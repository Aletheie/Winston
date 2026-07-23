import Testing
import Foundation
import SQLite3
@testable import Winston

@Suite(.serialized)
struct LibraryBackupTests {
    private struct RestoreFixture {
        let root: URL
        let store: URL
        let covers: URL
        let books: URL
        let managedFiles: URL
        let backup: URL
    }

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

    private func makeCompleteRestoreFixture(prefix: String) throws -> RestoreFixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "\(prefix)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let store = root.appending(path: LibraryBackup.currentStoreName)
        let covers = root.appending(path: "covers", directoryHint: .isDirectory)
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let managedFiles = root.appending(path: "ManagedFiles", directoryHint: .isDirectory)
        let journal = managedFiles.appending(path: "Journal", directoryHint: .isDirectory)
        let backups = root.appending(path: "backups", directoryHint: .isDirectory)
        for directory in [covers, books, journal, backups] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try makeDatabase(at: store, value: "restored")
        try Data("restored-cover".utf8).write(to: covers.appending(path: "book.jpg"))
        try Data("restored-book".utf8).write(to: books.appending(path: "book.epub"))
        try Data("restored-journal".utf8).write(to: journal.appending(path: "pending.json"))
        let backup = try LibraryBackup.backup(
            storeURL: store,
            coversDirectory: covers,
            to: backups,
            booksDirectory: books,
            managedFilesDirectory: managedFiles
        )

        try fileManager.removeItem(at: store)
        try makeDatabase(at: store, value: "current")
        for directory in [covers, books, managedFiles] {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: covers, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: books, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: journal, withIntermediateDirectories: true)
        try Data("current-cover".utf8).write(to: covers.appending(path: "current.jpg"))
        try Data("current-book".utf8).write(to: books.appending(path: "current.epub"))
        try Data("current-journal".utf8).write(to: journal.appending(path: "current.json"))

        return RestoreFixture(
            root: root,
            store: store,
            covers: covers,
            books: books,
            managedFiles: managedFiles,
            backup: backup
        )
    }

    @Test func copiesStoreBooksCoversAndRecoveryJournal() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "BackupTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = root.appending(path: "Winston.store")
        let covers = root.appending(path: "covers", directoryHint: .isDirectory)
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let managedFiles = root.appending(path: "ManagedFiles/Journal", directoryHint: .isDirectory)
        let dest = root.appending(path: "backups", directoryHint: .isDirectory)
        try fm.createDirectory(at: covers, withIntermediateDirectories: true)
        try fm.createDirectory(at: books, withIntermediateDirectories: true)
        try fm.createDirectory(at: managedFiles, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try makeDatabase(at: store, value: "store")
        try Data("img".utf8).write(to: covers.appending(path: "a.jpg"))
        try Data("book".utf8).write(to: books.appending(path: "a.epub"))
        try Data("journal".utf8).write(to: managedFiles.appending(path: "pending.json"))
        defer { try? fm.removeItem(at: root) }

        let made = try LibraryBackup.backup(storeURL: store, coversDirectory: covers, to: dest, keepLast: 5)
        #expect(made.lastPathComponent.hasPrefix("Winston Backup "))
        #expect(fm.fileExists(atPath: made.appending(path: "Winston.store").path(percentEncoded: false)))
        #expect(try databaseValue(at: made.appending(path: "Winston.store")) == "store")
        #expect(fm.fileExists(atPath: made.appending(path: "covers/a.jpg").path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: made.appending(path: "Books/a.epub").path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: made.appending(path: "ManagedFiles/Journal/pending.json").path(percentEncoded: false)))
        let manifestURL = made.appending(path: LibraryBackup.manifestName)
        #expect(fm.fileExists(atPath: manifestURL.path(percentEncoded: false)))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            LibrarySnapshotManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        #expect(manifest.formatVersion == 3)
        #expect(manifest.catalogFileName == "Winston.store")
        #expect(manifest.catalogGeneration.count == 64)
        #expect(manifest.coverGeneration.count == 64)
        #expect(manifest.captureSequence == ["catalog", "covers", "books", "managedFiles"])
        #expect(manifest.files.map(\.relativePath) == [
            "Books/a.epub",
            "ManagedFiles/Journal/pending.json",
            "Winston.store",
            "covers/a.jpg",
        ])
    }

    @Test func snapshotIncludesCommittedWALStateWithoutCopyingSidecars() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "BackupWAL-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = root.appending(path: "Winston.store")
        let covers = root.appending(path: "covers", directoryHint: .isDirectory)
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let destination = root.appending(path: "backups", directoryHint: .isDirectory)
        try fm.createDirectory(at: covers, withIntermediateDirectories: true)
        try fm.createDirectory(at: books, withIntermediateDirectories: true)
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
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let backupsFolder = root.appending(path: "backups", directoryHint: .isDirectory)
        try fm.createDirectory(at: covers, withIntermediateDirectories: true)
        try fm.createDirectory(at: books, withIntermediateDirectories: true)
        try fm.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
        try makeDatabase(at: store, value: "old")
        try Data("old-img".utf8).write(to: covers.appending(path: "a.jpg"))
        try Data("current-book".utf8).write(to: books.appending(path: "current.epub"))
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
        #expect(fm.fileExists(atPath: books.appending(path: "current.epub").path(percentEncoded: false)))
        let snapshots = LibraryBackup.availableBackups(in: backupsFolder)
            .filter { $0.lastPathComponent != backup.lastPathComponent }
        #expect(snapshots.count == 1)
        if let snapshot = snapshots.first {
            #expect(try databaseValue(at: snapshot.appending(path: "Winston.store")) == "old")
        }
        #expect(!LibraryBackup.applyPendingRestoreIfNeeded(storeURL: store, coversDirectory: covers))
    }

    @Test func versionThreeRestoreReplacesBooksCoversAndJournalTogether() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(
            path: "RestoreManagedFiles-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let store = root.appending(path: "Winston.store")
        let covers = root.appending(path: "covers", directoryHint: .isDirectory)
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let managedFiles = root.appending(path: "ManagedFiles", directoryHint: .isDirectory)
        let journal = managedFiles.appending(path: "Journal", directoryHint: .isDirectory)
        let backups = root.appending(path: "backups", directoryHint: .isDirectory)
        for directory in [covers, books, journal, backups] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root); LibraryBackup.cancelPendingRestore() }

        try makeDatabase(at: store, value: "backed-up")
        try Data("backed-cover".utf8).write(to: covers.appending(path: "book.jpg"))
        try Data("backed-book".utf8).write(to: books.appending(path: "book.epub"))
        try Data("backed-journal".utf8).write(to: journal.appending(path: "pending.json"))
        let backup = try LibraryBackup.backup(
            storeURL: store,
            coversDirectory: covers,
            to: backups,
            booksDirectory: books,
            managedFilesDirectory: managedFiles
        )

        try fm.removeItem(at: store)
        try makeDatabase(at: store, value: "current")
        try fm.removeItem(at: covers)
        try fm.removeItem(at: books)
        try fm.removeItem(at: managedFiles)
        try fm.createDirectory(at: covers, withIntermediateDirectories: true)
        try fm.createDirectory(at: books, withIntermediateDirectories: true)
        try fm.createDirectory(at: journal, withIntermediateDirectories: true)
        try Data("current-cover".utf8).write(to: covers.appending(path: "current.jpg"))
        try Data("current-book".utf8).write(to: books.appending(path: "current.epub"))
        try Data("current-journal".utf8).write(to: journal.appending(path: "current.json"))

        LibraryBackup.requestRestore(from: backup)
        #expect(LibraryBackup.applyPendingRestoreIfNeeded(
            storeURL: store,
            coversDirectory: covers,
            booksDirectory: books,
            managedFilesDirectory: managedFiles
        ))

        #expect(try databaseValue(at: store) == "backed-up")
        #expect(try Data(contentsOf: covers.appending(path: "book.jpg")) == Data("backed-cover".utf8))
        #expect(try Data(contentsOf: books.appending(path: "book.epub")) == Data("backed-book".utf8))
        #expect(try Data(contentsOf: journal.appending(path: "pending.json")) == Data("backed-journal".utf8))
        #expect(!fm.fileExists(atPath: books.appending(path: "current.epub").path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: journal.appending(path: "current.json").path(percentEncoded: false)))
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

    @Test func versionTwoBackupUsesReadOnlyCompatibilityRestore() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "RestoreV2-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let store = root.appending(path: LibraryBackup.currentStoreName)
        let covers = root.appending(path: "covers", directoryHint: .isDirectory)
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let managedFiles = root.appending(path: "ManagedFiles", directoryHint: .isDirectory)
        let backup = root.appending(
            path: "Winston Backup 2026-01-01-000000",
            directoryHint: .isDirectory
        )
        for directory in [
            covers,
            books,
            managedFiles.appending(path: "Journal", directoryHint: .isDirectory),
            backup.appending(path: "covers", directoryHint: .isDirectory),
            backup.appending(path: "Books", directoryHint: .isDirectory),
            backup.appending(path: "ManagedFiles/Journal", directoryHint: .isDirectory),
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer {
            try? fileManager.removeItem(at: root)
            LibraryBackup.cancelPendingRestore()
        }

        try makeDatabase(at: store, value: "current")
        try makeDatabase(
            at: backup.appending(path: LibraryBackup.currentStoreName),
            value: "version-two"
        )
        try Data("v2-cover".utf8).write(to: backup.appending(path: "covers/book.jpg"))
        try Data("v2-book".utf8).write(to: backup.appending(path: "Books/book.epub"))
        try Data("v2-journal".utf8).write(
            to: backup.appending(path: "ManagedFiles/Journal/pending.json")
        )
        let legacyManifest: [String: Any] = [
            "formatVersion": 2,
            "includesManagedBookFiles": true,
            "includesManagedFileJournal": true,
        ]
        try JSONSerialization.data(withJSONObject: legacyManifest).write(
            to: backup.appending(path: LibraryBackup.manifestName)
        )

        LibraryBackup.requestRestore(from: backup)
        #expect(LibraryBackup.applyPendingRestoreIfNeeded(
            storeURL: store,
            coversDirectory: covers,
            booksDirectory: books,
            managedFilesDirectory: managedFiles
        ))
        #expect(try databaseValue(at: store) == "version-two")
        #expect(try Data(contentsOf: covers.appending(path: "book.jpg")) == Data("v2-cover".utf8))
        #expect(try Data(contentsOf: books.appending(path: "book.epub")) == Data("v2-book".utf8))
    }

    @Test func backupRetriesWhenCoverGenerationChangesDuringCopy() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "BackupCoverRace-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let store = root.appending(path: LibraryBackup.currentStoreName)
        let covers = root.appending(path: "covers", directoryHint: .isDirectory)
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let managedFiles = root.appending(path: "ManagedFiles", directoryHint: .isDirectory)
        let backups = root.appending(path: "backups", directoryHint: .isDirectory)
        for directory in [covers, books, managedFiles, backups] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try makeDatabase(at: store, value: "catalog")
        let cover = covers.appending(path: "book.jpg")
        try Data("old-cover".utf8).write(to: cover)
        defer { try? fileManager.removeItem(at: root) }

        var mutationCount = 0
        let hooks = LibrarySnapshotCoordinator.TestingHooks(
            event: { event in
                if case .capturedSourceGeneration(let component, let attempt) = event,
                   component == "covers", attempt == 1, mutationCount == 0 {
                    mutationCount += 1
                    try Data("new-cover".utf8).write(to: cover)
                }
            },
            availableCapacity: { _ in Int64.max }
        )
        let backup = try LibraryBackup.backup(
            storeURL: store,
            coversDirectory: covers,
            to: backups,
            booksDirectory: books,
            managedFilesDirectory: managedFiles,
            testingHooks: hooks
        )

        #expect(mutationCount == 1)
        #expect(
            try Data(contentsOf: backup.appending(path: "covers/book.jpg"))
                == Data("new-cover".utf8)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            LibrarySnapshotManifest.self,
            from: Data(contentsOf: backup.appending(path: LibraryBackup.manifestName))
        )
        #expect(manifest.coverGeneration.count == 64)
    }

    @Test func insufficientSpaceLeavesLiveLibraryAndPendingRequestIntact() throws {
        let fixture = try makeCompleteRestoreFixture(prefix: "RestoreNoSpace")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            LibraryBackup.cancelPendingRestore()
        }
        LibraryBackup.requestRestore(from: fixture.backup)
        let hooks = LibrarySnapshotCoordinator.TestingHooks(
            availableCapacity: { _ in 0 }
        )

        let outcome = LibraryBackup.restorePendingSnapshotIfNeeded(
            storeURL: fixture.store,
            coversDirectory: fixture.covers,
            booksDirectory: fixture.books,
            managedFilesDirectory: fixture.managedFiles,
            testingHooks: hooks
        )

        #expect(outcome == .retryPending)
        #expect(try databaseValue(at: fixture.store) == "current")
        #expect(
            UserDefaults.standard.string(forKey: LibraryBackup.pendingRestoreKey)
                == fixture.backup.path(percentEncoded: false)
        )
        #expect(!FileManager.default.fileExists(
            atPath: fixture.root.appending(path: ".WinstonRestoreJournal.json")
                .path(percentEncoded: false)
        ))
    }

    @Test func corruptVersionThreeManifestNeverTouchesLiveLibraryAndRemainsPending() throws {
        let fixture = try makeCompleteRestoreFixture(prefix: "RestoreManifestCorrupt")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            LibraryBackup.cancelPendingRestore()
        }
        let manifestURL = fixture.backup.appending(path: LibraryBackup.manifestName)
        var manifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        )
        manifest["catalogSchemaVersion"] = 999
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: manifestURL, options: .atomic)
        LibraryBackup.requestRestore(from: fixture.backup)

        #expect(!LibraryBackup.applyPendingRestoreIfNeeded(
            storeURL: fixture.store,
            coversDirectory: fixture.covers,
            booksDirectory: fixture.books,
            managedFilesDirectory: fixture.managedFiles
        ))
        #expect(try databaseValue(at: fixture.store) == "current")
        #expect(
            try Data(contentsOf: fixture.covers.appending(path: "current.jpg"))
                == Data("current-cover".utf8)
        )
        #expect(
            UserDefaults.standard.string(forKey: LibraryBackup.pendingRestoreKey)
                == fixture.backup.path(percentEncoded: false)
        )
    }

    @Test func restartCompletesRestoreAfterEveryIndividualInstallMove() throws {
        // Full v3 restore has ten actual renames when live SQLite sidecars are present:
        // old/new catalog, old WAL, old SHM, and old/new covers, books, and managed files.
        for interruptedMove in 1...10 {
            let fixture = try makeCompleteRestoreFixture(
                prefix: "RestoreCrash-\(interruptedMove)"
            )
            LibraryBackup.requestRestore(from: fixture.backup)
            var moveCount = 0
            var didInterrupt = false
            var addedSQLiteSidecars = false
            let hooks = LibrarySnapshotCoordinator.TestingHooks(
                event: { event in
                    switch event {
                    case .capturedSourceGeneration(let component, let attempt)
                        where component == "managed files"
                            && attempt == 1
                            && !addedSQLiteSidecars:
                        // This event occurs during the safety snapshot, before the prepared
                        // component set is captured and after SQLite has finished reading live.
                        addedSQLiteSidecars = true
                        try Data("live-wal".utf8).write(
                            to: URL(fileURLWithPath:
                                fixture.store.path(percentEncoded: false) + "-wal")
                        )
                        try Data("live-shm".utf8).write(
                            to: URL(fileURLWithPath:
                                fixture.store.path(percentEncoded: false) + "-shm")
                        )
                    case .movedLive, .installed:
                        moveCount += 1
                        if moveCount == interruptedMove {
                            didInterrupt = true
                            throw LibrarySnapshotCoordinator.SimulatedCrash()
                        }
                    default:
                        break
                    }
                },
                availableCapacity: { _ in Int64.max }
            )

            let interrupted = LibraryBackup.restorePendingSnapshotIfNeeded(
                storeURL: fixture.store,
                coversDirectory: fixture.covers,
                booksDirectory: fixture.books,
                managedFilesDirectory: fixture.managedFiles,
                testingHooks: hooks
            )
            if case .blocked = interrupted {
                // Expected: a process crash would stop here before the caller can open the store.
            } else {
                Issue.record("move \(interruptedMove) did not leave a recoverable transaction")
            }
            #expect(didInterrupt)
            #expect(addedSQLiteSidecars)
            #expect(UserDefaults.standard.string(
                forKey: LibraryBackup.pendingRestoreKey
            ) != nil)
            #expect(FileManager.default.fileExists(
                atPath: fixture.root.appending(path: ".WinstonRestoreJournal.json")
                    .path(percentEncoded: false)
            ))

            let resumed = LibraryBackup.restorePendingSnapshotIfNeeded(
                storeURL: fixture.store,
                coversDirectory: fixture.covers,
                booksDirectory: fixture.books,
                managedFilesDirectory: fixture.managedFiles
            )
            #expect(resumed == .committed)
            #expect(try databaseValue(at: fixture.store) == "restored")
            #expect(
                try Data(contentsOf: fixture.covers.appending(path: "book.jpg"))
                    == Data("restored-cover".utf8)
            )
            #expect(!FileManager.default.fileExists(
                atPath: fixture.store.path(percentEncoded: false) + "-wal"
            ))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.store.path(percentEncoded: false) + "-shm"
            ))
            #expect(UserDefaults.standard.string(
                forKey: LibraryBackup.pendingRestoreKey
            ) == nil)
            #expect(!FileManager.default.fileExists(
                atPath: fixture.root.appending(path: ".WinstonRestoreJournal.json")
                    .path(percentEncoded: false)
            ))

            try FileManager.default.removeItem(at: fixture.root)
            LibraryBackup.cancelPendingRestore()
        }
    }

    @Test func restartCompletesRollbackAfterEveryIndividualRollbackMove() throws {
        // A fully installed v3 set has eight rollback renames: replacement/original pairs
        // for catalog, covers, books, and managed files.
        for interruptedMove in 1...8 {
            let fixture = try makeCompleteRestoreFixture(
                prefix: "RestoreRollbackCrash-\(interruptedMove)"
            )
            LibraryBackup.requestRestore(from: fixture.backup)
            var rollbackMoveCount = 0
            var injectedInstallFailure = false
            var didInterruptRollback = false
            let hooks = LibrarySnapshotCoordinator.TestingHooks(
                event: { event in
                    switch event {
                    case .installed(let component)
                        where component == "managedFiles" && !injectedInstallFailure:
                        injectedInstallFailure = true
                        throw CocoaError(.fileWriteUnknown)
                    case .rollbackMoved:
                        rollbackMoveCount += 1
                        if rollbackMoveCount == interruptedMove {
                            didInterruptRollback = true
                            throw LibrarySnapshotCoordinator.SimulatedCrash()
                        }
                    default:
                        break
                    }
                },
                availableCapacity: { _ in Int64.max }
            )

            let interrupted = LibraryBackup.restorePendingSnapshotIfNeeded(
                storeURL: fixture.store,
                coversDirectory: fixture.covers,
                booksDirectory: fixture.books,
                managedFilesDirectory: fixture.managedFiles,
                testingHooks: hooks
            )
            if case .blocked = interrupted {
                // Expected: the rollingBack journal owns all live paths until restart.
            } else {
                Issue.record(
                    "rollback move \(interruptedMove) did not leave a recoverable transaction"
                )
            }
            #expect(injectedInstallFailure)
            #expect(didInterruptRollback)

            #expect(LibraryBackup.restorePendingSnapshotIfNeeded(
                storeURL: fixture.store,
                coversDirectory: fixture.covers,
                booksDirectory: fixture.books,
                managedFilesDirectory: fixture.managedFiles
            ) == .retryPending)
            #expect(try databaseValue(at: fixture.store) == "current")
            #expect(
                try Data(contentsOf: fixture.covers.appending(path: "current.jpg"))
                    == Data("current-cover".utf8)
            )
            #expect(UserDefaults.standard.string(
                forKey: LibraryBackup.pendingRestoreKey
            ) != nil)
            #expect(!FileManager.default.fileExists(
                atPath: fixture.root.appending(path: ".WinstonRestoreJournal.json")
                    .path(percentEncoded: false)
            ))

            try FileManager.default.removeItem(at: fixture.root)
            LibraryBackup.cancelPendingRestore()
        }
    }

    @Test func failureAfterFinalValidationRollsBackAndKeepsPendingRequest() throws {
        let fixture = try makeCompleteRestoreFixture(prefix: "RestorePublishFailure")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            LibraryBackup.cancelPendingRestore()
        }
        LibraryBackup.requestRestore(from: fixture.backup)
        var injected = false
        let hooks = LibrarySnapshotCoordinator.TestingHooks(
            event: { event in
                if event == .validated, !injected {
                    injected = true
                    throw CocoaError(.fileWriteUnknown)
                }
            },
            availableCapacity: { _ in Int64.max }
        )

        #expect(LibraryBackup.restorePendingSnapshotIfNeeded(
            storeURL: fixture.store,
            coversDirectory: fixture.covers,
            booksDirectory: fixture.books,
            managedFilesDirectory: fixture.managedFiles,
            testingHooks: hooks
        ) == .retryPending)
        #expect(injected)
        #expect(try databaseValue(at: fixture.store) == "current")
        #expect(
            try Data(contentsOf: fixture.covers.appending(path: "current.jpg"))
                == Data("current-cover".utf8)
        )
        #expect(UserDefaults.standard.string(
            forKey: LibraryBackup.pendingRestoreKey
        ) != nil)
    }

    @Test func pendingMarkerSurvivesCrashAfterCommittedJournalPublish() throws {
        let fixture = try makeCompleteRestoreFixture(prefix: "RestoreCommitCrash")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            LibraryBackup.cancelPendingRestore()
        }
        LibraryBackup.requestRestore(from: fixture.backup)
        let hooks = LibrarySnapshotCoordinator.TestingHooks(
            event: { event in
                if event == .committed {
                    throw LibrarySnapshotCoordinator.SimulatedCrash()
                }
            },
            availableCapacity: { _ in Int64.max }
        )

        let interrupted = LibraryBackup.restorePendingSnapshotIfNeeded(
            storeURL: fixture.store,
            coversDirectory: fixture.covers,
            booksDirectory: fixture.books,
            managedFilesDirectory: fixture.managedFiles,
            testingHooks: hooks
        )
        if case .blocked = interrupted {
            // The committed journal is the durable source of truth on the next launch.
        } else {
            Issue.record("commit interruption was not retained for launch recovery")
        }
        let journalURL = fixture.root.appending(path: ".WinstonRestoreJournal.json")
        let journal = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL))
                as? [String: Any]
        )
        #expect(journal["state"] as? String == "committed")
        #expect(UserDefaults.standard.string(
            forKey: LibraryBackup.pendingRestoreKey
        ) != nil)

        #expect(LibraryBackup.restorePendingSnapshotIfNeeded(
            storeURL: fixture.store,
            coversDirectory: fixture.covers,
            booksDirectory: fixture.books,
            managedFilesDirectory: fixture.managedFiles
        ) == .committed)
        #expect(UserDefaults.standard.string(
            forKey: LibraryBackup.pendingRestoreKey
        ) == nil)
        #expect(!FileManager.default.fileExists(atPath: journalURL.path(percentEncoded: false)))
    }

    @Test func crashDuringPreparationIsDiscardedWithoutTouchingLivePaths() throws {
        let fixture = try makeCompleteRestoreFixture(prefix: "RestorePreparationCrash")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            LibraryBackup.cancelPendingRestore()
        }
        LibraryBackup.requestRestore(from: fixture.backup)
        let hooks = LibrarySnapshotCoordinator.TestingHooks(
            event: { event in
                if case .capturedSourceGeneration(let component, let attempt) = event,
                   component == "backup package", attempt == 1 {
                    throw LibrarySnapshotCoordinator.SimulatedCrash()
                }
            },
            availableCapacity: { _ in Int64.max }
        )

        let interrupted = LibraryBackup.restorePendingSnapshotIfNeeded(
            storeURL: fixture.store,
            coversDirectory: fixture.covers,
            booksDirectory: fixture.books,
            managedFilesDirectory: fixture.managedFiles,
            testingHooks: hooks
        )
        if case .blocked = interrupted {
            // Expected.
        } else {
            Issue.record("preparation interruption did not leave its durable ownership journal")
        }
        let journalURL = fixture.root.appending(path: ".WinstonRestoreJournal.json")
        let journal = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL))
                as? [String: Any]
        )
        #expect(journal["state"] as? String == "preparing")
        #expect(try databaseValue(at: fixture.store) == "current")

        #expect(LibraryBackup.restorePendingSnapshotIfNeeded(
            storeURL: fixture.store,
            coversDirectory: fixture.covers,
            booksDirectory: fixture.books,
            managedFilesDirectory: fixture.managedFiles
        ) == .retryPending)
        #expect(!FileManager.default.fileExists(atPath: journalURL.path(percentEncoded: false)))
        #expect(try databaseValue(at: fixture.store) == "current")

        #expect(LibraryBackup.restorePendingSnapshotIfNeeded(
            storeURL: fixture.store,
            coversDirectory: fixture.covers,
            booksDirectory: fixture.books,
            managedFilesDirectory: fixture.managedFiles
        ) == .committed)
        #expect(try databaseValue(at: fixture.store) == "restored")
    }

    @Test func readOnlySourceBackupUsesLocalSafetySnapshotFallback() throws {
        let fixture = try makeCompleteRestoreFixture(prefix: "RestoreReadOnlySource")
        let sourceFolder = fixture.backup.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: sourceFolder.path(percentEncoded: false)
            )
            try? FileManager.default.removeItem(at: fixture.root)
            LibraryBackup.cancelPendingRestore()
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: sourceFolder.path(percentEncoded: false)
        )
        LibraryBackup.requestRestore(from: fixture.backup)

        #expect(LibraryBackup.restorePendingSnapshotIfNeeded(
            storeURL: fixture.store,
            coversDirectory: fixture.covers,
            booksDirectory: fixture.books,
            managedFilesDirectory: fixture.managedFiles
        ) == .committed)
        #expect(try databaseValue(at: fixture.store) == "restored")
        let safetyFolder = fixture.root.appending(
            path: "Restore Safety Backups",
            directoryHint: .isDirectory
        )
        #expect(LibraryBackup.availableBackups(in: safetyFolder).count == 1)
    }

    @Test func ordinaryMoveFailureRollsBackAndRetriesOnNextStartup() throws {
        let fixture = try makeCompleteRestoreFixture(prefix: "RestoreMoveFailure")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            LibraryBackup.cancelPendingRestore()
        }
        LibraryBackup.requestRestore(from: fixture.backup)
        var injected = false
        let hooks = LibrarySnapshotCoordinator.TestingHooks(
            event: { event in
                if case .movedLive(let component) = event,
                   component == "catalog", !injected {
                    injected = true
                    throw CocoaError(.fileWriteUnknown)
                }
            },
            availableCapacity: { _ in Int64.max }
        )

        #expect(LibraryBackup.restorePendingSnapshotIfNeeded(
            storeURL: fixture.store,
            coversDirectory: fixture.covers,
            booksDirectory: fixture.books,
            managedFilesDirectory: fixture.managedFiles,
            testingHooks: hooks
        ) == .retryPending)
        #expect(injected)
        #expect(try databaseValue(at: fixture.store) == "current")
        #expect(
            try Data(contentsOf: fixture.covers.appending(path: "current.jpg"))
                == Data("current-cover".utf8)
        )
        #expect(UserDefaults.standard.string(
            forKey: LibraryBackup.pendingRestoreKey
        ) != nil)

        #expect(LibraryBackup.restorePendingSnapshotIfNeeded(
            storeURL: fixture.store,
            coversDirectory: fixture.covers,
            booksDirectory: fixture.books,
            managedFilesDirectory: fixture.managedFiles
        ) == .committed)
        #expect(try databaseValue(at: fixture.store) == "restored")
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
        #expect(UserDefaults.standard.string(forKey: LibraryBackup.pendingRestoreKey) != nil)
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
        #expect(UserDefaults.standard.string(forKey: LibraryBackup.pendingRestoreKey) != nil)
    }
}
