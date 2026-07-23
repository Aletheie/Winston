import CryptoKit
import Darwin
import Foundation
import OSLog
import SQLite3

nonisolated struct LibrarySnapshotManifest: Codable, Equatable, Sendable {
    struct FileRecord: Codable, Equatable, Sendable {
        let relativePath: String
        let byteCount: Int64
        let sha256: String
    }

    let formatVersion: Int
    let snapshotID: UUID
    let createdAt: Date
    let catalogSchemaVersion: Int
    let catalogFileName: String
    let catalogGeneration: String
    let catalogCapturedAt: Date
    let coverGeneration: String
    let coversCapturedAt: Date
    let captureSequence: [String]
    let includesManagedBookFiles: Bool
    let includesManagedFileJournal: Bool
    let files: [FileRecord]
}

/// Creates complete library snapshots and installs them through a durable, restartable journal.
///
/// SQLite and the file trees cannot be captured in one filesystem transaction. The manifest makes
/// their exact relationship explicit instead: it records the catalog digest, the independently
/// stabilized cover generation, capture order, and every file digest. Restore never mutates a
/// source backup and does not touch live data until the complete staged package has been verified.
nonisolated enum LibrarySnapshotCoordinator {
    enum RestoreOutcome: Equatable {
        case none
        case committed
        /// The live set is intact. The pending request remains so a later launch can retry.
        case retryPending
        /// A durable transaction still owns live paths. The caller must not open the live store.
        case blocked(String)
    }

    enum TestingEvent: Equatable {
        case capturedSourceGeneration(component: String, attempt: Int)
        case prepared
        case movedLive(component: String)
        case installed(component: String)
        case rollbackMoved(component: String)
        case validated
        case committed
    }

    struct SimulatedCrash: Error, Equatable {}

    struct TestingHooks {
        var event: (TestingEvent) throws -> Void
        var availableCapacity: (URL) -> Int64?

        init(
            event: @escaping (TestingEvent) throws -> Void = { _ in },
            availableCapacity: @escaping (URL) -> Int64? = Self.systemAvailableCapacity
        ) {
            self.event = event
            self.availableCapacity = availableCapacity
        }

        static var live: TestingHooks { TestingHooks() }

        private static func systemAvailableCapacity(at url: URL) -> Int64? {
            let values = try? url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            if let important = values?.volumeAvailableCapacityForImportantUsage {
                return important
            }
            if let available = values?.volumeAvailableCapacity {
                return Int64(available)
            }
            return nil
        }
    }

    private enum SnapshotError: Error, LocalizedError {
        case sqlite(String)
        case invalidDatabase
        case invalidManifest(String)
        case sourceChanged(String)
        case unsafeEntry(String)
        case insufficientSpace(required: Int64, available: Int64)
        case inconsistentRestore(String)
        case unsupportedVolume(String)

        var errorDescription: String? {
            switch self {
            case .sqlite(let message):
                message
            case .invalidDatabase:
                "The backup does not contain a valid SQLite catalog"
            case .invalidManifest(let message):
                "The backup manifest is invalid: \(message)"
            case .sourceChanged(let component):
                "The \(component) files changed repeatedly while the snapshot was being created"
            case .unsafeEntry(let path):
                "The snapshot contains an unsafe filesystem entry: \(path)"
            case .insufficientSpace(let required, let available):
                "The restore requires \(required) bytes but only \(available) bytes are available"
            case .inconsistentRestore(let message):
                "The restore journal cannot be reconciled: \(message)"
            case .unsupportedVolume(let path):
                "The live library path is not on the restore transaction volume: \(path)"
            }
        }
    }

    private struct ManifestHeader: Decodable {
        let formatVersion: Int
    }

    private struct LegacyManifest: Decodable {
        let formatVersion: Int
        let includesManagedBookFiles: Bool?
        let includesManagedFileJournal: Bool?
    }

    private struct PackageInfo {
        let sourceStoreName: String
        let restoresManagedFiles: Bool
        let manifest: LibrarySnapshotManifest?
        let byteCount: Int64
    }

    private enum ComponentKey: String, Codable, CaseIterable {
        case catalog
        case wal
        case shm
        case covers
        case books
        case managedFiles
    }

    private enum ComponentProgress: String, Codable {
        case pending
        case liveMoved
        case installed
    }

    private struct RestoreComponent: Codable {
        let key: ComponentKey
        let hadLive: Bool
        let hasStaged: Bool
        var progress: ComponentProgress
        var rollbackCompleted: Bool
    }

    private struct RestoreJournal: Codable {
        enum State: String, Codable {
            case preparing
            case prepared
            case installing
            case validating
            case committed
            case rollingBack
            case rolledBack
        }

        let formatVersion: Int
        let transactionID: UUID
        let backupPath: String
        let pendingPath: String
        let sourceStoreName: String
        let targetStoreName: String
        let targetCoversPath: String
        let targetBooksPath: String
        let targetManagedFilesPath: String
        let manifestFormatVersion: Int?
        let restoresManagedFiles: Bool
        var state: State
        var components: [RestoreComponent]
    }

    private struct RestorePaths {
        let store: URL
        let covers: URL
        let books: URL
        let managedFiles: URL

        var parent: URL { store.deletingLastPathComponent() }
        var journal: URL { parent.appending(path: ".WinstonRestoreJournal.json") }

        func transaction(for id: UUID) -> URL {
            parent.appending(path: ".WinstonRestore-\(id.uuidString)", directoryHint: .isDirectory)
        }

        func liveURL(for key: ComponentKey) -> URL {
            switch key {
            case .catalog:
                store
            case .wal:
                URL(fileURLWithPath: store.path(percentEncoded: false) + "-wal")
            case .shm:
                URL(fileURLWithPath: store.path(percentEncoded: false) + "-shm")
            case .covers:
                covers
            case .books:
                books
            case .managedFiles:
                managedFiles
            }
        }
    }

    private struct TreeSnapshot {
        let records: [LibrarySnapshotManifest.FileRecord]
        let generation: String
        let byteCount: Int64
    }

    private static let formatVersion = 3
    private static let restoreJournalVersion = 1
    private static let minimumFreeSpaceReserve: Int64 = 64 * 1_024 * 1_024
    private static let operationLock = NSRecursiveLock()

    // MARK: - Snapshot creation

    @discardableResult
    static func backup(
        storeURL: URL,
        coversDirectory: URL,
        to folder: URL,
        keepLast: Int,
        booksDirectory: URL?,
        managedFilesDirectory: URL?,
        hooks: TestingHooks
    ) throws -> URL {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try backupUnlocked(
            storeURL: storeURL,
            coversDirectory: coversDirectory,
            to: folder,
            keepLast: keepLast,
            booksDirectory: booksDirectory,
            managedFilesDirectory: managedFilesDirectory,
            hooks: hooks
        )
    }

    private static func backupUnlocked(
        storeURL: URL,
        coversDirectory: URL,
        to folder: URL,
        keepLast: Int,
        booksDirectory: URL?,
        managedFilesDirectory: URL?,
        hooks: TestingHooks
    ) throws -> URL {
        let fileManager = FileManager.default
        let booksDirectory = booksDirectory
            ?? siblingDirectory(named: "Books", of: coversDirectory)
        let managedFilesDirectory = managedFilesDirectory
            ?? siblingDirectory(named: "ManagedFiles", of: coversDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let sourceBytes = try sqliteFamilyByteCount(at: storeURL)
            + fileTreeByteCount(at: coversDirectory)
            + fileTreeByteCount(at: booksDirectory)
            + fileTreeByteCount(at: managedFilesDirectory)
        try requireCapacity(
            at: folder,
            required: sourceBytes + minimumFreeSpaceReserve,
            hooks: hooks
        )

        let destination = nextBackupURL(in: folder)
        let partial = folder.appending(
            path: ".WinstonSnapshot-\(UUID().uuidString).partial",
            directoryHint: .isDirectory
        )

        do {
            try fileManager.createDirectory(at: partial, withIntermediateDirectories: false)
            let catalog = partial.appending(path: storeURL.lastPathComponent)
            try snapshotSQLite(from: storeURL, to: catalog)
            let catalogCapturedAt = Date()
            // sqlite3_backup captures a coherent database but preserves the source's WAL mode.
            // Normalize the private snapshot to a standalone single-file catalog.
            try validateSQLite(at: catalog, checkpointWAL: true)
            try removeSQLiteSidecars(for: catalog)

            let covers = try copyStableDirectory(
                coversDirectory,
                to: partial.appending(path: "covers", directoryHint: .isDirectory),
                component: "covers",
                hooks: hooks
            )
            let coversCapturedAt = Date()
            _ = try copyStableDirectory(
                booksDirectory,
                to: partial.appending(path: "Books", directoryHint: .isDirectory),
                component: "books",
                hooks: hooks
            )
            _ = try copyStableDirectory(
                managedFilesDirectory,
                to: partial.appending(path: "ManagedFiles", directoryHint: .isDirectory),
                component: "managed files",
                hooks: hooks
            )

            let records = try treeSnapshot(
                at: partial,
                excludingRelativePaths: [LibraryBackup.manifestName]
            ).records
            let manifest = LibrarySnapshotManifest(
                formatVersion: formatVersion,
                snapshotID: UUID(),
                createdAt: Date(),
                catalogSchemaVersion: try sqliteSchemaVersion(at: catalog),
                catalogFileName: storeURL.lastPathComponent,
                catalogGeneration: try sha256(of: catalog),
                catalogCapturedAt: catalogCapturedAt,
                coverGeneration: covers.generation,
                coversCapturedAt: coversCapturedAt,
                captureSequence: ["catalog", "covers", "books", "managedFiles"],
                includesManagedBookFiles: true,
                includesManagedFileJournal: true,
                files: records
            )
            try writeManifest(
                manifest,
                to: partial.appending(path: LibraryBackup.manifestName)
            )
            _ = try inspectPackage(at: partial, preferredStoreName: storeURL.lastPathComponent)

            try durableMove(partial, to: destination)
            LibraryBackup.prune(in: folder, keepLast: keepLast)
            return destination
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private static func copyStableDirectory(
        _ source: URL,
        to destination: URL,
        component: String,
        hooks: TestingHooks
    ) throws -> TreeSnapshot {
        let fileManager = FileManager.default
        for attempt in 1...3 {
            let before = try treeSnapshot(at: source)
            try hooks.event(.capturedSourceGeneration(component: component, attempt: attempt))
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: source.path(percentEncoded: false)) {
                try fileManager.copyItem(at: source, to: destination)
            } else {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            let after = try treeSnapshot(at: source)
            let copied = try treeSnapshot(at: destination)
            if before.generation == after.generation,
               after.generation == copied.generation {
                return copied
            }
        }
        throw SnapshotError.sourceChanged(component)
    }

    // MARK: - Restore orchestration

    static func restorePendingSnapshotIfNeeded(
        storeURL: URL,
        coversDirectory: URL,
        booksDirectory: URL?,
        managedFilesDirectory: URL?,
        hooks: TestingHooks
    ) -> RestoreOutcome {
        operationLock.lock()
        defer { operationLock.unlock() }

        let paths = RestorePaths(
            store: storeURL,
            covers: coversDirectory,
            books: booksDirectory ?? siblingDirectory(named: "Books", of: coversDirectory),
            managedFiles: managedFilesDirectory
                ?? siblingDirectory(named: "ManagedFiles", of: coversDirectory)
        )

        do {
            try FileManager.default.createDirectory(
                at: paths.parent,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: paths.journal.path(percentEncoded: false)) {
                var journal = try readJournal(at: paths.journal)
                return try resume(journal: &journal, paths: paths, hooks: hooks)
            }

            guard let pendingPath = UserDefaults.standard.string(
                forKey: LibraryBackup.pendingRestoreKey
            ) else {
                return .none
            }
            var journal = try prepareRestore(
                backup: URL(fileURLWithPath: pendingPath, isDirectory: true),
                pendingPath: pendingPath,
                paths: paths,
                hooks: hooks
            )
            return try install(journal: &journal, paths: paths, hooks: hooks)
        } catch is SimulatedCrash {
            return .blocked("A simulated process interruption left a durable restore transaction")
        } catch {
            Log.persistence.error(
                "Backup restore stopped: \(error.localizedDescription, privacy: .public)"
            )
            return recoverAfterFailure(error, paths: paths, hooks: hooks)
        }
    }

    private static func resume(
        journal: inout RestoreJournal,
        paths: RestorePaths,
        hooks: TestingHooks
    ) throws -> RestoreOutcome {
        try validateJournalTargets(journal, for: paths)
        if journal.state != .preparing {
            try validateJournalComponents(journal)
        }
        switch journal.state {
        case .preparing:
            try cleanupPreparingTransaction(journal: journal, paths: paths)
            return .retryPending
        case .committed:
            completeCommittedRestore(journal: journal, paths: paths)
            return .committed
        case .rollingBack:
            try rollback(journal: &journal, paths: paths, hooks: hooks)
            cleanupCompletedTransaction(journal: journal, paths: paths)
            return .retryPending
        case .rolledBack:
            cleanupCompletedTransaction(journal: journal, paths: paths)
            return .retryPending
        case .prepared, .installing, .validating:
            return try install(journal: &journal, paths: paths, hooks: hooks)
        }
    }

    private static func prepareRestore(
        backup: URL,
        pendingPath: String,
        paths: RestorePaths,
        hooks: TestingHooks
    ) throws -> RestoreJournal {
        let fileManager = FileManager.default
        let package = try inspectPackage(
            at: backup,
            preferredStoreName: paths.store.lastPathComponent
        )
        let liveBytes = try liveLibraryByteCount(paths: paths)
        try requireCapacity(
            at: paths.parent,
            required: package.byteCount + liveBytes + minimumFreeSpaceReserve,
            hooks: hooks
        )

        let transactionID = UUID()
        let transaction = paths.transaction(for: transactionID)
        let staging = transaction.appending(path: "staged", directoryHint: .isDirectory)
        let rollbackDirectory = transaction.appending(
            path: "rollback",
            directoryHint: .isDirectory
        )
        let discardDirectory = transaction.appending(
            path: "discard",
            directoryHint: .isDirectory
        )
        var journalWasWritten = false

        do {
            var journal = RestoreJournal(
                formatVersion: restoreJournalVersion,
                transactionID: transactionID,
                backupPath: standardizedPath(backup),
                pendingPath: pendingPath,
                sourceStoreName: package.sourceStoreName,
                targetStoreName: paths.store.lastPathComponent,
                targetCoversPath: standardizedPath(paths.covers),
                targetBooksPath: standardizedPath(paths.books),
                targetManagedFilesPath: standardizedPath(paths.managedFiles),
                manifestFormatVersion: package.manifest?.formatVersion,
                restoresManagedFiles: package.restoresManagedFiles,
                state: .preparing,
                components: []
            )
            // Publish ownership before creating any transaction files. A crash anywhere in
            // staging can then be distinguished from an install that has touched live paths.
            try writeJournal(journal, at: paths.journal)
            journalWasWritten = true
            try fileManager.createDirectory(at: transaction, withIntermediateDirectories: false)
            _ = try copyStableDirectory(
                backup,
                to: staging,
                component: "backup package",
                hooks: hooks
            )
            let stagedPackage = try inspectPackage(
                at: staging,
                preferredStoreName: paths.store.lastPathComponent
            )
            guard stagedPackage.sourceStoreName == package.sourceStoreName,
                  stagedPackage.restoresManagedFiles == package.restoresManagedFiles else {
                throw SnapshotError.invalidManifest("the staged package changed during validation")
            }

            try normalizeStagedStore(
                in: staging,
                sourceStoreName: package.sourceStoreName,
                targetStoreName: paths.store.lastPathComponent
            )
            try validateSQLite(
                at: staging.appending(path: paths.store.lastPathComponent),
                checkpointWAL: package.manifest == nil
            )
            if package.manifest == nil {
                try removeSQLiteSidecars(
                    for: staging.appending(path: paths.store.lastPathComponent)
                )
            }

            if fileManager.fileExists(atPath: paths.store.path(percentEncoded: false)) {
                try createSafetySnapshot(
                    paths: paths,
                    preferredFolder: backup.deletingLastPathComponent(),
                    hooks: hooks
                )
            }

            try fileManager.createDirectory(
                at: rollbackDirectory,
                withIntermediateDirectories: false
            )
            try fileManager.createDirectory(
                at: discardDirectory,
                withIntermediateDirectories: false
            )
            try validateTransactionVolume(paths: paths, restoresManagedFiles: package.restoresManagedFiles)

            let keys: [ComponentKey] = package.restoresManagedFiles
                ? [.catalog, .wal, .shm, .covers, .books, .managedFiles]
                : [.catalog, .wal, .shm, .covers]
            let components = keys.map { key in
                RestoreComponent(
                    key: key,
                    hadLive: fileManager.fileExists(
                        atPath: paths.liveURL(for: key).path(percentEncoded: false)
                    ),
                    hasStaged: fileManager.fileExists(
                        atPath: stagedURL(
                            for: key,
                            transaction: transaction,
                            targetStoreName: paths.store.lastPathComponent
                        ).path(percentEncoded: false)
                    ),
                    progress: .pending,
                    rollbackCompleted: false
                )
            }
            guard components.first(where: { $0.key == .catalog })?.hasStaged == true else {
                throw SnapshotError.invalidDatabase
            }

            journal.state = .prepared
            journal.components = components
            try writeJournal(journal, at: paths.journal)
            try hooks.event(.prepared)
            return journal
        } catch {
            if !journalWasWritten {
                try? fileManager.removeItem(at: transaction)
            }
            throw error
        }
    }

    private static func createSafetySnapshot(
        paths: RestorePaths,
        preferredFolder: URL,
        hooks: TestingHooks
    ) throws {
        do {
            _ = try backupUnlocked(
                storeURL: paths.store,
                coversDirectory: paths.covers,
                to: preferredFolder,
                keepLast: Int.max,
                booksDirectory: paths.books,
                managedFilesDirectory: paths.managedFiles,
                hooks: hooks
            )
        } catch {
            let fallback = paths.parent.appending(
                path: "Restore Safety Backups",
                directoryHint: .isDirectory
            )
            guard standardizedPath(fallback) != standardizedPath(preferredFolder) else {
                throw error
            }
            Log.persistence.notice(
                "Could not write the safety snapshot beside the source backup; using local recovery storage"
            )
            _ = try backupUnlocked(
                storeURL: paths.store,
                coversDirectory: paths.covers,
                to: fallback,
                keepLast: Int.max,
                booksDirectory: paths.books,
                managedFilesDirectory: paths.managedFiles,
                hooks: hooks
            )
        }
    }

    private static func install(
        journal: inout RestoreJournal,
        paths: RestorePaths,
        hooks: TestingHooks
    ) throws -> RestoreOutcome {
        try validate(journal: journal, for: paths)
        if journal.state == .prepared {
            journal.state = .installing
            try writeJournal(journal, at: paths.journal)
        }

        if journal.state == .installing {
            for index in journal.components.indices {
                try installComponent(
                    at: index,
                    journal: &journal,
                    paths: paths,
                    hooks: hooks
                )
            }
            journal.state = .validating
            try writeJournal(journal, at: paths.journal)
        }

        guard journal.state == .validating else {
            throw SnapshotError.inconsistentRestore(
                "unexpected install state \(journal.state.rawValue)"
            )
        }
        try validateSQLite(at: paths.store, checkpointWAL: false)
        if journal.manifestFormatVersion == formatVersion {
            try validateInstalledManifest(journal: journal, paths: paths)
        }
        try validateInstalledComponentPresence(journal: journal, paths: paths)
        try hooks.event(.validated)

        journal.state = .committed
        try writeJournal(journal, at: paths.journal)
        try hooks.event(.committed)
        completeCommittedRestore(journal: journal, paths: paths)
        return .committed
    }

    private static func installComponent(
        at index: Int,
        journal: inout RestoreJournal,
        paths: RestorePaths,
        hooks: TestingHooks
    ) throws {
        let fileManager = FileManager.default
        let transaction = paths.transaction(for: journal.transactionID)
        let key = journal.components[index].key
        let live = paths.liveURL(for: key)
        let staged = stagedURL(
            for: key,
            transaction: transaction,
            targetStoreName: journal.targetStoreName
        )
        let saved = rollbackURL(for: key, transaction: transaction)

        if journal.components[index].progress == .pending {
            if fileManager.fileExists(atPath: saved.path(percentEncoded: false)) {
                journal.components[index].progress = .liveMoved
                try writeJournal(journal, at: paths.journal)
            } else if journal.components[index].hadLive {
                guard fileManager.fileExists(atPath: live.path(percentEncoded: false)) else {
                    throw SnapshotError.inconsistentRestore(
                        "\(key.rawValue) is absent from both live and rollback locations"
                    )
                }
                try durableMove(live, to: saved)
                try hooks.event(.movedLive(component: key.rawValue))
                journal.components[index].progress = .liveMoved
                try writeJournal(journal, at: paths.journal)
            } else {
                guard !fileManager.fileExists(atPath: live.path(percentEncoded: false)) else {
                    throw SnapshotError.inconsistentRestore(
                        "a new live \(key.rawValue) appeared after restore preparation"
                    )
                }
                journal.components[index].progress = .liveMoved
                try writeJournal(journal, at: paths.journal)
            }
        }

        if journal.components[index].progress == .liveMoved {
            if journal.components[index].hasStaged {
                if fileManager.fileExists(atPath: staged.path(percentEncoded: false)) {
                    guard !fileManager.fileExists(atPath: live.path(percentEncoded: false)) else {
                        throw SnapshotError.inconsistentRestore(
                            "\(key.rawValue) exists in both staged and live locations"
                        )
                    }
                    try durableMove(staged, to: live)
                    try hooks.event(.installed(component: key.rawValue))
                } else {
                    guard fileManager.fileExists(atPath: live.path(percentEncoded: false)) else {
                        throw SnapshotError.inconsistentRestore(
                            "\(key.rawValue) is absent from staged and live locations"
                        )
                    }
                }
            } else {
                guard !fileManager.fileExists(atPath: live.path(percentEncoded: false)) else {
                    throw SnapshotError.inconsistentRestore(
                        "\(key.rawValue) was expected to be absent after installation"
                    )
                }
            }
            journal.components[index].progress = .installed
            try writeJournal(journal, at: paths.journal)
        }

        guard journal.components[index].progress == .installed else {
            throw SnapshotError.inconsistentRestore(
                "\(key.rawValue) did not reach the installed state"
            )
        }
        let liveExists = fileManager.fileExists(atPath: live.path(percentEncoded: false))
        guard liveExists == journal.components[index].hasStaged else {
            throw SnapshotError.inconsistentRestore(
                "\(key.rawValue) does not match its staged presence"
            )
        }
    }

    private static func recoverAfterFailure(
        _ originalError: Error,
        paths: RestorePaths,
        hooks: TestingHooks
    ) -> RestoreOutcome {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.journal.path(percentEncoded: false)) else {
            // Validation, staging, capacity, and safety-snapshot failures leave live data untouched.
            return .retryPending
        }

        do {
            var journal = try readJournal(at: paths.journal)
            try validateJournalTargets(journal, for: paths)
            if journal.state == .preparing {
                try cleanupPreparingTransaction(journal: journal, paths: paths)
                return .retryPending
            }
            try validateJournalComponents(journal)
            if journal.state == .committed {
                completeCommittedRestore(journal: journal, paths: paths)
                return .committed
            }
            if journal.state != .rollingBack && journal.state != .rolledBack {
                // Persist rollback intent before reversing a single rename. If publishing this
                // checkpoint fails, recovery must keep following the prior install intent.
                journal.state = .rollingBack
                try writeJournal(journal, at: paths.journal)
            }
            if journal.state == .rollingBack {
                try rollback(journal: &journal, paths: paths, hooks: hooks)
            }
            cleanupCompletedTransaction(journal: journal, paths: paths)
            return .retryPending
        } catch is SimulatedCrash {
            return .blocked("A simulated interruption occurred while rolling the restore back")
        } catch {
            let message = "\(originalError.localizedDescription); recovery: \(error.localizedDescription)"
            Log.persistence.fault(
                "Restore recovery remains unresolved: \(message, privacy: .public)"
            )
            return .blocked(message)
        }
    }

    private static func rollback(
        journal: inout RestoreJournal,
        paths: RestorePaths,
        hooks: TestingHooks
    ) throws {
        guard journal.state == .rollingBack else {
            throw SnapshotError.inconsistentRestore("rollback was entered without durable intent")
        }
        let fileManager = FileManager.default
        let transaction = paths.transaction(for: journal.transactionID)

        for index in journal.components.indices.reversed() {
            if journal.components[index].rollbackCompleted { continue }
            let key = journal.components[index].key
            let live = paths.liveURL(for: key)
            let saved = rollbackURL(for: key, transaction: transaction)
            let discard = discardURL(for: key, transaction: transaction)
            let liveExists = fileManager.fileExists(atPath: live.path(percentEncoded: false))
            let savedExists = fileManager.fileExists(atPath: saved.path(percentEncoded: false))
            let discardExists = fileManager.fileExists(atPath: discard.path(percentEncoded: false))

            if savedExists {
                if liveExists {
                    guard !discardExists else {
                        throw SnapshotError.inconsistentRestore(
                            "\(key.rawValue) exists in live, rollback, and discard locations"
                        )
                    }
                    try durableMove(live, to: discard)
                    try hooks.event(.rollbackMoved(component: key.rawValue))
                }
                try durableMove(saved, to: live)
                try hooks.event(.rollbackMoved(component: key.rawValue))
            } else if journal.components[index].hadLive {
                guard liveExists else {
                    throw SnapshotError.inconsistentRestore(
                        "the original \(key.rawValue) cannot be found during rollback"
                    )
                }
            } else if liveExists {
                guard !discardExists else {
                    throw SnapshotError.inconsistentRestore(
                        "the replacement \(key.rawValue) exists in live and discard locations"
                    )
                }
                try durableMove(live, to: discard)
                try hooks.event(.rollbackMoved(component: key.rawValue))
            }

            journal.components[index].rollbackCompleted = true
            try writeJournal(journal, at: paths.journal)
        }

        journal.state = .rolledBack
        try writeJournal(journal, at: paths.journal)
    }

    private static func completeCommittedRestore(
        journal: RestoreJournal,
        paths: RestorePaths
    ) {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: LibraryBackup.pendingRestoreKey) == journal.pendingPath {
            defaults.removeObject(forKey: LibraryBackup.pendingRestoreKey)
            guard defaults.synchronize() else {
                // Keep the committed journal as the durable source of truth until the defaults
                // domain confirms that the request marker is gone.
                Log.persistence.error(
                    "Committed restore is waiting for durable pending-marker removal"
                )
                return
            }
        }
        cleanupCompletedTransaction(journal: journal, paths: paths)
    }

    private static func cleanupCompletedTransaction(
        journal: RestoreJournal,
        paths: RestorePaths
    ) {
        guard journal.state == .committed || journal.state == .rolledBack else { return }
        let fileManager = FileManager.default
        let transaction = paths.transaction(for: journal.transactionID)
        if fileManager.fileExists(atPath: transaction.path(percentEncoded: false)) {
            do {
                try fileManager.removeItem(at: transaction)
                try syncDirectory(transaction.deletingLastPathComponent())
            } catch {
                Log.persistence.error(
                    "Could not remove completed restore transaction: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }
        do {
            try removeDurably(paths.journal)
        } catch {
            Log.persistence.error(
                "Could not remove completed restore journal: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Package validation

    private static func inspectPackage(
        at backup: URL,
        preferredStoreName: String
    ) throws -> PackageInfo {
        let fileManager = FileManager.default
        let values = try backup.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SnapshotError.invalidManifest("the backup path is not a directory")
        }
        let packageTree = try treeSnapshot(at: backup)
        let manifestURL = backup.appending(path: LibraryBackup.manifestName)
        guard fileManager.fileExists(atPath: manifestURL.path(percentEncoded: false)) else {
            let sourceStoreName = try locateLegacyStore(
                in: backup,
                preferredStoreName: preferredStoreName
            )
            return PackageInfo(
                sourceStoreName: sourceStoreName,
                restoresManagedFiles: false,
                manifest: nil,
                byteCount: packageTree.byteCount
            )
        }

        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header: ManifestHeader
        do {
            header = try decoder.decode(ManifestHeader.self, from: data)
        } catch {
            throw SnapshotError.invalidManifest("it cannot be decoded")
        }

        if header.formatVersion == formatVersion {
            let manifest: LibrarySnapshotManifest
            do {
                manifest = try decoder.decode(LibrarySnapshotManifest.self, from: data)
            } catch {
                throw SnapshotError.invalidManifest("version 3 fields are incomplete")
            }
            try validate(manifest: manifest, in: backup)
            return PackageInfo(
                sourceStoreName: manifest.catalogFileName,
                restoresManagedFiles: manifest.includesManagedBookFiles
                    && manifest.includesManagedFileJournal,
                manifest: manifest,
                byteCount: packageTree.byteCount
            )
        }

        guard header.formatVersion > 0, header.formatVersion < formatVersion else {
            throw SnapshotError.invalidManifest(
                "unsupported format version \(header.formatVersion)"
            )
        }
        let legacy: LegacyManifest
        do {
            legacy = try decoder.decode(LegacyManifest.self, from: data)
        } catch {
            throw SnapshotError.invalidManifest("legacy fields cannot be decoded")
        }
        let restoresManagedFiles = legacy.formatVersion >= 2
            && legacy.includesManagedBookFiles == true
            && legacy.includesManagedFileJournal == true
        if restoresManagedFiles {
            try requireRealDirectory(backup.appending(path: "Books", directoryHint: .isDirectory))
            try requireRealDirectory(
                backup.appending(path: "ManagedFiles", directoryHint: .isDirectory)
            )
        }
        return PackageInfo(
            sourceStoreName: try locateLegacyStore(
                in: backup,
                preferredStoreName: preferredStoreName
            ),
            restoresManagedFiles: restoresManagedFiles,
            manifest: nil,
            byteCount: packageTree.byteCount
        )
    }

    private static func validate(
        manifest: LibrarySnapshotManifest,
        in backup: URL
    ) throws {
        guard manifest.formatVersion == formatVersion else {
            throw SnapshotError.invalidManifest("unexpected format version")
        }
        guard isSafeLeafName(manifest.catalogFileName) else {
            throw SnapshotError.invalidManifest("the catalog filename is unsafe")
        }
        guard manifest.captureSequence == ["catalog", "covers", "books", "managedFiles"],
              manifest.catalogCapturedAt <= manifest.coversCapturedAt,
              manifest.coversCapturedAt <= manifest.createdAt else {
            throw SnapshotError.invalidManifest("capture ordering is inconsistent")
        }
        guard manifest.includesManagedBookFiles,
              manifest.includesManagedFileJournal else {
            throw SnapshotError.invalidManifest("version 3 snapshots must be complete")
        }
        try requireRealDirectory(backup.appending(path: "covers", directoryHint: .isDirectory))
        try requireRealDirectory(backup.appending(path: "Books", directoryHint: .isDirectory))
        try requireRealDirectory(
            backup.appending(path: "ManagedFiles", directoryHint: .isDirectory)
        )

        let actual = try treeSnapshot(
            at: backup,
            excludingRelativePaths: [LibraryBackup.manifestName]
        ).records
        let expected = manifest.files.sorted { $0.relativePath < $1.relativePath }
        guard Set(expected.map(\.relativePath)).count == expected.count else {
            throw SnapshotError.invalidManifest("duplicate file records")
        }
        for record in expected {
            guard isSafeRelativePath(record.relativePath),
                  isAllowedSnapshotPath(
                    record.relativePath,
                    catalogFileName: manifest.catalogFileName
                  ) else {
                throw SnapshotError.invalidManifest(
                    "unsafe file record \(record.relativePath)"
                )
            }
        }
        guard expected == actual else {
            throw SnapshotError.invalidManifest("file size or checksum mismatch")
        }

        guard let catalog = expected.first(where: {
            $0.relativePath == manifest.catalogFileName
        }), catalog.sha256 == manifest.catalogGeneration else {
            throw SnapshotError.invalidManifest("catalog generation mismatch")
        }
        let catalogURL = backup.appending(path: manifest.catalogFileName)
        guard try sqliteSchemaVersion(at: catalogURL) == manifest.catalogSchemaVersion else {
            throw SnapshotError.invalidManifest("catalog schema version mismatch")
        }
        let coverRecords = expected.compactMap { record -> LibrarySnapshotManifest.FileRecord? in
            let prefix = "covers/"
            guard record.relativePath.hasPrefix(prefix) else { return nil }
            return LibrarySnapshotManifest.FileRecord(
                relativePath: String(record.relativePath.dropFirst(prefix.count)),
                byteCount: record.byteCount,
                sha256: record.sha256
            )
        }
        guard generation(for: coverRecords) == manifest.coverGeneration else {
            throw SnapshotError.invalidManifest("cover generation mismatch")
        }
    }

    private static func validateInstalledManifest(
        journal: RestoreJournal,
        paths: RestorePaths
    ) throws {
        let transaction = paths.transaction(for: journal.transactionID)
        let manifestURL = transaction
            .appending(path: "staged", directoryHint: .isDirectory)
            .appending(path: LibraryBackup.manifestName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            LibrarySnapshotManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        var actual = [
            try fileRecord(for: paths.store, relativePath: manifest.catalogFileName),
        ]
        for (directory, prefix) in [
            (paths.covers, "covers/"),
            (paths.books, "Books/"),
            (paths.managedFiles, "ManagedFiles/"),
        ] {
            actual.append(contentsOf: try treeSnapshot(at: directory).records.map { record in
                LibrarySnapshotManifest.FileRecord(
                    relativePath: prefix + record.relativePath,
                    byteCount: record.byteCount,
                    sha256: record.sha256
                )
            })
        }
        actual.sort { $0.relativePath < $1.relativePath }
        let expected = manifest.files.sorted { $0.relativePath < $1.relativePath }
        guard actual == expected else {
            throw SnapshotError.invalidManifest(
                "the installed file set does not exactly match the manifest"
            )
        }
        guard try sha256(of: paths.store) == manifest.catalogGeneration,
              try sqliteSchemaVersion(at: paths.store) == manifest.catalogSchemaVersion else {
            throw SnapshotError.invalidManifest("installed catalog generation mismatch")
        }
        let covers = try treeSnapshot(at: paths.covers)
        guard covers.generation == manifest.coverGeneration else {
            throw SnapshotError.invalidManifest("installed cover generation mismatch")
        }
    }

    private static func validateInstalledComponentPresence(
        journal: RestoreJournal,
        paths: RestorePaths
    ) throws {
        for component in journal.components {
            let exists = FileManager.default.fileExists(
                atPath: paths.liveURL(for: component.key).path(percentEncoded: false)
            )
            guard exists == component.hasStaged else {
                throw SnapshotError.inconsistentRestore(
                    "\(component.key.rawValue) changed during final restore validation"
                )
            }
        }
    }

    private static func locateLegacyStore(
        in backup: URL,
        preferredStoreName: String
    ) throws -> String {
        let fileManager = FileManager.default
        var candidates = [
            preferredStoreName,
            LibraryBackup.currentStoreName,
            LibraryBackup.legacyStoreName,
        ]
        candidates = candidates.reduce(into: []) { result, name in
            if !result.contains(name) { result.append(name) }
        }
        for name in candidates where isSafeLeafName(name) {
            let candidate = backup.appending(path: name)
            if fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
                let values = try candidate.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw SnapshotError.unsafeEntry(name)
                }
                return name
            }
        }
        throw SnapshotError.invalidDatabase
    }

    // MARK: - Journal helpers

    private static func validate(
        journal: RestoreJournal,
        for paths: RestorePaths
    ) throws {
        try validateJournalTargets(journal, for: paths)
        try validateJournalComponents(journal)
    }

    private static func validateJournalTargets(
        _ journal: RestoreJournal,
        for paths: RestorePaths
    ) throws {
        guard journal.formatVersion == restoreJournalVersion,
              journal.targetStoreName == paths.store.lastPathComponent,
              journal.targetCoversPath == standardizedPath(paths.covers),
              journal.targetBooksPath == standardizedPath(paths.books),
              journal.targetManagedFilesPath == standardizedPath(paths.managedFiles) else {
            throw SnapshotError.inconsistentRestore(
                "the journal does not belong to the requested live library"
            )
        }
    }

    private static func validateJournalComponents(
        _ journal: RestoreJournal
    ) throws {
        guard Set(journal.components.map(\.key)).count == journal.components.count,
              journal.components.contains(where: { $0.key == .catalog }) else {
            throw SnapshotError.inconsistentRestore("the journal component set is invalid")
        }
        let allowed: Set<ComponentKey> = journal.restoresManagedFiles
            ? Set(ComponentKey.allCases)
            : [.catalog, .wal, .shm, .covers]
        guard Set(journal.components.map(\.key)) == allowed else {
            throw SnapshotError.inconsistentRestore("the component set is incomplete")
        }
    }

    private static func cleanupPreparingTransaction(
        journal: RestoreJournal,
        paths: RestorePaths
    ) throws {
        guard journal.state == .preparing else {
            throw SnapshotError.inconsistentRestore(
                "only a preparing transaction can be discarded before install"
            )
        }
        let transaction = paths.transaction(for: journal.transactionID)
        if FileManager.default.fileExists(atPath: transaction.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: transaction)
            try syncDirectory(transaction.deletingLastPathComponent())
        }
        try removeDurably(paths.journal)
    }

    private static func writeJournal(
        _ journal: RestoreJournal,
        at url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeDurably(encoder.encode(journal), to: url)
    }

    private static func readJournal(at url: URL) throws -> RestoreJournal {
        do {
            return try JSONDecoder().decode(
                RestoreJournal.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw SnapshotError.inconsistentRestore("the durable journal is unreadable")
        }
    }

    private static func normalizeStagedStore(
        in staging: URL,
        sourceStoreName: String,
        targetStoreName: String
    ) throws {
        guard sourceStoreName != targetStoreName else { return }
        for suffix in ["", "-wal", "-shm"] {
            let source = staging.appending(path: sourceStoreName + suffix)
            guard FileManager.default.fileExists(
                atPath: source.path(percentEncoded: false)
            ) else {
                continue
            }
            try durableMove(source, to: staging.appending(path: targetStoreName + suffix))
        }
    }

    private static func stagedURL(
        for key: ComponentKey,
        transaction: URL,
        targetStoreName: String
    ) -> URL {
        let staging = transaction.appending(path: "staged", directoryHint: .isDirectory)
        switch key {
        case .catalog:
            return staging.appending(path: targetStoreName)
        case .wal:
            return staging.appending(path: targetStoreName + "-wal")
        case .shm:
            return staging.appending(path: targetStoreName + "-shm")
        case .covers:
            return staging.appending(path: "covers", directoryHint: .isDirectory)
        case .books:
            return staging.appending(path: "Books", directoryHint: .isDirectory)
        case .managedFiles:
            return staging.appending(path: "ManagedFiles", directoryHint: .isDirectory)
        }
    }

    private static func rollbackURL(
        for key: ComponentKey,
        transaction: URL
    ) -> URL {
        transaction
            .appending(path: "rollback", directoryHint: .isDirectory)
            .appending(path: key.rawValue)
    }

    private static func discardURL(
        for key: ComponentKey,
        transaction: URL
    ) -> URL {
        transaction
            .appending(path: "discard", directoryHint: .isDirectory)
            .appending(path: key.rawValue)
    }

    private static func validateTransactionVolume(
        paths: RestorePaths,
        restoresManagedFiles: Bool
    ) throws {
        let transactionVolume = try volumeIdentifier(at: paths.parent)
        let targets = restoresManagedFiles
            ? [paths.store, paths.covers, paths.books, paths.managedFiles]
            : [paths.store, paths.covers]
        for target in targets {
            let existing = FileManager.default.fileExists(
                atPath: target.path(percentEncoded: false)
            ) ? target : target.deletingLastPathComponent()
            guard try volumeIdentifier(at: existing) == transactionVolume else {
                throw SnapshotError.unsupportedVolume(standardizedPath(target))
            }
        }
    }

    // MARK: - Filesystem consistency

    private static func treeSnapshot(
        at root: URL,
        excludingRelativePaths: Set<String> = []
    ) throws -> TreeSnapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path(percentEncoded: false)) else {
            return TreeSnapshot(records: [], generation: generation(for: []), byteCount: 0)
        }
        let rootValues = try root.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard rootValues.isSymbolicLink != true else {
            throw SnapshotError.unsafeEntry(root.lastPathComponent)
        }
        if rootValues.isRegularFile == true {
            let record = try fileRecord(for: root, relativePath: root.lastPathComponent)
            return TreeSnapshot(
                records: [record],
                generation: generation(for: [record]),
                byteCount: record.byteCount
            )
        }
        guard rootValues.isDirectory == true else {
            throw SnapshotError.unsafeEntry(root.path(percentEncoded: false))
        }

        var records: [LibrarySnapshotManifest.FileRecord] = []
        try collectFileRecords(
            in: root,
            relativeDirectory: "",
            excludingRelativePaths: excludingRelativePaths,
            records: &records
        )
        records.sort { $0.relativePath < $1.relativePath }
        return TreeSnapshot(
            records: records,
            generation: generation(for: records),
            byteCount: records.reduce(0) { $0 + $1.byteCount }
        )
    }

    private static func collectFileRecords(
        in directory: URL,
        relativeDirectory: String,
        excludingRelativePaths: Set<String>,
        records: inout [LibrarySnapshotManifest.FileRecord]
    ) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for entry in entries {
            let relativePath = relativeDirectory.isEmpty
                ? entry.lastPathComponent
                : relativeDirectory + "/" + entry.lastPathComponent
            guard isSafeRelativePath(relativePath) else {
                throw SnapshotError.unsafeEntry(relativePath)
            }
            let values = try entry.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw SnapshotError.unsafeEntry(relativePath)
            }
            if values.isDirectory == true {
                try collectFileRecords(
                    in: entry,
                    relativeDirectory: relativePath,
                    excludingRelativePaths: excludingRelativePaths,
                    records: &records
                )
            } else if values.isRegularFile == true {
                if !excludingRelativePaths.contains(relativePath) {
                    records.append(try fileRecord(for: entry, relativePath: relativePath))
                }
            } else {
                throw SnapshotError.unsafeEntry(relativePath)
            }
        }
    }

    private static func fileRecord(
        for file: URL,
        relativePath: String
    ) throws -> LibrarySnapshotManifest.FileRecord {
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        return LibrarySnapshotManifest.FileRecord(
            relativePath: relativePath,
            byteCount: Int64(values.fileSize ?? 0),
            sha256: try sha256(of: file)
        )
    }

    private static func generation(
        for records: [LibrarySnapshotManifest.FileRecord]
    ) -> String {
        var hasher = SHA256()
        for record in records.sorted(by: { $0.relativePath < $1.relativePath }) {
            hasher.update(data: Data(record.relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(record.byteCount).utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(record.sha256.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(of file: URL) throws -> String {
        let values = try file.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SnapshotError.unsafeEntry(file.path(percentEncoded: false))
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileTreeByteCount(at url: URL) throws -> Int64 {
        try treeSnapshot(at: url).byteCount
    }

    private static func sqliteFamilyByteCount(at storeURL: URL) throws -> Int64 {
        var total = try fileTreeByteCount(at: storeURL)
        for suffix in ["-wal", "-shm"] {
            total += try fileTreeByteCount(
                at: URL(fileURLWithPath: storeURL.path(percentEncoded: false) + suffix)
            )
        }
        return total
    }

    private static func liveLibraryByteCount(paths: RestorePaths) throws -> Int64 {
        var total: Int64 = 0
        for key in ComponentKey.allCases {
            total += try fileTreeByteCount(at: paths.liveURL(for: key))
        }
        return total
    }

    private static func requireCapacity(
        at url: URL,
        required: Int64,
        hooks: TestingHooks
    ) throws {
        guard let available = hooks.availableCapacity(url), available < required else {
            return
        }
        throw SnapshotError.insufficientSpace(required: required, available: available)
    }

    private static func requireRealDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SnapshotError.unsafeEntry(url.path(percentEncoded: false))
        }
    }

    private static func isAllowedSnapshotPath(
        _ path: String,
        catalogFileName: String
    ) -> Bool {
        path == catalogFileName
            || path.hasPrefix("covers/")
            || path.hasPrefix("Books/")
            || path.hasPrefix("ManagedFiles/")
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func isSafeLeafName(_ name: String) -> Bool {
        isSafeRelativePath(name) && !name.contains("/")
    }

    private static func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }

    private static func siblingDirectory(named name: String, of directory: URL) -> URL {
        directory.deletingLastPathComponent().appending(
            path: name,
            directoryHint: .isDirectory
        )
    }

    private static func nextBackupURL(in folder: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: Date())
        var destination = folder.appending(
            path: "\(LibraryBackup.folderPrefix)\(stamp)",
            directoryHint: .isDirectory
        )
        var collision = 2
        while FileManager.default.fileExists(
            atPath: destination.path(percentEncoded: false)
        ) {
            destination = folder.appending(
                path: "\(LibraryBackup.folderPrefix)\(stamp)-\(collision)",
                directoryHint: .isDirectory
            )
            collision += 1
        }
        return destination
    }

    // MARK: - SQLite

    private static func snapshotSQLite(from sourceURL: URL, to destinationURL: URL) throws {
        var source: OpaquePointer?
        let sourceCode = sqlite3_open_v2(
            sourceURL.path(percentEncoded: false),
            &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard sourceCode == SQLITE_OK, let source else {
            let message = sqliteMessage(source, fallback: "Could not open the live catalog")
            if let source { sqlite3_close(source) }
            throw SnapshotError.sqlite(message)
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 5_000)

        var destination: OpaquePointer?
        let destinationCode = sqlite3_open_v2(
            destinationURL.path(percentEncoded: false),
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationCode == SQLITE_OK, let destination else {
            let message = sqliteMessage(
                destination,
                fallback: "Could not create the backup catalog"
            )
            if let destination { sqlite3_close(destination) }
            throw SnapshotError.sqlite(message)
        }
        defer { sqlite3_close(destination) }
        sqlite3_busy_timeout(destination, 5_000)

        guard let handle = sqlite3_backup_init(destination, "main", source, "main") else {
            throw SnapshotError.sqlite(
                sqliteMessage(destination, fallback: "Could not start SQLite backup")
            )
        }

        var stepCode: Int32 = SQLITE_OK
        var busyRetries = 0
        repeat {
            stepCode = sqlite3_backup_step(handle, 128)
            if stepCode == SQLITE_BUSY || stepCode == SQLITE_LOCKED {
                busyRetries += 1
                sqlite3_sleep(25)
            } else if stepCode == SQLITE_OK {
                busyRetries = 0
            }
        } while stepCode == SQLITE_OK
            || ((stepCode == SQLITE_BUSY || stepCode == SQLITE_LOCKED) && busyRetries < 200)

        let finishCode = sqlite3_backup_finish(handle)
        guard stepCode == SQLITE_DONE, finishCode == SQLITE_OK else {
            throw SnapshotError.sqlite(
                sqliteMessage(destination, fallback: "SQLite backup did not complete")
            )
        }
    }

    private static func validateSQLite(at storeURL: URL, checkpointWAL: Bool) throws {
        var database: OpaquePointer?
        let accessMode = checkpointWAL ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
        let openCode = sqlite3_open_v2(
            storeURL.path(percentEncoded: false),
            &database,
            accessMode | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SnapshotError.invalidDatabase
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)

        if checkpointWAL {
            let checkpoint = sqlite3_exec(
                database,
                "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE",
                nil,
                nil,
                nil
            )
            guard checkpoint == SQLITE_OK else {
                throw SnapshotError.invalidDatabase
            }
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA quick_check",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw SnapshotError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0),
              String(cString: text) == "ok" else {
            throw SnapshotError.invalidDatabase
        }
    }

    private static func sqliteSchemaVersion(at storeURL: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            storeURL.path(percentEncoded: false),
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SnapshotError.invalidDatabase
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA schema_version",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw SnapshotError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SnapshotError.invalidDatabase
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func sqliteMessage(
        _ database: OpaquePointer?,
        fallback: String
    ) -> String {
        guard let database, let message = sqlite3_errmsg(database) else { return fallback }
        return String(cString: message)
    }

    private static func removeSQLiteSidecars(for storeURL: URL) throws {
        for suffix in ["-wal", "-shm"] {
            try removeDurably(
                URL(fileURLWithPath: storeURL.path(percentEncoded: false) + suffix)
            )
        }
    }

    // MARK: - Durable filesystem operations

    private static func writeManifest(
        _ manifest: LibrarySnapshotManifest,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try writeDurably(encoder.encode(manifest), to: url)
    }

    private static func writeDurably(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            let renameResult = temporary.path(percentEncoded: false).withCString { source in
                url.path(percentEncoded: false).withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard renameResult == 0 else { throw currentPOSIXError() }
            try syncDirectory(parent)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func durableMove(_ source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
        try syncDirectory(source.deletingLastPathComponent())
        if source.deletingLastPathComponent().standardizedFileURL
            != destination.deletingLastPathComponent().standardizedFileURL {
            try syncDirectory(destination.deletingLastPathComponent())
        }
    }

    private static func removeDurably(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return
        }
        try FileManager.default.removeItem(at: url)
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = directory.path(percentEncoded: false).withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        if Darwin.fsync(descriptor) != 0, errno != EINVAL {
            throw currentPOSIXError()
        }
    }

    private static func volumeIdentifier(at url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.volumeIdentifierKey])
        guard let identifier = values.volumeIdentifier else {
            throw SnapshotError.unsupportedVolume(standardizedPath(url))
        }
        return String(describing: identifier)
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
