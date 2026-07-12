import Testing
import Foundation
import SQLite3
@testable import Winston

struct LibraryBackupTests {

    private func makeDatabase(at url: URL, value: String) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path(percentEncoded: false), &database) == SQLITE_OK)
        guard let database else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(database) }
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(database, "CREATE TABLE marker(value TEXT); INSERT INTO marker VALUES ('\(escaped)');",
                           nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func databaseValue(at url: URL) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path(percentEncoded: false), &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM marker LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { throw CocoaError(.fileReadCorruptFile) }
        return String(cString: text)
    }

    @Test func copiesStoreAndCovers() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "BackupTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = root.appending(path: "Winston.store")
        let covers = root.appending(path: "covers", directoryHint: .isDirectory)
        let dest = root.appending(path: "backups", directoryHint: .isDirectory)
        try fm.createDirectory(at: covers, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try makeDatabase(at: store, value: "store")
        try Data("img".utf8).write(to: covers.appending(path: "a.jpg"))
        defer { try? fm.removeItem(at: root) }

        let made = try LibraryBackup.backup(storeURL: store, coversDirectory: covers, to: dest, keepLast: 5)
        #expect(made.lastPathComponent.hasPrefix("Winston Backup "))
        #expect(fm.fileExists(atPath: made.appending(path: "Winston.store").path(percentEncoded: false)))
        #expect(try databaseValue(at: made.appending(path: "Winston.store")) == "store")
        #expect(fm.fileExists(atPath: made.appending(path: "covers/a.jpg").path(percentEncoded: false)))
    }

    @Test func snapshotIncludesCommittedWALStateWithoutCopyingSidecars() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "BackupWAL-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = root.appending(path: "Winston.store")
        let covers = root.appending(path: "covers", directoryHint: .isDirectory)
        let destination = root.appending(path: "backups", directoryHint: .isDirectory)
        try fm.createDirectory(at: covers, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var database: OpaquePointer?
        guard sqlite3_open(store.path(percentEncoded: false), &database) == SQLITE_OK,
              let database else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE marker(value TEXT); INSERT INTO marker VALUES ('wal-value');",
                           nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        #expect(fm.fileExists(atPath: store.path(percentEncoded: false) + "-wal"))

        let made = try LibraryBackup.backup(
            storeURL: store,
            coversDirectory: covers,
            to: destination,
            keepLast: 5
        )

        #expect(!fm.fileExists(atPath: made.appending(path: "Winston.store-wal").path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: made.appending(path: "Winston.store-shm").path(percentEncoded: false)))
        #expect(try databaseValue(at: made.appending(path: "Winston.store")) == "wal-value")
    }

    @Test func prunesToKeepLastNewest() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "PruneTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        for stamp in ["2026-01-01-000000", "2026-01-02-000000", "2026-01-03-000000", "2026-01-04-000000"] {
            try fm.createDirectory(at: folder.appending(path: "Winston Backup \(stamp)"), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: folder.appending(path: "Other"), withIntermediateDirectories: true)

        LibraryBackup.prune(in: folder, keepLast: 2)

        let backups = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("Winston Backup ") }
            .sorted()
        #expect(backups == ["Winston Backup 2026-01-03-000000", "Winston Backup 2026-01-04-000000"])
        #expect(fm.fileExists(atPath: folder.appending(path: "Other").path(percentEncoded: false)))
    }

    // MARK: - Restore

    @Test func listsBackupsNewestFirstAndParsesDates() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "ListTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        for stamp in ["2026-01-02-000000", "2026-03-01-121500", "2026-01-01-000000"] {
            try fm.createDirectory(at: folder.appending(path: "Winston Backup \(stamp)"), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: folder.appending(path: "Other"), withIntermediateDirectories: true)

        let backups = LibraryBackup.availableBackups(in: folder)
        #expect(backups.map(\.lastPathComponent) == [
            "Winston Backup 2026-03-01-121500",
            "Winston Backup 2026-01-02-000000",
            "Winston Backup 2026-01-01-000000",
        ])
        let date = try #require(LibraryBackup.date(of: backups[0]))
        let parts = Calendar.current.dateComponents([.year, .month, .hour, .minute], from: date)
        #expect(parts.year == 2026 && parts.month == 3 && parts.hour == 12 && parts.minute == 15)
    }

    @Test func appliesPendingRestoreAndSnapshotsCurrentState() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "RestoreTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = root.appending(path: "Winston.store")
        let covers = root.appending(path: "covers", directoryHint: .isDirectory)
        let backupsFolder = root.appending(path: "backups", directoryHint: .isDirectory)
        try fm.createDirectory(at: covers, withIntermediateDirectories: true)
        try fm.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
        try makeDatabase(at: store, value: "old")
        try Data("old-img".utf8).write(to: covers.appending(path: "a.jpg"))
        defer { try? fm.removeItem(at: root); LibraryBackup.cancelPendingRestore() }

        let backup = backupsFolder.appending(path: "Winston Backup 2026-01-01-000000", directoryHint: .isDirectory)
        try fm.createDirectory(at: backup.appending(path: "covers"), withIntermediateDirectories: true)
        try makeDatabase(at: backup.appending(path: "Winston.store"), value: "restored")
        try Data("restored-img".utf8).write(to: backup.appending(path: "covers/b.jpg"))

        LibraryBackup.requestRestore(from: backup)
        let applied = LibraryBackup.applyPendingRestoreIfNeeded(storeURL: store, coversDirectory: covers)

        #expect(applied)
        #expect(try databaseValue(at: store) == "restored")
        #expect(fm.fileExists(atPath: covers.appending(path: "b.jpg").path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: covers.appending(path: "a.jpg").path(percentEncoded: false)))
        let snapshots = LibraryBackup.availableBackups(in: backupsFolder)
            .filter { $0.lastPathComponent != backup.lastPathComponent }
        #expect(snapshots.count == 1)
        if let snapshot = snapshots.first {
            #expect(try databaseValue(at: snapshot.appending(path: "Winston.store")) == "old")
        }
        #expect(!LibraryBackup.applyPendingRestoreIfNeeded(storeURL: store, coversDirectory: covers))
    }

    @Test func listsAndRestoresPreRenameKalibreBackups() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "RestoreLegacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = root.appending(path: "Winston.store")
        let covers = root.appending(path: "covers", directoryHint: .isDirectory)
        let backupsFolder = root.appending(path: "backups", directoryHint: .isDirectory)
        try fm.createDirectory(at: covers, withIntermediateDirectories: true)
        try fm.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
        try makeDatabase(at: store, value: "current")
        defer { try? fm.removeItem(at: root); LibraryBackup.cancelPendingRestore() }

        let legacy = backupsFolder.appending(path: "Kalibre Backup 2026-01-01-000000", directoryHint: .isDirectory)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try makeDatabase(at: legacy.appending(path: "Kalibre.store"), value: "from-kalibre")

        let listed = LibraryBackup.availableBackups(in: backupsFolder).map(\.lastPathComponent)
        #expect(listed.contains("Kalibre Backup 2026-01-01-000000"))
        #expect(LibraryBackup.date(of: legacy) != nil)

        LibraryBackup.requestRestore(from: legacy)
        #expect(LibraryBackup.applyPendingRestoreIfNeeded(storeURL: store, coversDirectory: covers))
        #expect(try databaseValue(at: store) == "from-kalibre")
    }

    @Test func missingBackupIsANoOp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "RestoreMissing-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = root.appending(path: "Winston.store")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("live".utf8).write(to: store)
        defer { try? fm.removeItem(at: root); LibraryBackup.cancelPendingRestore() }

        LibraryBackup.requestRestore(from: root.appending(path: "Winston Backup 1999-01-01-000000"))
        #expect(!LibraryBackup.applyPendingRestoreIfNeeded(storeURL: store, coversDirectory: root.appending(path: "covers")))
        #expect(try Data(contentsOf: store) == Data("live".utf8))
    }

    @Test func corruptBackupLeavesLiveStoreAndCoversUntouched() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "RestoreCorrupt-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = root.appending(path: "Winston.store")
        let covers = root.appending(path: "covers", directoryHint: .isDirectory)
        let backup = root.appending(path: "Winston Backup 2026-01-01-000000", directoryHint: .isDirectory)
        try fm.createDirectory(at: covers, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try makeDatabase(at: store, value: "live")
        try Data("live-cover".utf8).write(to: covers.appending(path: "live.jpg"))
        try Data("not sqlite".utf8).write(to: backup.appending(path: "Winston.store"))
        defer { try? fm.removeItem(at: root); LibraryBackup.cancelPendingRestore() }

        LibraryBackup.requestRestore(from: backup)
        #expect(!LibraryBackup.applyPendingRestoreIfNeeded(storeURL: store, coversDirectory: covers))
        #expect(try databaseValue(at: store) == "live")
        #expect(try Data(contentsOf: covers.appending(path: "live.jpg")) == Data("live-cover".utf8))
    }
}
