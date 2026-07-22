import CryptoKit
import Foundation
import OSLog
import SQLite3
import SwiftData

nonisolated struct StoreOpenFailure: Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case corruption
        case migrationRequired
        case retryable
    }

    let kind: Kind
    let domain: String
    let code: Int
    let message: String
}

nonisolated struct StoreQuarantineManifest: Codable, Equatable, Sendable {
    struct FileRecord: Codable, Equatable, Sendable {
        let originalPath: String
        let snapshotPath: String
        var checksum: String?
        var copySucceeded: Bool
        var originalRemovalSucceeded: Bool
        var error: String?
    }

    enum Status: String, Codable, Sendable {
        case copying
        case copyFailed
        case preserved
        case cleanupFailed
        case completed
    }

    let createdAt: Date
    let storePath: String
    var status: Status
    var files: [FileRecord]
}

nonisolated struct StoreRecoveryFileSystem: Sendable {
    var fileExists: @Sendable (String) -> Bool
    var createDirectory: @Sendable (URL) throws -> Void
    var copyItem: @Sendable (URL, URL) throws -> Void
    var moveItem: @Sendable (URL, URL) throws -> Void
    var removeItem: @Sendable (URL) throws -> Void
    var checksum: @Sendable (URL) throws -> String
    var writeManifest: @Sendable (StoreQuarantineManifest, URL) throws -> Void

    static let live = StoreRecoveryFileSystem(
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        createDirectory: {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false)
        },
        copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
        moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
        removeItem: { try FileManager.default.removeItem(at: $0) },
        checksum: { url in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        },
        writeManifest: { manifest, url in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: url, options: .atomic)
        }
    )
}

nonisolated enum StoreIntegrityInspection: Sendable {
    case healthy
    case corrupt(message: String)
    case unavailable(StoreOpenFailure)
}

nonisolated struct StoreIntegrityInspector: Sendable {
    var inspect: @Sendable (URL) -> StoreIntegrityInspection

    static let live = StoreIntegrityInspector { storeURL in
        var database: OpaquePointer?
        let uri = "file:\(storeURL.path(percentEncoded: false))?mode=ro"
        let openCode = sqlite3_open_v2(
            uri,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite could not inspect the store."
            if let database { sqlite3_close(database) }
            return inspectionFailure(code: openCode, message: message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)

        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            return inspectionFailure(code: prepareCode, message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        let stepCode = sqlite3_step(statement)
        guard stepCode == SQLITE_ROW else {
            return inspectionFailure(code: stepCode, message: String(cString: sqlite3_errmsg(database)))
        }
        guard let text = sqlite3_column_text(statement, 0) else {
            return .unavailable(StoreOpenFailure(
                kind: .retryable,
                domain: "NSSQLiteErrorDomain",
                code: Int(stepCode),
                message: "SQLite integrity inspection returned no result."
            ))
        }
        let result = String(cString: text)
        return result == "ok" ? .healthy : .corrupt(message: result)
    }

    private static func inspectionFailure(code: Int32, message: String) -> StoreIntegrityInspection {
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
            return .corrupt(message: message)
        }
        return .unavailable(StoreOpenFailure(
            kind: .retryable,
            domain: "NSSQLiteErrorDomain",
            code: Int(code),
            message: message
        ))
    }
}

@MainActor
struct StoreRecoveryCoordinator {
    typealias StoreOpener = @MainActor (URL) throws -> ModelContainer

    enum Outcome {
        case opened(ModelContainer)
        case retryableFailure(StoreOpenFailure)
        case migrationRequired(StoreOpenFailure)
        case quarantined(ModelContainer, snapshotURL: URL)
        case readOnlyRecovery(snapshotURL: URL?, failure: StoreOpenFailure)
    }

    private enum QuarantineOutcome: Sendable {
        case ready(snapshotURL: URL)
        case incomplete(snapshotURL: URL?, message: String)
    }

    let fileSystem: StoreRecoveryFileSystem
    let inspector: StoreIntegrityInspector
    let now: @Sendable () -> Date
    let uuid: @Sendable () -> UUID

    init(
        fileSystem: StoreRecoveryFileSystem = .live,
        inspector: StoreIntegrityInspector = .live,
        now: @escaping @Sendable () -> Date = Date.init,
        uuid: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.fileSystem = fileSystem
        self.inspector = inspector
        self.now = now
        self.uuid = uuid
    }

    func open(storeURL: URL, opener: StoreOpener) -> Outcome {
        do {
            return .opened(try opener(storeURL))
        } catch {
            let failure = Self.classify(error)
            var confirmedFailure = failure
            switch failure.kind {
            case .retryable:
                let inspector = inspector
                let inspection = DispatchQueue.global(qos: .userInitiated).sync {
                    inspector.inspect(storeURL)
                }
                switch inspection {
                case .healthy:
                    return .retryableFailure(failure)
                case .unavailable(let inspectionFailure):
                    return .retryableFailure(inspectionFailure)
                case .corrupt(let message):
                    confirmedFailure = StoreOpenFailure(
                        kind: .corruption,
                        domain: "NSSQLiteErrorDomain",
                        code: Int(SQLITE_CORRUPT),
                        message: message
                    )
                }
            case .migrationRequired:
                return .migrationRequired(failure)
            case .corruption:
                break
            }

            Log.persistence.error("Store corruption was identified at \(storeURL.lastPathComponent, privacy: .public): \(confirmedFailure.message, privacy: .public)")
            let fileSystem = fileSystem
            let now = now()
            let uuid = uuid()
            let quarantine = DispatchQueue.global(qos: .userInitiated).sync {
                Self.quarantine(
                    storeURL: storeURL,
                    fileSystem: fileSystem,
                    now: now,
                    uuid: uuid
                )
            }

            switch quarantine {
            case .incomplete(let snapshotURL, let message):
                return .readOnlyRecovery(
                    snapshotURL: snapshotURL,
                    failure: StoreOpenFailure(
                        kind: .corruption,
                        domain: confirmedFailure.domain,
                        code: confirmedFailure.code,
                        message: message
                    )
                )
            case .ready(let snapshotURL):
                do {
                    return .quarantined(try opener(storeURL), snapshotURL: snapshotURL)
                } catch {
                    let freshFailure = Self.classify(error)
                    return .readOnlyRecovery(snapshotURL: snapshotURL, failure: freshFailure)
                }
            }
        }
    }

    nonisolated static func classify(_ error: any Error) -> StoreOpenFailure {
        let errors = flattenedErrors(error)

        if let migration = errors.first(where: isMigrationError) {
            return failure(from: migration, kind: .migrationRequired)
        }
        if let corruption = errors.first(where: isCorruptionError) {
            return failure(from: corruption, kind: .corruption)
        }
        if let operational = errors.first(where: isOperationalError) {
            return failure(from: operational, kind: .retryable)
        }
        return failure(from: errors.first ?? error as NSError, kind: .retryable)
    }

    private nonisolated static func quarantine(
        storeURL: URL,
        fileSystem: StoreRecoveryFileSystem,
        now: Date,
        uuid: UUID
    ) -> QuarantineOutcome {
        let parent = storeURL.deletingLastPathComponent()
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let finalURL = parent.appending(path: "\(storeURL.lastPathComponent).recovery-\(stamp)-\(uuid.uuidString)", directoryHint: .isDirectory)
        let stagingURL = parent.appending(path: ".\(storeURL.lastPathComponent).recovery-\(uuid.uuidString).partial", directoryHint: .isDirectory)
        let manifestName = "manifest.json"
        let base = storeURL.path(percentEncoded: false)
        let sources = ["", "-wal", "-shm"]
            .map { URL(filePath: base + $0) }
            .filter { fileSystem.fileExists($0.path(percentEncoded: false)) }

        guard !sources.isEmpty else {
            return .incomplete(snapshotURL: nil, message: "The store was classified as corrupt, but no store files were available to preserve.")
        }

        do {
            try fileSystem.createDirectory(stagingURL)
        } catch {
            return .incomplete(snapshotURL: nil, message: "Creating the recovery directory failed: \(error.localizedDescription)")
        }

        var manifest = StoreQuarantineManifest(
            createdAt: now,
            storePath: base,
            status: .copying,
            files: sources.map {
                StoreQuarantineManifest.FileRecord(
                    originalPath: $0.path(percentEncoded: false),
                    snapshotPath: stagingURL.appending(path: $0.lastPathComponent).path(percentEncoded: false),
                    checksum: nil,
                    copySucceeded: false,
                    originalRemovalSucceeded: false,
                    error: nil
                )
            }
        )

        for index in manifest.files.indices {
            let source = URL(filePath: manifest.files[index].originalPath)
            let destination = URL(filePath: manifest.files[index].snapshotPath)
            do {
                let sourceChecksum = try fileSystem.checksum(source)
                try fileSystem.copyItem(source, destination)
                let copiedChecksum = try fileSystem.checksum(destination)
                guard sourceChecksum == copiedChecksum else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                manifest.files[index].checksum = sourceChecksum
                manifest.files[index].copySucceeded = true
            } catch {
                manifest.files[index].error = "Copy failed: \(error.localizedDescription)"
            }
        }

        if manifest.files.contains(where: { !$0.copySucceeded }) {
            manifest.status = .copyFailed
            try? fileSystem.writeManifest(manifest, stagingURL.appending(path: manifestName))
            return .incomplete(snapshotURL: stagingURL, message: "One or more store files could not be copied into recovery quarantine.")
        }

        manifest.status = .preserved
        do {
            try fileSystem.writeManifest(manifest, stagingURL.appending(path: manifestName))
            try fileSystem.moveItem(stagingURL, finalURL)
        } catch {
            try? fileSystem.writeManifest(manifest, stagingURL.appending(path: manifestName))
            return .incomplete(snapshotURL: stagingURL, message: "Finalizing the recovery snapshot failed: \(error.localizedDescription)")
        }

        for index in manifest.files.indices {
            let source = URL(filePath: manifest.files[index].originalPath)
            do {
                try fileSystem.removeItem(source)
                manifest.files[index].originalRemovalSucceeded = true
            } catch {
                manifest.files[index].error = "Original cleanup failed: \(error.localizedDescription)"
            }
        }

        manifest.status = manifest.files.allSatisfy(\.originalRemovalSucceeded) ? .completed : .cleanupFailed
        let finalManifestURL = finalURL.appending(path: manifestName)
        do {
            try fileSystem.writeManifest(manifest, finalManifestURL)
        } catch {
            return .incomplete(snapshotURL: finalURL, message: "Updating the recovery manifest failed: \(error.localizedDescription)")
        }

        guard manifest.status == .completed else {
            return .incomplete(snapshotURL: finalURL, message: "The recovery snapshot is complete, but one or more original store files could not be removed.")
        }
        return .ready(snapshotURL: finalURL)
    }

    private nonisolated static func flattenedErrors(_ error: any Error) -> [NSError] {
        var result: [NSError] = []
        var queue: [NSError] = [error as NSError]
        var seen: Set<ObjectIdentifier> = []
        while let current = queue.popLast() {
            guard seen.insert(ObjectIdentifier(current)).inserted else { continue }
            result.append(current)
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                queue.append(underlying)
            }
            if let detailed = current.userInfo["NSDetailedErrors"] as? [NSError] {
                queue.append(contentsOf: detailed)
            }
        }
        return result
    }

    private nonisolated static func isMigrationError(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain && (134100...134150).contains(error.code)
    }

    private nonisolated static func isCorruptionError(_ error: NSError) -> Bool {
        if error.domain == "NSSQLiteErrorDomain" && [11, 26].contains(error.code) {
            return true
        }
        if let sqliteCode = error.userInfo["NSSQLiteErrorDomain"] as? NSNumber,
           [11, 26].contains(sqliteCode.intValue) {
            return true
        }
        let diagnostic = "\(error.localizedDescription) \(error.userInfo[NSDebugDescriptionErrorKey] as? String ?? "")".lowercased()
        return diagnostic.contains("database disk image is malformed")
            || diagnostic.contains("file is not a database")
            || diagnostic.contains("not a database")
            || diagnostic.contains("database corruption")
    }

    private nonisolated static func isOperationalError(_ error: NSError) -> Bool {
        guard error.domain == NSPOSIXErrorDomain else { return false }
        return [EACCES, EAGAIN, EBUSY, EDQUOT, EMFILE, ENFILE, ENOENT, ENOSPC, EROFS, ETIMEDOUT].contains(Int32(error.code))
    }

    private nonisolated static func failure(from error: NSError, kind: StoreOpenFailure.Kind) -> StoreOpenFailure {
        StoreOpenFailure(
            kind: kind,
            domain: error.domain,
            code: error.code,
            message: error.localizedDescription
        )
    }
}
