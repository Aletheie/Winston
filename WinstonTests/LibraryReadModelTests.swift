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

private final class LockedReadModelClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }

    func readAndAdvance(by interval: TimeInterval) -> Date {
        lock.withLock {
            let current = value
            value = value.addingTimeInterval(interval)
            return current
        }
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

    @Test func relativeFacetsRefreshWhenTimeCrossesTheRecentCutoff() async {
        let initialNow = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LockedReadModelClock(initialNow)
        let book = Book(
            fileName: "aging.epub",
            originalFileName: "Aging.epub",
            dateAdded: initialNow.addingTimeInterval(-13 * 24 * 3600)
        )
        let model = LibraryReadModel(now: { clock.now })
        await bootstrap(model, books: [book])
        #expect(model.facets.recent == 1)

        clock.advance(by: 2 * 24 * 3600)
        model.refreshRelativeFacets()

        #expect(model.facets.recent == 0)
        #expect(model.relativeFilterRevision == 1)
        let recentIDs = await model.displayIDs(
            query: query(filter: .recentlyAdded)
        )
        #expect(recentIDs.isEmpty)
    }

    @Test func bulkSortChangesRemoveEveryOldPositionBeforeInsertion() async throws {
        let alpha = Book(fileName: "alpha.epub", originalFileName: "Alpha.epub")
        alpha.title = "Alpha"
        let bravo = Book(fileName: "bravo.epub", originalFileName: "Bravo.epub")
        bravo.title = "Bravo"
        let charlie = Book(
            fileName: "charlie.epub",
            originalFileName: "Charlie.epub"
        )
        charlie.title = "Charlie"
        let delta = Book(fileName: "delta.epub", originalFileName: "Delta.epub")
        delta.title = "Delta"
        let books = [alpha, bravo, charlie, delta]
        let model = LibraryReadModel()
        await bootstrap(model, books: books)
        let titleQuery = query(
            filter: .all,
            sort: LibraryDisplaySort(field: .title, ascending: true)
        )
        let originalIDs = await model.displayIDs(query: titleQuery)
        let oldAlpha = try #require(model.record(for: alpha.uuid))
        let oldCharlie = try #require(model.record(for: charlie.uuid))

        alpha.title = "Able"
        charlie.title = "Aaa"
        await model.synchronize(
            books: books,
            collections: [],
            delta: LibraryCatalogDelta(
                fromRevision: 0,
                toRevision: 1,
                affectedBookIDs: [alpha.uuid, charlie.uuid],
                affectedCollectionIDs: [],
                fields: [.displayMetadata],
                requiresFullRebuild: false,
                changesBookMembership: false
            ),
            deviceFileNames: [],
            deviceIsConnected: false
        )
        let newAlpha = try #require(model.record(for: alpha.uuid))
        let newCharlie = try #require(model.record(for: charlie.uuid))
        let orderedChanges = LibraryReadModelDisplayDelta(
            fromGeneration: 0,
            toGeneration: 1,
            changes: [
                LibraryReadModelRecordChange(
                    id: alpha.uuid,
                    old: oldAlpha,
                    new: newAlpha
                ),
                LibraryReadModelRecordChange(
                    id: charlie.uuid,
                    old: oldCharlie,
                    new: newCharlie
                ),
            ],
            requiresFullRebuild: false
        )

        let incremental = try #require(
            model.incrementallyUpdatingDisplayIDs(
                originalIDs,
                with: orderedChanges,
                query: titleQuery
            )
        )

        #expect(incremental.ids == [
            charlie.uuid,
            alpha.uuid,
            bravo.uuid,
            delta.uuid,
        ])
        let rebuiltIDs = await model.displayIDs(query: titleQuery)
        #expect(incremental.ids == rebuiltIDs)
    }

    @Test func thousandRecordBatchPreservesDisplayPluginOrderAndFacetIndexes() async throws {
        let books = makeBooks(1_000)
        let model = LibraryReadModel()
        await bootstrap(model, books: books)
        let titleQuery = query(filter: .all, sort: LibraryDisplaySort(field: .title, ascending: true))
        let previousIDs = await model.displayIDs(query: titleQuery)
        for (index, book) in books.enumerated() {
            book.title = "Changed \(books.count - index)"
            book.readingStatus = .reading
        }
        await model.synchronize(
            books: books,
            collections: [],
            delta: LibraryCatalogDelta(
                fromRevision: 0,
                toRevision: 1,
                affectedBookIDs: Set(books.map(\.uuid)),
                affectedCollectionIDs: [],
                fields: [.displayMetadata, .readingState],
                requiresFullRebuild: false,
                changesBookMembership: false
            ),
            deviceFileNames: [],
            deviceIsConnected: false
        )
        let referenceIDs = LibraryQuery.displayIDs(for: model.recordSnapshot(), query: titleQuery)
        let incremental = try #require(model.incrementallyUpdatingDisplayIDs(
            previousIDs,
            with: model.displayDelta(since: 0),
            query: titleQuery
        ))
        #expect(incremental.ids == referenceIDs)
        #expect(await model.displayIDs(query: titleQuery) == referenceIDs)
        #expect(await model.displayIDs(query: query(filter: .status(.unread))).isEmpty)
        #expect(await model.displayIDs(query: query(filter: .status(.reading))) == books.map(\.uuid))
        #expect(model.facets.statusCounts[.reading] == books.count)
        #expect(model.facets.authors["Author 0"] == 4)
        #expect(model.facets.tags["tag-0"] == 20)
        let page = try #require(await model.pluginBooks(
            matching: "", offset: 0, limit: books.count,
            scanLimit: books.count, maximumOffset: books.count
        ))
        #expect(page.items == books.map(PluginBookDTO.init).sorted(by: PluginBookDTO.precedes))
        #expect(model.diagnostics.fullRebuildCount == 1)
    }

    @Test func incrementalSourceOrderUsesLiveRanksAfterMultipleInsertions() async throws {
        let original = makeBooks(3)
        original[1].readingStatus = .reading
        original[2].readingStatus = .reading
        let model = LibraryReadModel()
        await bootstrap(model, books: original)
        let additions = makeBooks(3)
        let books = additions + original
        await model.synchronize(
            books: books, collections: [],
            delta: LibraryCatalogDelta(
                fromRevision: 0, toRevision: 1,
                affectedBookIDs: Set(additions.map(\.uuid)),
                affectedCollectionIDs: [], fields: .all,
                requiresFullRebuild: false, changesBookMembership: true
            ),
            deviceFileNames: [], deviceIsConnected: false
        )
        let readingQuery = query(filter: .status(.reading))
        let previousIDs = await model.displayIDs(query: readingQuery)
        original[0].readingStatus = .reading
        await model.synchronize(
            books: books, collections: [],
            delta: LibraryCatalogDelta(
                fromRevision: 1, toRevision: 2,
                affectedBookIDs: [original[0].uuid],
                affectedCollectionIDs: [], fields: [.readingState],
                requiresFullRebuild: false, changesBookMembership: false
            ),
            deviceFileNames: [], deviceIsConnected: false
        )
        let incremental = try #require(model.incrementallyUpdatingDisplayIDs(
            previousIDs, with: model.displayDelta(since: 1), query: readingQuery
        ))
        #expect(incremental.ids == original.map(\.uuid))
        #expect(incremental.ids == (await model.displayIDs(query: readingQuery)))
    }

    @Test func cancelledIndexedQueryReturnsNoPartialResults() async {
        let records = makeRecords(1_000)
        let engine = LibraryMetadataQueryEngine(now: { .now })
        await engine.rebuild(records: records, sourceOrder: records.map(\.id), generation: 1)
        let specification = query(filter: .all, sort: LibraryDisplaySort(field: .title, ascending: false))
        let cancelledQuery = Task { await engine.query(specification) }
        cancelledQuery.cancel()
        #expect(await cancelledQuery.value.ids.isEmpty)
        #expect(await engine.query(allBooksQuery).ids == records.map(\.id))
    }

    @Test func overlappingDeltasRemoveTheActuallyIndexedDeviceKeys() async {
        #expect(ManagedLeafName(rawValue: "Intermediate device name.epub") != nil)
        #expect(ManagedLeafName(rawValue: "Final device name.epub") != nil)
        let book = makeBooks(1)[0]
        func capture() -> LibraryBookRecord {
            LibraryBookRecord(book, sourceOrdinal: 0, includeCollections: true, includeHighlights: true)
        }
        let initial = capture()
        let engine = LibraryMetadataQueryEngine(now: { .now })
        await engine.rebuild(records: [initial], sourceOrder: [book.uuid], generation: 0)
        book.originalFileName = "Intermediate device name.epub"
        book.title = "Intermediate"
        let intermediate = capture()
        await engine.apply(
            changes: [LibraryReadModelRecordChange(id: book.uuid, old: initial, new: intermediate)],
            sourceOrder: nil, generation: 1
        )
        book.originalFileName = "Final device name.epub"
        book.title = "Final"
        let final = capture()
        #expect(initial.deviceMatchKeys.isDisjoint(with: intermediate.deviceMatchKeys),
                "Initial keys: \(initial.deviceMatchKeys); intermediate keys: \(intermediate.deviceMatchKeys)")
        #expect(intermediate.deviceMatchKeys.isDisjoint(with: final.deviceMatchKeys),
                "Intermediate keys: \(intermediate.deviceMatchKeys); final keys: \(final.deviceMatchKeys)")
        // The newer task captured its delta before the first task published.
        await engine.apply(
            changes: [LibraryReadModelRecordChange(id: book.uuid, old: initial, new: final)],
            sourceOrder: nil, generation: 2
        )
        let result = await engine.query(query(
            filter: .all, deviceFileNames: intermediate.deviceMatchKeys,
            deviceIsConnected: true, kindlePresenceFilter: .notOnKindle
        ))
        #expect(result.ids == [book.uuid])
        #expect(result.generation == 2)
        #expect(await engine.records(matchingDeviceKeys: intermediate.deviceMatchKeys).isEmpty)
    }

    @Test func recentExpirationTracksInsertedRecordsAndClockReversal() async {
        let initialNow = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LockedReadModelClock(initialNow)
        let model = LibraryReadModel(now: { clock.now })
        await bootstrap(model, books: [])
        let book = Book(
            fileName: "expiring.epub", originalFileName: "Expiring.epub",
            dateAdded: initialNow.addingTimeInterval(-LibraryRelativeDateFilter.recentlyAddedInterval + 1)
        )
        await model.synchronize(
            books: [book], collections: [],
            delta: LibraryCatalogDelta(
                fromRevision: 0, toRevision: 1, affectedBookIDs: [book.uuid],
                affectedCollectionIDs: [], fields: .all,
                requiresFullRebuild: false, changesBookMembership: true
            ),
            deviceFileNames: [], deviceIsConnected: false
        )
        #expect(model.facets.recent == 1)
        clock.advance(by: 1)
        model.refreshRelativeFacets()
        #expect(model.facets.recent == 0)
        clock.advance(by: -1)
        model.refreshRelativeFacets()
        #expect(model.facets.recent == 1)
        #expect(model.relativeFilterRevision == 2)
    }

    @Test func cutoffBetweenFacetCalculationAndPublicationRemainsScheduled() async {
        let initialNow = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = LockedReadModelClock(initialNow)
        let model = LibraryReadModel(now: { clock.readAndAdvance(by: 1) })
        let book = Book(
            fileName: "publication-cutoff.epub", originalFileName: "Publication cutoff.epub",
            dateAdded: initialNow.addingTimeInterval(-LibraryRelativeDateFilter.recentlyAddedInterval + 2)
        )
        await bootstrap(model, books: [book])
        #expect(model.facets.recent == 1)

        model.refreshRelativeFacets()

        #expect(model.facets.recent == 0)
        #expect(model.relativeFilterRevision == 1)
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

    @Test(arguments: ["notes", "shelf", "year"])
    func savedSearchCountsTrackSearchOnlyMetadataChanges(_ field: String) async {
        let book = makeBooks(1)[0]
        func setMatchingValue(_ matches: Bool) {
            switch field {
            case "notes": book.notes = matches ? "needle" : "changed"
            case "shelf": book.shelfLocation = matches ? "needle" : "changed"
            default: book.year = matches ? "2020" : "2021"
            }
        }
        setMatchingValue(true)
        let searchText = field == "year" ? "year:2020" : "needle"
        let saved = BookCollection(name: "Saved search", savedSearch: searchText)
        let structured = BookCollection(name: "Unread")
        structured.smartShelfDefinition = SmartShelfDefinition(rules: [
            SmartShelfRule(field: .readingStatus, value: ReadingStatus.unread.rawValue),
        ])
        let model = LibraryReadModel()
        await model.synchronize(
            books: [book], collections: [saved, structured], delta: fullDelta(to: 0),
            deviceFileNames: [], deviceIsConnected: false
        )
        #expect(model.facets.smartCounts[saved.id] == 1)

        for generation in 1 ... 2 {
            setMatchingValue(generation == 2)
            await model.synchronize(
                books: [book], collections: [saved, structured],
                delta: LibraryCatalogDelta(
                    fromRevision: generation - 1, toRevision: generation,
                    affectedBookIDs: [book.uuid], affectedCollectionIDs: [],
                    fields: [.displayMetadata], requiresFullRebuild: false,
                    changesBookMembership: false
                ),
                deviceFileNames: [], deviceIsConnected: false
            )
            let displayed = await model.displayIDs(query: query(filter: .all, savedSearch: searchText))
            #expect(model.facets.smartCounts[saved.id, default: 0] == displayed.count)
            #expect(displayed.count == generation - 1)
            #expect(model.facets.smartCounts[structured.id] == 1)
            #expect(model.diagnostics.lastSmartShelfEvaluationCount == 2)
            #expect(model.diagnostics.lastCapturedRecordCount == 1)
        }
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
        let ids = LibraryQuery.displayIDs(
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

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["WINSTON_PERFORMANCE_BENCHMARKS"] == "1"),
        arguments: [1_000, 10_000, 50_000]
    )
    func immutableIndexedQueryScalingBenchmark(_ count: Int) async {
        let records = makeRecords(count, varyMetadata: true)
        let engine = LibraryMetadataQueryEngine(now: { .now })
        let clock = ContinuousClock()
        var startedAt = clock.now
        await engine.rebuild(records: records, sourceOrder: records.map(\.id), generation: 1)
        print("PERF immutable index build [\(count)]: \(startedAt.duration(to: clock.now))")
        let specifications = [
            allBooksQuery,
            query(filter: .tag("TAG"), searchText: "author:Author format:EPUB"),
            query(filter: .all, searchText: "Book", sort: LibraryDisplaySort(field: .title, ascending: false)),
            query(filter: .status(.reading)),
        ]
        for (index, specification) in specifications.enumerated() {
            startedAt = clock.now
            let result = await engine.query(specification)
            print("PERF immutable query \(index) [\(count), \(result.ids.count) matches]: \(startedAt.duration(to: clock.now))")
            #expect(result.ids == LibraryQuery.displayIDs(for: records, query: specification))
            #expect(result.ids.count == (index == 3 ? count / 100 : count))
        }
        let removals = records.prefix(min(1_000, count)).map {
            LibraryReadModelRecordChange(id: $0.id, old: $0, new: nil)
        }
        let remaining = Array(records.dropFirst(removals.count))
        startedAt = clock.now
        await engine.apply(changes: removals, sourceOrder: remaining.map(\.id), generation: 2)
        print("PERF immutable remove batch [\(count), \(removals.count) changes]: \(startedAt.duration(to: clock.now))")
        #expect(await engine.query(allBooksQuery).ids == remaining.map(\.id))
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

    private func makeRecords(_ count: Int, varyMetadata: Bool = false) -> [LibraryBookRecord] {
        return (0..<count).map { index in
            let id = UUID()
            let title = varyMetadata ? "Book \(count - index)" : "Book"
            let author = varyMetadata ? "Author \(index % 250)" : "Author"
            return LibraryBookRecord(
                id: id,
                sourceOrdinal: index,
                displayTitle: title,
                displayAuthor: author,
                title: title,
                author: author,
                dateAdded: Date(timeIntervalSince1970: TimeInterval(index)),
                rating: 0,
                readingStatus: varyMetadata && index.isMultiple(of: 100) ? .reading : .unread,
                format: "EPUB",
                tags: ["tag"],
                series: nil,
                seriesIndex: .greatestFiniteMagnitude,
                collectionIDs: [],
                normalized: LibraryNormalizedStrings(
                    title: title,
                    author: author,
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
