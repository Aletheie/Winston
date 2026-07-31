import Foundation
import Observation
import Testing
@testable import Winston

private actor ReadModelSynchronizationGate {
    private let blockedGeneration: Int
    private var didEnter = false
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(blockedGeneration: Int) {
        self.blockedGeneration = blockedGeneration
    }

    func pauseIfNeeded(generation: Int) async {
        guard generation == blockedGeneration else { return }
        didEnter = true
        entryContinuation?.resume()
        entryContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            entryContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

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

        let record = LibraryBookRecord(
            book,
            sourceOrdinal: 0,
            includeCollections: true,
            includeHighlights: true
        )

        #expect(record.format == "EPUB")
        #expect(record.normalized.format == "epub")
        #expect(record.deviceMatchKeys.contains("missing on disk"))
        #expect(!record.deviceMatchKeys.contains("physical:\(id.uuidString.lowercased())"))
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

    @Test func newerGenerationWinsWhenOlderSynchronizationCompletesLast() async {
        let gate = ReadModelSynchronizationGate(blockedGeneration: 1)
        let model = LibraryReadModel(synchronizationHook: { generation in
            await gate.pauseIfNeeded(generation: generation)
        })
        let olderBooks = makeBooks(8)
        let newerBooks = makeBooks(3)
        let olderDelta = fullDelta(to: 1)
        let newerDelta = fullDelta(to: 2)

        let olderSynchronization = Task { @MainActor in
            await model.synchronize(
                books: olderBooks,
                collections: [],
                delta: olderDelta,
                deviceFileNames: [],
                deviceIsConnected: false
            )
        }
        await gate.waitUntilEntered()

        await model.synchronize(
            books: newerBooks,
            collections: [],
            delta: newerDelta,
            deviceFileNames: [],
            deviceIsConnected: false
        )
        await gate.release()
        await olderSynchronization.value
        let recordIDs: [UUID] = model.recordSnapshot().map(\.id)
        let newerBookIDs: [UUID] = newerBooks.map(\.uuid)
        let queryGeneration = await model.query(allBooksQuery).generation

        #expect(model.generation == 2)
        #expect(model.bookCount == newerBooks.count)
        #expect(recordIDs == newerBookIDs)
        #expect(queryGeneration == 2)
    }

    @Test func recentClassificationUsesInjectedClockAtExactCutoff() async {
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let cutoff = fixedNow.addingTimeInterval(-14 * 24 * 3600)
        let recent = Book(
            fileName: "recent.epub",
            originalFileName: "Recent.epub",
            dateAdded: cutoff.addingTimeInterval(1)
        )
        let atCutoff = Book(
            fileName: "cutoff.epub",
            originalFileName: "Cutoff.epub",
            dateAdded: cutoff
        )
        let old = Book(
            fileName: "old.epub",
            originalFileName: "Old.epub",
            dateAdded: cutoff.addingTimeInterval(-1)
        )
        let books = [recent, atCutoff, old]
        let recentQuery = query(filter: .recentlyAdded)
        let model = LibraryReadModel(now: { fixedNow })

        await model.synchronize(
            books: books,
            collections: [],
            delta: fullDelta(to: 0),
            deviceFileNames: [],
            deviceIsConnected: false
        )

        #expect(model.facets.recent == 1)
        #expect(await model.displayIDs(query: recentQuery) == [recent.uuid])
        #expect(
            LibraryQuery.displayIDs(
                for: model.recordSnapshot(),
                query: recentQuery,
                now: fixedNow
            ) == [recent.uuid]
        )
        #expect(
            LibraryQuery.apply(
                to: books,
                filter: .recentlyAdded,
                searchText: "",
                sort: .sourceOrder,
                now: fixedNow
            ).map(\.uuid) == [recent.uuid]
        )
    }

    @Test func statusFilterRemovesOnlyTheChangedBook() async throws {
        let books = makeBooks(100)
        let changed = books[42]
        let model = LibraryReadModel()
        await bootstrap(model, books: books)
        let query = LibraryQuerySpec(
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

    @Test func pluginPagesComeFromTheSharedImmutableSnapshot() async throws {
        let books = makeBooks(250)
        let model = LibraryReadModel()
        await bootstrap(model, books: books)

        let first = try #require(await model.pluginBooks(
            matching: "",
            offset: 0,
            limit: 17,
            scanLimit: 17,
            maximumOffset: 100_000
        ))
        #expect(first.items.count == 17)
        #expect(first.nextOffset == 17)

        let changed = books[137]
        changed.title = "AAAA Incremental"
        await model.synchronize(
            books: books,
            collections: [],
            delta: LibraryCatalogDelta(
                fromRevision: 0,
                toRevision: 1,
                affectedBookIDs: [changed.uuid],
                affectedCollectionIDs: [],
                fields: [.identity, .displayMetadata],
                requiresFullRebuild: false,
                changesBookMembership: false
            ),
            deviceFileNames: [],
            deviceIsConnected: false
        )

        let updated = try #require(await model.pluginBooks(
            matching: "incremental",
            offset: 0,
            limit: 10,
            scanLimit: 250,
            maximumOffset: 100_000
        ))
        #expect(updated.items.map(\.uuid) == [changed.uuid.uuidString])
        #expect(model.diagnostics.lastCapturedRecordCount == 1)
    }

    @Test func coverChangeAdvancesGenerationAndRefreshesKindleProjection() async throws {
        let books = makeBooks(500)
        let model = LibraryReadModel()
        await bootstrap(model, books: books)
        let generation = model.generation

        books[42].coverVersion += 1
        await model.synchronize(
            books: books,
            collections: [],
            delta: LibraryCatalogDelta(
                fromRevision: 0,
                toRevision: 1,
                affectedBookIDs: [books[42].uuid],
                affectedCollectionIDs: [],
                fields: [.cover],
                requiresFullRebuild: false,
                changesBookMembership: false
            ),
            deviceFileNames: [],
            deviceIsConnected: false
        )

        #expect(model.generation == generation + 1)
        #expect(model.diagnostics.fullRebuildCount == 1)
        #expect(model.diagnostics.lastCapturedRecordCount == 1)
        let candidates = try #require(await model.kindleCandidates())
        #expect(candidates.first(where: { $0.id == books[42].uuid })?.coverVersion == 1)
    }

    @Test func smartShelfDependencyMaskSkipsUnrelatedCoverChanges() async {
        let book = makeBooks(1)[0]
        let statusShelf = BookCollection(name: "Reading")
        statusShelf.smartShelfDefinition = SmartShelfDefinition(rules: [
            SmartShelfRule(
                field: .readingStatus,
                value: ReadingStatus.reading.rawValue
            ),
        ])
        let titleShelf = BookCollection(name: "Named")
        titleShelf.smartShelfDefinition = SmartShelfDefinition(rules: [
            SmartShelfRule(
                field: .title,
                comparison: .contains,
                value: "Book"
            ),
        ])
        let collections = [statusShelf, titleShelf]
        let model = LibraryReadModel()
        await model.synchronize(
            books: [book],
            collections: collections,
            delta: fullDelta(to: 0),
            deviceFileNames: [],
            deviceIsConnected: false
        )

        book.coverVersion += 1
        await model.synchronize(
            books: [book],
            collections: collections,
            delta: LibraryCatalogDelta(
                fromRevision: 0,
                toRevision: 1,
                affectedBookIDs: [book.uuid],
                affectedCollectionIDs: [],
                fields: [.cover],
                requiresFullRebuild: false,
                changesBookMembership: false
            ),
            deviceFileNames: [],
            deviceIsConnected: false
        )
        #expect(model.diagnostics.lastSmartShelfEvaluationCount == 0)

        book.readingStatus = .reading
        await model.synchronize(
            books: [book],
            collections: collections,
            delta: LibraryCatalogDelta(
                fromRevision: 1,
                toRevision: 2,
                affectedBookIDs: [book.uuid],
                affectedCollectionIDs: [],
                fields: [.readingState],
                requiresFullRebuild: false,
                changesBookMembership: false
            ),
            deviceFileNames: [],
            deviceIsConnected: false
        )
        #expect(model.diagnostics.lastSmartShelfEvaluationCount == 2)
        #expect(model.facets.smartCounts[statusShelf.id] == 1)
    }

    @Test func deviceInventoryDeltaUpdatesOnlyMatchingSmartShelfRecords() async {
        let books = makeBooks(1_000)
        let changed = books[537]
        let shelf = BookCollection(name: "On Kindle")
        shelf.smartShelfDefinition = SmartShelfDefinition(rules: [
            SmartShelfRule(field: .onDevice, comparison: .isTrue),
        ])
        let model = LibraryReadModel()
        await model.synchronize(
            books: books,
            collections: [shelf],
            delta: fullDelta(to: 0),
            deviceFileNames: [],
            deviceIsConnected: true,
            deviceInventoryDelta: .empty
        )
        let deviceBook = DeviceBook(
            path: "documents/\(changed.originalFileName)",
            fileName: changed.originalFileName,
            sizeBytes: 10
        )
        let deviceDelta = DeviceInventoryDelta(
            fromGeneration: 0,
            toGeneration: 1,
            inserted: [deviceBook],
            updated: [],
            removed: []
        )

        await model.synchronize(
            books: books,
            collections: [shelf],
            delta: LibraryCatalogDelta(
                fromRevision: 0,
                toRevision: 0,
                affectedBookIDs: [],
                affectedCollectionIDs: [],
                fields: [],
                requiresFullRebuild: false,
                changesBookMembership: false
            ),
            deviceFileNames: [deviceBook.matchKey],
            deviceIsConnected: true,
            deviceInventoryDelta: deviceDelta
        )

        #expect(model.diagnostics.fullRebuildCount == 1)
        #expect(model.diagnostics.lastCapturedRecordCount == 1)
        #expect(model.diagnostics.lastSmartShelfEvaluationCount == 2)
        #expect(model.facets.smartCounts[shelf.id] == 1)
    }

    @Test func observationInvalidatesGenerationButNotUnchangedFacets() async {
        let books = makeBooks(20)
        let model = LibraryReadModel()
        await bootstrap(model, books: books)
        let generationInvalidated = InvalidationFlag()
        let facetsInvalidated = InvalidationFlag()

        withObservationTracking {
            _ = model.generation
        } onChange: {
            generationInvalidated.mark()
        }
        withObservationTracking {
            _ = model.facets
        } onChange: {
            facetsInvalidated.mark()
        }

        books[0].coverVersion += 1
        await model.synchronize(
            books: books,
            collections: [],
            delta: LibraryCatalogDelta(
                fromRevision: 0,
                toRevision: 1,
                affectedBookIDs: [books[0].uuid],
                affectedCollectionIDs: [],
                fields: [.cover],
                requiresFullRebuild: false,
                changesBookMembership: false
            ),
            deviceFileNames: [],
            deviceIsConnected: false
        )

        #expect(generationInvalidated.value)
        #expect(!facetsInvalidated.value)
    }

    @Test func appliesCatalogMutationChangeSetDirectly() async {
        let books = makeBooks(10)
        let changed = books[4]
        let model = LibraryReadModel()
        await bootstrap(model, books: books)
        changed.readingStatus = .finished

        await model.apply(
            CatalogChangeSet(
                command: .setReadingStatus(
                    bookIDs: [changed.uuid],
                    status: .finished
                ),
                affectedBookIDs: [changed.uuid],
                affectedWorkIDs: [],
                affectedCollectionIDs: []
            ),
            catalogGeneration: 1,
            books: books,
            collections: [],
            deviceFileNames: [],
            deviceIsConnected: false
        )

        #expect(model.generation == 1)
        #expect(model.facets.statusCounts[.finished] == 1)
        let finishedIDs = await model.displayIDs(
            query: query(filter: .status(.finished))
        )
        #expect(finishedIDs == [changed.uuid])
    }

    @Test func membershipChangesUpdateRecordsAndIndexesWithoutFullRebuild() async {
        var books = makeBooks(100)
        let removed = books.remove(at: 37)
        let model = LibraryReadModel()
        await bootstrap(model, books: [removed] + books)

        let added = Book(
            fileName: "incremental.epub",
            originalFileName: "Incremental.epub",
            dateAdded: .now
        )
        added.title = "Incremental Addition"
        added.author = "New Indexed Author"
        added.series = "New Indexed Series"
        added.tags = ["new-indexed-tag"]
        added.readingStatus = .reading
        books.insert(added, at: 0)

        await model.synchronize(
            books: books,
            collections: [],
            delta: LibraryCatalogDelta(
                fromRevision: 0,
                toRevision: 1,
                affectedBookIDs: [removed.uuid, added.uuid],
                affectedCollectionIDs: [],
                fields: .all,
                requiresFullRebuild: false,
                changesBookMembership: true
            ),
            deviceFileNames: [],
            deviceIsConnected: false
        )

        #expect(model.generation == 1)
        #expect(model.bookCount == books.count)
        #expect(model.diagnostics.fullRebuildCount == 1)
        #expect(model.diagnostics.lastCapturedRecordCount == 2)
        #expect(model.record(for: removed.uuid) == nil)
        #expect(model.record(for: added.uuid)?.normalized.author == "new indexed author")
        #expect(model.facets.authors["New Indexed Author"] == 1)
        #expect(model.facets.series["New Indexed Series"] == 1)
        #expect(model.facets.tags["new-indexed-tag"] == 1)

        let authorIDs = await model.displayIDs(query: query(
            filter: .author("New Indexed Author")
        ))
        #expect(authorIDs == [added.uuid])
        let authorRecords = await model.records(
            matching: query(filter: .author("New Indexed Author"))
        )
        #expect(authorRecords.generation == model.generation)
        #expect(authorRecords.records.map(\.id) == [added.uuid])
        let smartShelfIDs = await model.displayIDs(query: query(
            filter: .collection(UUID()),
            smartShelf: SmartShelfDefinition(rules: [
                SmartShelfRule(
                    field: .author,
                    comparison: .contains,
                    value: "New Indexed Author"
                ),
            ])
        ))
        #expect(smartShelfIDs == [added.uuid])
        let sourceIDs = await model.displayIDs(query: allBooksQuery)
        #expect(sourceIDs == books.map(\.uuid))
    }

    @Test func incrementalStateMatchesReferenceFullRebuild() async {
        var books = makeBooks(300)
        for index in books.indices {
            books[index].series = index.isMultiple(of: 3) ? "Indexed Series" : nil
            books[index].rating = index.isMultiple(of: 5) ? 4 : nil
        }
        let collection = BookCollection(name: "Indexed Collection")
        books[12].collections = [collection]
        collection.books = [books[12]]

        let incremental = LibraryReadModel()
        await incremental.synchronize(
            books: books,
            collections: [collection],
            delta: fullDelta(to: 0),
            deviceFileNames: [],
            deviceIsConnected: false
        )

        let changed = books[12]
        changed.title = "Žlutý Incremental"
        changed.author = "Reference Author"
        changed.tags = ["reference-tag"]
        changed.series = "Reference Series"
        changed.readingStatus = .reading
        changed.rating = 5
        await incremental.synchronize(
            books: books,
            collections: [collection],
            delta: LibraryCatalogDelta(
                fromRevision: 0,
                toRevision: 1,
                affectedBookIDs: [changed.uuid],
                affectedCollectionIDs: [collection.id],
                fields: [.identity, .displayMetadata, .collectionMembership, .readingState],
                requiresFullRebuild: false,
                changesBookMembership: false
            ),
            deviceFileNames: [],
            deviceIsConnected: false
        )
        await expectMatchesFullRebuild(
            incremental,
            books: books,
            collections: [collection],
            generation: 1,
            highlightedBookID: changed.uuid
        )

        let removed = books.remove(at: 101)
        let added = Book(
            fileName: "replacement.epub",
            originalFileName: "Replacement.epub",
            dateAdded: .now
        )
        added.title = "Replacement"
        added.author = "Membership Author"
        added.tags = ["membership"]
        books.insert(added, at: 0)
        await incremental.synchronize(
            books: books,
            collections: [collection],
            delta: LibraryCatalogDelta(
                fromRevision: 1,
                toRevision: 2,
                affectedBookIDs: [removed.uuid, added.uuid],
                affectedCollectionIDs: [],
                fields: .all,
                requiresFullRebuild: false,
                changesBookMembership: true
            ),
            deviceFileNames: [],
            deviceIsConnected: false
        )
        await expectMatchesFullRebuild(
            incremental,
            books: books,
            collections: [collection],
            generation: 2,
            highlightedBookID: changed.uuid
        )
        #expect(incremental.diagnostics.fullRebuildCount == 1)
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

    @Test(arguments: [1_000, 10_000])
    func indexedReadModelQueryBenchmark(_ count: Int) async {
        let books = makeBooks(count)
        for index in books.indices where index.isMultiple(of: 100) {
            books[index].readingStatus = .reading
        }
        let model = LibraryReadModel()
        await bootstrap(model, books: books)

        let clock = ContinuousClock()
        let startedAt = clock.now
        let ids = await model.displayIDs(query: query(filter: .status(.reading)))
        let elapsed = startedAt.duration(to: clock.now)

        print("Library indexed query benchmark (\(count) records): \(elapsed)")
        #expect(ids.count == count / 100)
        #expect(elapsed < .seconds(1))
    }

    @Test func normalizedFacetIndexesGroupTagCaseAndAliasHTMLFormats() async {
        let first = Book(
            fileName: "first.htm",
            originalFileName: "First.htm"
        )
        first.title = "First"
        first.tags = ["Sci-Fi"]
        let second = Book(
            fileName: "second.html",
            originalFileName: "Second.html"
        )
        second.title = "Second"
        second.tags = ["Sci-Fi"]
        let third = Book(
            fileName: "third.epub",
            originalFileName: "Third.epub"
        )
        third.title = "Third"
        third.tags = ["sci-fi"]
        let model = LibraryReadModel()
        await bootstrap(model, books: [first, second, third])

        let tagIDs = await model.displayIDs(query: query(filter: .tag("SCI-FI")))
        let htmlIDs = await model.displayIDs(query: query(filter: .format("HTML")))

        #expect(tagIDs.count == 3)
        #expect(model.facets.tagKeys == ["Sci-Fi"])
        #expect(model.facets.tags["Sci-Fi"] == 3)
        #expect(htmlIDs == [first.uuid, second.uuid])
    }

    private var allBooksQuery: LibraryQuerySpec {
        query(filter: .all)
    }

    private func query(
        filter: LibraryFilter,
        searchText: String = "",
        sort: LibraryDisplaySort = .sourceOrder,
        savedSearch: String? = nil,
        smartShelf: SmartShelfDefinition? = nil,
        deviceFileNames: Set<String> = [],
        deviceIsConnected: Bool = false,
        kindlePresenceFilter: KindlePresenceFilter = .all
    ) -> LibraryQuerySpec {
        LibraryQuerySpec(
            filter: filter,
            searchText: searchText,
            sort: sort,
            savedSearch: savedSearch,
            smartShelf: smartShelf,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected,
            kindlePresenceFilter: kindlePresenceFilter
        )
    }

    private func expectMatchesFullRebuild(
        _ incremental: LibraryReadModel,
        books: [Book],
        collections: [BookCollection],
        generation: Int,
        highlightedBookID: UUID
    ) async {
        let reference = LibraryReadModel()
        await reference.synchronize(
            books: books,
            collections: collections,
            delta: fullDelta(to: generation),
            deviceFileNames: [],
            deviceIsConnected: false
        )

        let deviceKeys = incremental.record(for: highlightedBookID)?.deviceMatchKeys ?? []
        let specifications: [LibraryQuerySpec] = [
            query(filter: .all),
            query(filter: .status(.reading)),
            query(filter: .author("Reference Author")),
            query(filter: .series("Reference Series")),
            query(filter: .tag("reference-tag")),
            query(filter: .collection(collections[0].id)),
            query(filter: .all, searchText: "incremental"),
            query(
                filter: .all,
                sort: LibraryDisplaySort(field: .title, ascending: true)
            ),
            query(
                filter: .all,
                deviceFileNames: deviceKeys,
                deviceIsConnected: true,
                kindlePresenceFilter: .onKindle
            ),
        ]

        #expect(incremental.generation == generation)
        #expect(incremental.facets == reference.facets)
        #expect(incremental.recordSnapshot() == reference.recordSnapshot())
        for specification in specifications {
            let incrementalIDs = await incremental.displayIDs(query: specification)
            let referenceIDs = await reference.displayIDs(query: specification)
            #expect(incrementalIDs == referenceIDs)
        }
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

    private func makeRecords(_ count: Int) -> [LibraryBookRecord] {
        return (0..<count).map { index in
            let id = UUID()
            return LibraryBookRecord(
                id: id,
                sourceOrdinal: index,
                displayTitle: "Book",
                displayAuthor: "Author",
                title: "Book",
                author: "Author",
                dateAdded: Date(timeIntervalSince1970: TimeInterval(index)),
                rating: 0,
                readingStatus: .unread,
                format: "EPUB",
                tags: ["tag"],
                series: nil,
                seriesIndex: .greatestFiniteMagnitude,
                collectionIDs: [],
                normalized: LibraryNormalizedStrings(
                    title: "Book",
                    author: "Author",
                    tags: ["tag"],
                    format: "EPUB"
                )
            )
        }
    }
}

private final class InvalidationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func mark() {
        lock.withLock { storage = true }
    }
}
