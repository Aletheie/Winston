import Foundation
import Testing
@testable import Winston

@MainActor
@Suite(.serialized)
struct LibraryReadModelTests {
    @Test func recordUsesPersistedAvailabilityWithoutFilesystemValidation() {
        let id = UUID()
        let book = Book(
            uuid: id,
            fileName: "\(id.uuidString).epub",
            originalFileName: "Missing on disk.epub"
        )

        let record = LibraryDisplaySnapshot(
            book,
            sourceOrdinal: 0,
            includeCollections: true,
            includeHighlights: true
        )

        #expect(record.format == "EPUB")
        #expect(record.search.format == "epub")
        #expect(record.smartShelf.deviceMatchKeys.contains("missing on disk"))
        #expect(!record.smartShelf.deviceMatchKeys.contains("physical:\(id.uuidString.lowercased())"))
    }

    @Test func oneStatusMutationCapturesOneRecordAndUpdatesFacets() async {
        let books = makeBooks(1_000)
        let changed = books[537]
        let model = LibraryReadModel()
        await bootstrap(model, books: books)
        let generation = model.generation
        let originalIDs = await model.displayIDs(query: allBooksQuery)

        changed.readingStatus = .reading
        await model.synchronize(
            books: books,
            collections: [],
            delta: LibraryCatalogDelta(
                fromRevision: 0,
                toRevision: 1,
                affectedBookIDs: [changed.uuid],
                affectedCollectionIDs: [],
                requiresFullRebuild: false,
                changesBookMembership: false
            ),
            deviceFileNames: [],
            deviceIsConnected: false
        )

        #expect(model.diagnostics.fullRebuildCount == 1)
        #expect(model.diagnostics.lastCapturedRecordCount == 1)
        #expect(model.facets.statusCounts[.reading] == 1)
        #expect(model.facets.statusCounts[.unread] == 999)

        let delta = model.displayDelta(since: generation)
        let incremental = model.incrementallyUpdatingDisplayIDs(
            originalIDs,
            with: delta,
            query: allBooksQuery
        )
        #expect(incremental?.ids == originalIDs)
        #expect(incremental?.changed == false)
    }

    @Test func statusFilterRemovesOnlyTheChangedBook() async throws {
        let books = makeBooks(100)
        let changed = books[42]
        let model = LibraryReadModel()
        await bootstrap(model, books: books)
        let query = LibraryDisplayQuery(
            filter: .status(.unread),
            searchText: "",
            sort: .sourceOrder,
            savedSearch: nil,
            smartShelf: nil,
            deviceFileNames: [],
            deviceIsConnected: false,
            kindlePresenceFilter: .all
        )
        let generation = model.generation
        let originalIDs = await model.displayIDs(query: query)

        changed.readingStatus = .reading
        await model.synchronize(
            books: books,
            collections: [],
            delta: LibraryCatalogDelta(
                fromRevision: 0,
                toRevision: 1,
                affectedBookIDs: [changed.uuid],
                affectedCollectionIDs: [],
                requiresFullRebuild: false,
                changesBookMembership: false
            ),
            deviceFileNames: [],
            deviceIsConnected: false
        )

        let incremental = try #require(
            model.incrementallyUpdatingDisplayIDs(
                originalIDs,
                with: model.displayDelta(since: generation),
                query: query
            )
        )
        let rebuilt = await model.displayIDs(query: query)
        #expect(incremental.ids == rebuilt)
        #expect(incremental.changed)
        #expect(incremental.ids.count == 99)
        #expect(!incremental.ids.contains(changed.uuid))
    }

    @Test func smartShelfCountChangesIncrementally() async {
        let books = makeBooks(20)
        let collection = BookCollection(name: "Unread")
        collection.smartShelfDefinition = SmartShelfDefinition(rules: [
            SmartShelfRule(
                field: .readingStatus,
                value: ReadingStatus.unread.rawValue
            ),
        ])
        let model = LibraryReadModel()
        await model.synchronize(
            books: books,
            collections: [collection],
            delta: fullDelta(to: 0),
            deviceFileNames: [],
            deviceIsConnected: false
        )
        #expect(model.facets.smartCounts[collection.id] == 20)

        books[0].readingStatus = .finished
        await model.synchronize(
            books: books,
            collections: [collection],
            delta: LibraryCatalogDelta(
                fromRevision: 0,
                toRevision: 1,
                affectedBookIDs: [books[0].uuid],
                affectedCollectionIDs: [],
                requiresFullRebuild: false,
                changesBookMembership: false
            ),
            deviceFileNames: [],
            deviceIsConnected: false
        )

        #expect(model.facets.smartCounts[collection.id] == 19)
        #expect(model.diagnostics.lastCapturedRecordCount == 1)
    }

    @Test(arguments: [1_000, 10_000, 50_000])
    func lightweightRecordFilteringBenchmark(_ count: Int) async {
        let records = makeRecords(count)
        let clock = ContinuousClock()
        let startedAt = clock.now
        let ids = await LibraryQuery.displayIDsConcurrently(
            for: records,
            filter: .all,
            searchText: "",
            sort: .sourceOrder,
            savedSearch: nil,
            smartShelf: nil,
            deviceFileNames: [],
            deviceIsConnected: false
        )
        let elapsed = startedAt.duration(to: clock.now)

        print("Library read-model filter benchmark (\(count) records): \(elapsed)")
        #expect(ids.count == count)
        #expect(elapsed < .seconds(1))
    }

    private var allBooksQuery: LibraryDisplayQuery {
        LibraryDisplayQuery(
            filter: .all,
            searchText: "",
            sort: .sourceOrder,
            savedSearch: nil,
            smartShelf: nil,
            deviceFileNames: [],
            deviceIsConnected: false,
            kindlePresenceFilter: .all
        )
    }

    private func bootstrap(
        _ model: LibraryReadModel,
        books: [Book]
    ) async {
        await model.synchronize(
            books: books,
            collections: [],
            delta: fullDelta(to: 0),
            deviceFileNames: [],
            deviceIsConnected: false
        )
    }

    private func fullDelta(to revision: Int) -> LibraryCatalogDelta {
        LibraryCatalogDelta(
            fromRevision: 0,
            toRevision: revision,
            affectedBookIDs: [],
            affectedCollectionIDs: [],
            requiresFullRebuild: true,
            changesBookMembership: true
        )
    }

    private func makeBooks(_ count: Int) -> [Book] {
        (0..<count).map { index in
            let book = Book(
                fileName: "book-\(index).epub",
                originalFileName: "Book \(index).epub",
                dateAdded: Date(timeIntervalSince1970: TimeInterval(index))
            )
            book.title = "Book \(index)"
            book.author = "Author \(index % 250)"
            book.tags = ["tag-\(index % 50)"]
            return book
        }
    }

    private func makeRecords(_ count: Int) -> [LibraryDisplaySnapshot] {
        let search = LibraryQuery.SearchSnapshot(
            title: "book",
            author: "author",
            tags: ["tag"],
            format: "epub"
        )
        return (0..<count).map { index in
            let id = UUID()
            return LibraryDisplaySnapshot(
                id: id,
                sourceOrdinal: index,
                displayTitle: "Book",
                displayAuthor: "Author",
                dateAdded: Date(timeIntervalSince1970: TimeInterval(index)),
                rating: 0,
                readingStatus: .unread,
                format: "EPUB",
                tags: ["tag"],
                series: nil,
                seriesIndex: .greatestFiniteMagnitude,
                collectionIDs: [],
                search: search,
                smartShelf: SmartShelfBookSnapshot(
                    id: id,
                    title: "Book",
                    author: "Author",
                    format: "EPUB"
                )
            )
        }
    }
}
