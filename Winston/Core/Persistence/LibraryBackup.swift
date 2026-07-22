import Foundation
import SQLite3
import OSLog

nonisolated enum LibraryBackup {
    private struct BackupManifest: Codable {
        let formatVersion: Int
        let createdAt: Date
        let includesManagedBookFiles: Bool
        let includesManagedFileJournal: Bool
    }

    private enum BackupError: Error, LocalizedError {
        case sqlite(String)
        case invalidDatabase

        var errorDescription: String? {
            switch self {
            case .sqlite(let message): message
            case .invalidDatabase: "The backup does not contain a valid SQLite catalog"
            }
        }
    }

    static let folderPrefix = "Winston Backup "
    // Backups made before the app was renamed from Kalibre — keep them listed and restorable.
    static let legacyFolderPrefix = "Kalibre Backup "
    static let currentStoreName = "Winston.store"
    static let legacyStoreName = "Kalibre.store"
    static let pendingRestoreKey = "pendingRestorePath"
    static let manifestName = "backup-manifest.json"

    private static func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }

    @discardableResult
    static func backup(
        storeURL: URL,
        coversDirectory: URL,
        to folder: URL,
        keepLast: Int = 5,
        booksDirectory: URL? = nil,
        managedFilesDirectory: URL? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let booksDirectory = booksDirectory ?? siblingDirectory(named: "Books", of: coversDirectory)
        let managedFilesDirectory = managedFilesDirectory
            ?? siblingDirectory(named: "ManagedFiles", of: coversDirectory)
        let stamp = timestampFormatter().string(from: Date())
        var destination = folder.appending(path: "\(folderPrefix)\(stamp)", directoryHint: .isDirectory)
        var collision = 2
        while fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = folder.appending(path: "\(folderPrefix)\(stamp)-\(collision)", directoryHint: .isDirectory)
            collision += 1
        }

        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let snapshot = destination.appending(path: storeURL.lastPathComponent)
            try snapshotSQLite(from: storeURL, to: snapshot)

            try copyDirectory(
                coversDirectory,
                to: destination.appending(path: "covers", directoryHint: .isDirectory),
                fileManager: fm
            )
            try copyDirectory(
                booksDirectory,
                to: destination.appending(path: "Books", directoryHint: .isDirectory),
                fileManager: fm
            )
            try copyDirectory(
                managedFilesDirectory,
                to: destination.appending(path: "ManagedFiles", directoryHint: .isDirectory),
                fileManager: fm
            )
            let manifest = BackupManifest(
                formatVersion: 2,
                createdAt: Date(),
                includesManagedBookFiles: true,
                includesManagedFileJournal: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(
                to: destination.appending(path: manifestName),
                options: .atomic
            )

            prune(in: folder, keepLast: keepLast)
            return destination
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    static func prune(in folder: URL, keepLast: Int) {
        for old in availableBackups(in: folder).dropFirst(max(0, keepLast)) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    // MARK: - Restore

    static func availableBackups(in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter {
                $0.lastPathComponent.hasPrefix(folderPrefix)
                    || $0.lastPathComponent.hasPrefix(legacyFolderPrefix)
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func date(of backup: URL) -> Date? {
        let name = backup.lastPathComponent
        let prefix = name.hasPrefix(legacyFolderPrefix) ? legacyFolderPrefix : folderPrefix
        let stamp = name.replacingOccurrences(of: prefix, with: "")
        return timestampFormatter().date(from: String(stamp.prefix(17)))
    }

    static func catalogURL(in backup: URL) -> URL? {
        let fileManager = FileManager.default
        for name in [currentStoreName, legacyStoreName] {
            let candidate = backup.appending(path: name)
            if fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return nil
    }

    static func coverURL(for bookID: UUID, in backup: URL) -> URL? {
        let candidate = backup
            .appending(path: "covers", directoryHint: .isDirectory)
            .appending(path: "\(bookID.uuidString).jpg")
        guard FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) else {
            return nil
        }
        return candidate
    }

    static func requestRestore(from backup: URL) {
        UserDefaults.standard.set(backup.path(percentEncoded: false), forKey: pendingRestoreKey)
    }

    static func cancelPendingRestore() {
        UserDefaults.standard.removeObject(forKey: pendingRestoreKey)
    }

    @discardableResult
    static func applyPendingRestoreIfNeeded(
        storeURL: URL,
        coversDirectory: URL,
        booksDirectory: URL? = nil,
        managedFilesDirectory: URL? = nil
    ) -> Bool {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: pendingRestoreKey) else { return false }
        defaults.removeObject(forKey: pendingRestoreKey)

        let fm = FileManager.default
        let backup = URL(fileURLWithPath: path, isDirectory: true)
        var sourceStoreName = storeURL.lastPathComponent
        if !fm.fileExists(atPath: backup.appending(path: sourceStoreName).path(percentEncoded: false)) {
            sourceStoreName = legacyStoreName
        }
        let backupStore = backup.appending(path: sourceStoreName)
        guard fm.fileExists(atPath: backupStore.path(percentEncoded: false)) else { return false }
        let booksDirectory = booksDirectory ?? siblingDirectory(named: "Books", of: coversDirectory)
        let managedFilesDirectory = managedFilesDirectory
            ?? siblingDirectory(named: "ManagedFiles", of: coversDirectory)

        let parent = storeURL.deletingLastPathComponent()
        let staging = parent.appending(
            path: ".WinstonRestoreStaging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fm.removeItem(at: staging) }

        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let stagedStore = staging.appending(path: storeURL.lastPathComponent)
            for suffix in ["", "-wal", "-shm"] {
                let source = backup.appending(path: sourceStoreName + suffix)
                guard fm.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
                try fm.copyItem(
                    at: source,
                    to: staging.appending(path: storeURL.lastPathComponent + suffix)
                )
            }

            let backupCovers = backup.appending(path: "covers", directoryHint: .isDirectory)
            let stagedCovers = staging.appending(path: "covers", directoryHint: .isDirectory)
            if fm.fileExists(atPath: backupCovers.path(percentEncoded: false)) {
                try fm.copyItem(at: backupCovers, to: stagedCovers)
            }

            let shouldRestoreManagedFiles = try restoresManagedFiles(in: backup)
            if shouldRestoreManagedFiles {
                let backupBooks = backup.appending(path: "Books", directoryHint: .isDirectory)
                let backupManagedFiles = backup.appending(
                    path: "ManagedFiles",
                    directoryHint: .isDirectory
                )
                guard fm.fileExists(atPath: backupBooks.path(percentEncoded: false)),
                      fm.fileExists(atPath: backupManagedFiles.path(percentEncoded: false)) else {
                    throw BackupError.invalidDatabase
                }
                try fm.copyItem(
                    at: backupBooks,
                    to: staging.appending(path: "Books", directoryHint: .isDirectory)
                )
                try fm.copyItem(
                    at: backupManagedFiles,
                    to: staging.appending(path: "ManagedFiles", directoryHint: .isDirectory)
                )
            }

            try validateSQLite(at: stagedStore)

            let storePath = storeURL.path(percentEncoded: false)
            if fm.fileExists(atPath: storePath) {
                _ = try Self.backup(
                    storeURL: storeURL,
                    coversDirectory: coversDirectory,
                    to: backup.deletingLastPathComponent(),
                    keepLast: Int.max,
                    booksDirectory: booksDirectory,
                    managedFilesDirectory: managedFilesDirectory
                )
            }

            try installStagedRestore(
                staging: staging,
                storeURL: storeURL,
                coversDirectory: coversDirectory,
                booksDirectory: booksDirectory,
                managedFilesDirectory: managedFilesDirectory,
                restoresManagedFiles: shouldRestoreManagedFiles
            )
            return true
        } catch {
            Log.persistence.error("Backup restore failed before commit: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - SQLite snapshot

    private static func snapshotSQLite(from sourceURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destinationURL)

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
            throw BackupError.sqlite(message)
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
            let message = sqliteMessage(destination, fallback: "Could not create the backup catalog")
            if let destination { sqlite3_close(destination) }
            throw BackupError.sqlite(message)
        }
        defer { sqlite3_close(destination) }
        sqlite3_busy_timeout(destination, 5_000)

        guard let handle = sqlite3_backup_init(destination, "main", source, "main") else {
            throw BackupError.sqlite(sqliteMessage(destination, fallback: "Could not start SQLite backup"))
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
            throw BackupError.sqlite(sqliteMessage(destination, fallback: "SQLite backup did not complete"))
        }
    }

    private static func validateSQLite(at storeURL: URL) throws {
        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(
            storeURL.path(percentEncoded: false),
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw BackupError.invalidDatabase
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)

        _ = sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw BackupError.invalidDatabase }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0),
              String(cString: text) == "ok" else {
            throw BackupError.invalidDatabase
        }
    }

    private static func installStagedRestore(
        staging: URL,
        storeURL: URL,
        coversDirectory: URL,
        booksDirectory: URL,
        managedFilesDirectory: URL,
        restoresManagedFiles: Bool
    ) throws {
        let fm = FileManager.default
        let rollback = storeURL.deletingLastPathComponent().appending(
            path: ".WinstonRestoreRollback-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fm.createDirectory(at: rollback, withIntermediateDirectories: true)

        let storeName = storeURL.lastPathComponent
        do {
            for suffix in ["", "-wal", "-shm"] {
                let live = URL(fileURLWithPath: storeURL.path(percentEncoded: false) + suffix)
                if fm.fileExists(atPath: live.path(percentEncoded: false)) {
                    try fm.moveItem(at: live, to: rollback.appending(path: storeName + suffix))
                }
            }
            if fm.fileExists(atPath: coversDirectory.path(percentEncoded: false)) {
                try fm.moveItem(at: coversDirectory, to: rollback.appending(path: "covers"))
            }
            if restoresManagedFiles {
                if fm.fileExists(atPath: booksDirectory.path(percentEncoded: false)) {
                    try fm.moveItem(at: booksDirectory, to: rollback.appending(path: "Books"))
                }
                if fm.fileExists(atPath: managedFilesDirectory.path(percentEncoded: false)) {
                    try fm.moveItem(
                        at: managedFilesDirectory,
                        to: rollback.appending(path: "ManagedFiles")
                    )
                }
            }

            for suffix in ["", "-wal", "-shm"] {
                let staged = staging.appending(path: storeName + suffix)
                guard fm.fileExists(atPath: staged.path(percentEncoded: false)) else { continue }
                let live = URL(fileURLWithPath: storeURL.path(percentEncoded: false) + suffix)
                try fm.moveItem(at: staged, to: live)
            }
            let stagedCovers = staging.appending(path: "covers", directoryHint: .isDirectory)
            if fm.fileExists(atPath: stagedCovers.path(percentEncoded: false)) {
                try fm.moveItem(at: stagedCovers, to: coversDirectory)
            }
            if restoresManagedFiles {
                try fm.moveItem(
                    at: staging.appending(path: "Books", directoryHint: .isDirectory),
                    to: booksDirectory
                )
                try fm.moveItem(
                    at: staging.appending(path: "ManagedFiles", directoryHint: .isDirectory),
                    to: managedFilesDirectory
                )
            }

            try fm.removeItem(at: rollback)
        } catch {
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(atPath: storeURL.path(percentEncoded: false) + suffix)
                let saved = rollback.appending(path: storeName + suffix)
                if fm.fileExists(atPath: saved.path(percentEncoded: false)) {
                    try? fm.moveItem(
                        at: saved,
                        to: URL(fileURLWithPath: storeURL.path(percentEncoded: false) + suffix)
                    )
                }
            }
            try? fm.removeItem(at: coversDirectory)
            let savedCovers = rollback.appending(path: "covers", directoryHint: .isDirectory)
            if fm.fileExists(atPath: savedCovers.path(percentEncoded: false)) {
                try? fm.moveItem(at: savedCovers, to: coversDirectory)
            }
            if restoresManagedFiles {
                try? fm.removeItem(at: booksDirectory)
                let savedBooks = rollback.appending(path: "Books", directoryHint: .isDirectory)
                if fm.fileExists(atPath: savedBooks.path(percentEncoded: false)) {
                    try? fm.moveItem(at: savedBooks, to: booksDirectory)
                }
                try? fm.removeItem(at: managedFilesDirectory)
                let savedManagedFiles = rollback.appending(
                    path: "ManagedFiles",
                    directoryHint: .isDirectory
                )
                if fm.fileExists(atPath: savedManagedFiles.path(percentEncoded: false)) {
                    try? fm.moveItem(at: savedManagedFiles, to: managedFilesDirectory)
                }
            }
            throw error
        }
    }

    private static func copyDirectory(
        _ source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: source.path(percentEncoded: false)) {
            try fileManager.copyItem(at: source, to: destination)
        } else {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }
    }

    private static func siblingDirectory(named name: String, of directory: URL) -> URL {
        directory.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory)
    }

    private static func restoresManagedFiles(in backup: URL) throws -> Bool {
        let manifestURL = backup.appending(path: manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) else {
            return false
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            BackupManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        return manifest.formatVersion >= 2
            && manifest.includesManagedBookFiles
            && manifest.includesManagedFileJournal
    }

    private static func sqliteMessage(_ database: OpaquePointer?, fallback: String) -> String {
        guard let database, let message = sqlite3_errmsg(database) else { return fallback }
        return String(cString: message)
    }
}
