import Foundation
import SwiftData
import Testing
@testable import Winston

@MainActor
struct LibraryTimeMachineTests {
    @Test func diffClassifiesDeletedModifiedAddedAndUnchangedBooks() throws {
        let deletedID = UUID()
        let modifiedID = UUID()
        let addedID = UUID()
        let unchangedID = UUID()

        let deleted = snapshot(id: deletedID, title: "Deleted")
        let backupModified = snapshot(
            id: modifiedID,
            title: "Older Title",
            coverURL: URL(filePath: "/tmp/backup-cover.jpg"),
            coverVersion: 1
        )
        let currentModified = snapshot(
            id: modifiedID,
            title: "Current Title",
            coverURL: URL(filePath: "/tmp/current-cover.jpg"),
            coverVersion: 2
        )
        let unchanged = snapshot(id: unchangedID, title: "Same")
        let added = snapshot(id: addedID, title: "Added")

        let diffs = LibraryTimeMachineDiffBuilder.compare(
            backupBooks: [deleted, backupModified, unchanged],
            currentBooks: [currentModified, unchanged, added]
        )
        let byID = Dictionary(uniqueKeysWithValues: diffs.map { ($0.id, $0) })

        #expect(byID[deletedID]?.kind == .deletedSinceBackup)
        #expect(byID[deletedID]?.canRestore == true)
        #expect(byID[modifiedID]?.kind == .modified)
        #expect(byID[modifiedID]?.changeGroups == [.metadata, .cover])
        #expect(byID[modifiedID]?.fieldChanges.map(\.field) == [.title])
        #expect(byID[addedID]?.kind == .addedSinceBackup)
        #expect(byID[addedID]?.canRestore == false)
        #expect(byID[unchangedID]?.kind == .unchanged)
    }

    @Test func fileRecordOnlyDifferenceIsVisibleButNotRestorable() {
        let id = UUID()
        let backup = snapshot(id: id, title: "Book", fileName: "old.epub")
        let current = snapshot(id: id, title: "Book", fileName: "new.epub")

        let diff = LibraryTimeMachineDiffBuilder.compare(
            backupBooks: [backup],
            currentBooks: [current]
        ).first

        #expect(diff?.kind == .modified)
        #expect(diff?.changeGroups == [.fileRecord])
        #expect(diff?.canRestore == false)
    }

    @Test func coverVersionOnlyMattersWhenBothSnapshotsHaveACover() {
        let id = UUID()
        let withoutCover = snapshot(id: id, title: "Book", coverVersion: 1)
        let newerWithoutCover = snapshot(id: id, title: "Book", coverVersion: 2)

        let unchanged = LibraryTimeMachineDiffBuilder.compare(
            backupBooks: [withoutCover],
            currentBooks: [newerWithoutCover]
        ).first

        #expect(unchanged?.kind == .unchanged)
    }

    @Test func diffScalesToLargeLibraries() {
        let ids = (0..<10_000).map { _ in UUID() }
        let backup = ids.enumerated().map { index, id in
            snapshot(id: id, title: "Book \(index)")
        }
        var current = backup
        current[5_000].metadata.title = "Changed Book"

        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = LibraryTimeMachineDiffBuilder.compare(
            backupBooks: backup,
            currentBooks: current
        )
        let elapsed = startedAt.duration(to: clock.now)

        print("Library Time Machine diff benchmark: \(elapsed)")
        #expect(result.count == 10_000)
        #expect(result.count { $0.kind == .modified } == 1)
        #expect(elapsed < .seconds(2))
    }

    @Test func currentSnapshotResolvesFilesAndCoversWithoutChangingModelData() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WinstonTimeMachineSnapshot-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let booksDirectory = root.appending(path: "books", directoryHint: .isDirectory)
        let coversDirectory = root.appending(path: "covers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let book = Book(fileName: "present.epub", originalFileName: "Present.epub")
        book.title = "Present"
        try Data("book".utf8).write(to: booksDirectory.appending(path: book.fileName))
        try Data("cover".utf8).write(
            to: coversDirectory.appending(path: "\(book.uuid.uuidString).jpg")
        )

        let snapshots = await LibraryTimeMachineDiffBuilder.snapshotCurrentBooks(
            [book],
            currentCoversDirectory: coversDirectory,
            currentBooksDirectory: booksDirectory
        )
        let snapshot = try #require(snapshots.first)

        #expect(snapshot.metadata.title == "Present")
        #expect(snapshot.bookFileExists)
        #expect(snapshot.hasCover)
    }

    @Test func technicalLookupStateIsIgnoredButVisibleRatingDataIsCompared() {
        let id = UUID()
        var backup = snapshot(id: id, title: "Book")
        var current = snapshot(id: id, title: "Book")
        backup.metadata.onlineLookupAt = Date(timeIntervalSince1970: 100)
        backup.metadata.onlineLookupConfiguration = "old-provider"
        backup.metadata.sampleNoticeDismissed = false
        current.metadata.onlineLookupAt = Date(timeIntervalSince1970: 200)
        current.metadata.onlineLookupConfiguration = "new-provider"
        current.metadata.sampleNoticeDismissed = true

        let cacheOnly = LibraryTimeMachineDiffBuilder.compare(
            backupBooks: [backup],
            currentBooks: [current]
        ).first
        #expect(cacheOnly?.kind == .unchanged)

        current.metadata.communityRatingCount = 42
        let visibleChange = LibraryTimeMachineDiffBuilder.compare(
            backupBooks: [backup],
            currentBooks: [current]
        ).first
        #expect(visibleChange?.changeGroups == [.metadata])
        #expect(visibleChange?.fieldChanges.map(\.field) == [.communityRatingCount])
    }

    @Test func readerLoadsRelationshipsAndCoverFromRealBackup() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "WinstonTimeMachineReader-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let live = root.appending(path: "live", directoryHint: .isDirectory)
        let store = live.appending(path: LibraryBackup.currentStoreName)
        let covers = live.appending(path: "covers", directoryHint: .isDirectory)
        let backups = root.appending(path: "backups", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: covers, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: backups, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let container = try makeContainer(at: store)
        let context = container.mainContext
        let bookID = UUID()
        let book = Book(
            uuid: bookID,
            fileName: "archive.epub",
            originalFileName: "Archive.epub",
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        book.title = "Archived Book"
        book.author = "Ada Reader"
        book.tags = ["History", "Local"]
        book.readingStatusRaw = ReadingStatus.finished.rawValue
        let session = ReadingSession(
            uuid: UUID(),
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 300),
            status: .finished,
            progress: 1,
            book: book
        )
        let highlight = Highlight(
            text: "Remember this",
            isNote: false,
            location: "Chapter 2",
            addedDate: Date(timeIntervalSince1970: 250)
        )
        highlight.book = book
        let collection = BookCollection(name: "Research")
        collection.books.append(book)
        let work = Work(title: "Archived Work", author: "Ada Reader")
        book.work = work
        let asset = BookAsset(
            fileName: "archive.epub",
            origin: .original,
            contentHash: "content-hash",
            sizeBytes: 42,
            book: book
        )
        context.insert(book)
        context.insert(session)
        context.insert(highlight)
        context.insert(collection)
        context.insert(work)
        context.insert(asset)
        try context.save()

        let coverData = Data("backup-cover".utf8)
        try coverData.write(to: covers.appending(path: "\(bookID.uuidString).jpg"))
        let backup = try LibraryBackup.backup(
            storeURL: store,
            coversDirectory: covers,
            to: backups,
            keepLast: 5
        )

        let loaded = try LibraryTimeMachineReader.load(backup)
        let archived = try #require(loaded.books.first { $0.id == bookID })
        #expect(archived.metadata.title == "Archived Book")
        #expect(archived.metadata.tags == ["History", "Local"])
        #expect(archived.reading.sessions.count == 1)
        #expect(archived.highlights.map(\.text) == ["Remember this"])
        #expect(archived.collections.map(\.name) == ["Research"])
        #expect(archived.work?.title == "Archived Work")
        #expect(archived.assets.map(\.contentHash) == ["content-hash"])
        #expect(archived.hasCover)
    }

    @Test func metadataRestoreLeavesReadingHistoryAndCoverUntouched() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "WinstonMetadataRestore-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let covers = root.appending(path: "covers", directoryHint: .isDirectory)
        let sourceBackup = root.appending(path: "Winston Backup 2026-01-01-000000")
        let safetyBackup = root.appending(path: "Winston Backup 2026-07-16-120000")
        try fileManager.createDirectory(at: covers, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let id = UUID()
        let book = Book(uuid: id, fileName: "book.epub", originalFileName: "Book.epub")
        book.title = "Current Title"
        book.author = "Current Author"
        let currentSession = ReadingSession(status: .reading, progress: 0.4, book: book)
        context.insert(book)
        context.insert(currentSession)
        try context.save()
        let currentCover = Data("current-cover".utf8)
        try currentCover.write(to: covers.appending(path: "\(id.uuidString).jpg"))

        let backup = snapshot(
            id: id,
            title: "Backup Title",
            author: "Backup Author",
            reading: LibraryTimeMachineReadingSnapshot(
                statusRaw: ReadingStatus.finished.rawValue,
                sessions: [
                    LibraryTimeMachineReadingSessionSnapshot(
                        id: UUID(),
                        startedAt: .distantPast,
                        endedAt: .distantPast,
                        statusRaw: ReadingSessionStatus.finished.rawValue,
                        progress: 1
                    ),
                ]
            )
        )
        let restorer = LibraryTimeMachineRestorer(
            modelContext: context,
            coversDirectory: covers,
            createSafetyBackup: { _ in safetyBackup }
        )
        let result = try await restorer.restore(
            backup,
            scope: .metadata,
            from: sourceBackup
        )

        #expect(book.title == "Backup Title")
        #expect(book.author == "Backup Author")
        #expect(book.readingSessions.count == 1)
        #expect(book.readingSessions.first?.id == currentSession.id)
        #expect(try Data(contentsOf: covers.appending(path: "\(id.uuidString).jpg")) == currentCover)
        #expect(result.safetyBackupURL == safetyBackup)
    }

    @Test func coverRestoreChangesOnlyCoverAndInvalidatesVersion() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "WinstonCoverRestore-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let covers = root.appending(path: "covers", directoryHint: .isDirectory)
        let backupCover = root.appending(path: "backup.jpg")
        let sourceBackup = root.appending(path: "Winston Backup 2026-01-01-000000")
        try fileManager.createDirectory(at: covers, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let id = UUID()
        let book = Book(uuid: id, fileName: "book.epub", originalFileName: "Book.epub")
        book.title = "Keep This Title"
        book.coverVersion = 3
        context.insert(book)
        try context.save()
        try Data("current".utf8).write(to: covers.appending(path: "\(id.uuidString).jpg"))
        let restoredData = Data("restored".utf8)
        try restoredData.write(to: backupCover)

        var backup = snapshot(
            id: id,
            title: "Ignored Backup Title",
            coverURL: backupCover
        )
        backup.coverVersion = 2
        let restorer = LibraryTimeMachineRestorer(
            modelContext: context,
            coversDirectory: covers,
            createSafetyBackup: { _ in sourceBackup }
        )
        _ = try await restorer.restore(backup, scope: .cover, from: sourceBackup)

        #expect(book.title == "Keep This Title")
        #expect(book.coverVersion == 4)
        #expect(try Data(contentsOf: covers.appending(path: "\(id.uuidString).jpg")) == restoredData)
    }

    @Test func wholeBookRestoreRecreatesDeletedCatalogRecordAndPersonalData() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WinstonBookRestore-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let covers = root.appending(path: "covers", directoryHint: .isDirectory)
        let sourceBackup = root.appending(path: "Winston Backup 2026-01-01-000000")
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let collection = BookCollection(name: "Favorites")
        context.insert(collection)
        try context.save()

        let id = UUID()
        let sessionID = UUID()
        let assetID = UUID()
        let backup = LibraryTimeMachineBookSnapshot(
            id: id,
            fileName: "deleted.epub",
            originalFileName: "Deleted.epub",
            dateAdded: Date(timeIntervalSince1970: 500),
            fileSizeBytes: 99,
            metadata: LibraryTimeMachineMetadataSnapshot(
                title: "Recovered Book",
                author: "Recovered Author",
                tags: ["Recovered"],
                notes: "Personal note"
            ),
            reading: LibraryTimeMachineReadingSnapshot(
                statusRaw: ReadingStatus.finished.rawValue,
                dateStarted: Date(timeIntervalSince1970: 600),
                dateFinished: Date(timeIntervalSince1970: 700),
                sessions: [
                    LibraryTimeMachineReadingSessionSnapshot(
                        id: sessionID,
                        startedAt: Date(timeIntervalSince1970: 600),
                        endedAt: Date(timeIntervalSince1970: 700),
                        statusRaw: ReadingSessionStatus.finished.rawValue,
                        progress: 1
                    ),
                ]
            ),
            highlights: [
                LibraryTimeMachineHighlightSnapshot(
                    text: "Recovered highlight",
                    kindRaw: "highlight",
                    location: "12",
                    addedDate: nil,
                    dateImported: Date(timeIntervalSince1970: 650)
                ),
            ],
            collections: [
                LibraryTimeMachineCollectionSnapshot(
                    id: collection.id,
                    name: collection.name,
                    dateCreated: collection.dateCreated,
                    savedSearch: nil,
                    smartShelfRulesData: nil,
                    systemKindRaw: nil
                ),
            ],
            assets: [
                LibraryTimeMachineAssetSnapshot(
                    id: assetID,
                    fileName: "deleted.epub",
                    originRaw: AssetOrigin.original.rawValue,
                    contentHash: "old-hash",
                    generatedFromContentHash: nil,
                    sizeBytes: 99,
                    dateAdded: Date(timeIntervalSince1970: 500),
                    validationStatusRaw: AssetValidation.missing.rawValue
                ),
            ]
        )
        let restorer = LibraryTimeMachineRestorer(
            modelContext: context,
            coversDirectory: covers,
            createSafetyBackup: { _ in sourceBackup }
        )
        let result = try await restorer.restore(backup, scope: .book, from: sourceBackup)

        let restored = try #require(context.allBooks().first { $0.uuid == id })
        #expect(result.createdBook)
        #expect(result.bookFileMissing)
        #expect(restored.title == "Recovered Book")
        #expect(restored.notes == "Personal note")
        #expect(restored.readingSessions.map(\.uuid) == [sessionID])
        #expect(restored.highlights.map(\.text) == ["Recovered highlight"])
        #expect(restored.collections.map(\.id) == [collection.id])
        #expect(restored.assets.map(\.uuid) == [assetID])
    }

    @Test func failedSafetyBackupPreventsAnyMutation() async throws {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let id = UUID()
        let book = Book(uuid: id, fileName: "book.epub", originalFileName: "Book.epub")
        book.title = "Current"
        context.insert(book)
        try context.save()

        let restorer = LibraryTimeMachineRestorer(
            modelContext: context,
            createSafetyBackup: { _ in throw TimeMachineTestError.expected }
        )
        let backup = snapshot(id: id, title: "Backup")

        await #expect(throws: LibraryTimeMachineRestoreError.self) {
            try await restorer.restore(
                backup,
                scope: .metadata,
                from: URL(filePath: "/tmp/source-backup")
            )
        }
        #expect(book.title == "Current")
    }

    private func snapshot(
        id: UUID,
        title: String,
        author: String? = nil,
        fileName: String = "book.epub",
        coverURL: URL? = nil,
        coverVersion: Int = 0,
        reading: LibraryTimeMachineReadingSnapshot = .init()
    ) -> LibraryTimeMachineBookSnapshot {
        LibraryTimeMachineBookSnapshot(
            id: id,
            fileName: fileName,
            originalFileName: fileName,
            coverVersion: coverVersion,
            metadata: LibraryTimeMachineMetadataSnapshot(title: title, author: author),
            reading: reading,
            coverURL: coverURL
        )
    }

    private func makeContainer(at url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Work.self, Book.self, ReadingSession.self, BookAsset.self,
            BookCollection.self, Highlight.self, WishlistItem.self,
            LibraryNotice.self, SeriesCatalogSnapshot.self,
            configurations: ModelConfiguration(url: url)
        )
    }
}

private enum TimeMachineTestError: Error {
    case expected
}
