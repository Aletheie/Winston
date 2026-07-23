import Foundation

/// Compatibility facade for snapshot creation and launch-time restore.
///
/// `LibrarySnapshotCoordinator` owns the consistency and crash-recovery protocol. Keeping this
/// facade lets the settings UI and older call sites retain their small synchronous API.
nonisolated enum LibraryBackup {
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
        managedFilesDirectory: URL? = nil,
        testingHooks: LibrarySnapshotCoordinator.TestingHooks = .live
    ) throws -> URL {
        try LibrarySnapshotCoordinator.backup(
            storeURL: storeURL,
            coversDirectory: coversDirectory,
            to: folder,
            keepLast: keepLast,
            booksDirectory: booksDirectory,
            managedFilesDirectory: managedFilesDirectory,
            hooks: testingHooks
        )
    }

    static func prune(in folder: URL, keepLast: Int) {
        for old in availableBackups(in: folder).dropFirst(max(0, keepLast)) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    static func availableBackups(in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
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
        let defaults = UserDefaults.standard
        defaults.set(backup.path(percentEncoded: false), forKey: pendingRestoreKey)
        // A restore request must survive an immediate application termination.
        defaults.synchronize()
    }

    static func cancelPendingRestore() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: pendingRestoreKey)
        defaults.synchronize()
    }

    @discardableResult
    static func applyPendingRestoreIfNeeded(
        storeURL: URL,
        coversDirectory: URL,
        booksDirectory: URL? = nil,
        managedFilesDirectory: URL? = nil,
        testingHooks: LibrarySnapshotCoordinator.TestingHooks = .live
    ) -> Bool {
        restorePendingSnapshotIfNeeded(
            storeURL: storeURL,
            coversDirectory: coversDirectory,
            booksDirectory: booksDirectory,
            managedFilesDirectory: managedFilesDirectory,
            testingHooks: testingHooks
        ) == .committed
    }

    static func restorePendingSnapshotIfNeeded(
        storeURL: URL,
        coversDirectory: URL,
        booksDirectory: URL? = nil,
        managedFilesDirectory: URL? = nil,
        testingHooks: LibrarySnapshotCoordinator.TestingHooks = .live
    ) -> LibrarySnapshotCoordinator.RestoreOutcome {
        LibrarySnapshotCoordinator.restorePendingSnapshotIfNeeded(
            storeURL: storeURL,
            coversDirectory: coversDirectory,
            booksDirectory: booksDirectory,
            managedFilesDirectory: managedFilesDirectory,
            hooks: testingHooks
        )
    }
}
