import Foundation
import Observation
import OSLog
import SwiftData

nonisolated struct LibraryFacetTip: Equatable, Sendable {
    let original: String
    let suggestion: String
}

nonisolated struct LibraryFacetSnapshot: Equatable, Sendable {
    var formats: [String: Int] = [:]
    var authors: [String: Int] = [:]
    var series: [String: Int] = [:]
    var tags: [String: Int] = [:]
    var formatKeys: [String] = []
    var authorKeys: [String] = []
    var seriesKeys: [String] = []
    var tagKeys: [String] = []
    var rated = 0
    var statusCounts: [ReadingStatus: Int] = [:]
    var recent = 0
    var smartCounts: [UUID: Int] = [:]
    var authorTips: [LibraryFacetTip] = []
    var seriesTips: [LibraryFacetTip] = []

    static func build(
        records: [LibraryDisplaySnapshot],
        smartCollections: [LibrarySmartCollectionSnapshot],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool,
        now: Date = .now
    ) -> LibraryFacetSnapshot {
        var facets = LibraryFacetSnapshot()
        let recentCutoff = now.addingTimeInterval(-14 * 24 * 3600)
        for record in records {
            guard !Task.isCancelled else { return facets }
            facets.add(record, recentCutoff: recentCutoff)
        }
        facets.refreshKeysAndTips()
        facets.smartCounts = Self.makeSmartCounts(
            records: records,
            smartCollections: smartCollections,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected
        )
        return facets
    }

    mutating func apply(
        _ changes: [LibraryReadModelRecordChange],
        smartCollections: [LibrarySmartCollectionSnapshot],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool,
        now: Date = .now
    ) {
        let recentCutoff = now.addingTimeInterval(-14 * 24 * 3600)
        var refreshKeys = false
        for change in changes {
            if let old = change.old {
                remove(old, recentCutoff: recentCutoff)
            }
            if let new = change.new {
                add(new, recentCutoff: recentCutoff)
            }
            if change.old?.format != change.new?.format
                || change.old?.displayAuthor != change.new?.displayAuthor
                || change.old?.series != change.new?.series
                || change.old?.tags != change.new?.tags {
                refreshKeys = true
            }

            for collection in smartCollections {
                let oldMatches = change.old.map {
                    collection.matches(
                        $0,
                        deviceFileNames: deviceFileNames,
                        deviceIsConnected: deviceIsConnected
                    )
                } ?? false
                let newMatches = change.new.map {
                    collection.matches(
                        $0,
                        deviceFileNames: deviceFileNames,
                        deviceIsConnected: deviceIsConnected
                    )
                } ?? false
                guard oldMatches != newMatches else { continue }
                if newMatches {
                    smartCounts[collection.id, default: 0] += 1
                } else {
                    Self.decrement(&smartCounts, key: collection.id)
                }
            }
        }
        if refreshKeys { refreshKeysAndTips() }
    }

    private mutating func add(
        _ record: LibraryDisplaySnapshot,
        recentCutoff: Date
    ) {
        formats[record.format, default: 0] += 1
        if !record.displayAuthor.isEmpty {
            authors[record.displayAuthor, default: 0] += 1
        }
        if let series = record.series, !series.isEmpty {
            self.series[series, default: 0] += 1
        }
        for tag in record.tags {
            tags[tag, default: 0] += 1
        }
        if record.rating > 0 { rated += 1 }
        statusCounts[record.readingStatus, default: 0] += 1
        if record.dateAdded > recentCutoff { recent += 1 }
    }

    private mutating func remove(
        _ record: LibraryDisplaySnapshot,
        recentCutoff: Date
    ) {
        Self.decrement(&formats, key: record.format)
        if !record.displayAuthor.isEmpty {
            Self.decrement(&authors, key: record.displayAuthor)
        }
        if let series = record.series, !series.isEmpty {
            Self.decrement(&self.series, key: series)
        }
        for tag in record.tags {
            Self.decrement(&tags, key: tag)
        }
        if record.rating > 0 { rated = max(0, rated - 1) }
        Self.decrement(&statusCounts, key: record.readingStatus)
        if record.dateAdded > recentCutoff { recent = max(0, recent - 1) }
    }

    private mutating func refreshKeysAndTips() {
        formatKeys = formats.keys.sorted()
        authorKeys = authors.keys.sorted()
        seriesKeys = series.compactMap { name, count in
            count > 1 ? name : nil
        }.sorted()
        tagKeys = tags.keys.sorted()
        authorTips = authorKeys.compactMap { author in
            MetadataFixFinder.reversedAuthorSuggestion(author).map {
                LibraryFacetTip(original: author, suggestion: $0)
            }
        }
        seriesTips = SeriesSuggestions.unificationTips(counts: series).map {
            LibraryFacetTip(original: $0.original, suggestion: $0.suggestion)
        }
    }

    private static func makeSmartCounts(
        records: [LibraryDisplaySnapshot],
        smartCollections: [LibrarySmartCollectionSnapshot],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) -> [UUID: Int] {
        guard !smartCollections.isEmpty else { return [:] }
        var counts: [UUID: Int] = [:]
        for record in records {
            guard !Task.isCancelled else { return counts }
            for collection in smartCollections
            where collection.matches(
                record,
                deviceFileNames: deviceFileNames,
                deviceIsConnected: deviceIsConnected
            ) {
                counts[collection.id, default: 0] += 1
            }
        }
        return counts
    }

    private static func decrement<Key: Hashable>(
        _ counts: inout [Key: Int],
        key: Key
    ) {
        guard let count = counts[key] else { return }
        if count <= 1 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = count - 1
        }
    }
}

nonisolated struct LibrarySmartCollectionSnapshot: Equatable, Sendable {
    let id: UUID
    let savedSearch: LibraryQuery.NormalizedQuery?
    let definition: SmartShelfDefinition?

    func matches(
        _ record: LibraryDisplaySnapshot,
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) -> Bool {
        if let definition {
            return definition.matches(
                record.smartShelf,
                deviceFileNames: deviceFileNames,
                deviceIsConnected: deviceIsConnected
            )
        }
        if let savedSearch {
            return record.search.matches(savedSearch)
        }
        return false
    }
}

nonisolated struct LibraryReadModelRecordChange: Equatable, Sendable {
    let id: UUID
    let old: LibraryDisplaySnapshot?
    let new: LibraryDisplaySnapshot?
}

nonisolated struct LibraryReadModelDisplayDelta: Equatable, Sendable {
    let fromGeneration: Int
    let toGeneration: Int
    let changes: [LibraryReadModelRecordChange]
    let requiresFullRebuild: Bool

    var isEmpty: Bool {
        fromGeneration == toGeneration && changes.isEmpty && !requiresFullRebuild
    }
}

nonisolated struct LibraryIncrementalDisplayUpdate: Equatable, Sendable {
    let ids: [UUID]
    let changed: Bool
}

nonisolated struct LibraryReadModelDiagnostics: Equatable, Sendable {
    var fullRebuildCount = 0
    var incrementallyCapturedRecordCount = 0
    var lastCapturedRecordCount = 0
}

private nonisolated struct LibraryReadModelUpdate: Sendable {
    let generation: Int
    let changes: [LibraryReadModelRecordChange]
    let requiresFullDisplayRebuild: Bool
}

private actor LibraryReadModelWorker {
    func makeFacets(
        records: [LibraryDisplaySnapshot],
        smartCollections: [LibrarySmartCollectionSnapshot],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) -> LibraryFacetSnapshot {
        LibraryFacetSnapshot.build(
            records: records,
            smartCollections: smartCollections,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected
        )
    }

    func displayIDs(
        records: [LibraryDisplaySnapshot],
        query: LibraryDisplayQuery
    ) -> [UUID] {
        LibraryQuery.displayIDs(for: records, query: query)
    }
}

@MainActor
@Observable
final class LibraryReadModel {
    private(set) var generation = 0
    private(set) var catalogRevision = 0
    private(set) var bookCount = 0
    private(set) var facets = LibraryFacetSnapshot()

    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var orderedRecords: [LibraryDisplaySnapshot] = []
    @ObservationIgnored private var recordsByID: [UUID: LibraryDisplaySnapshot] = [:]
    @ObservationIgnored private var booksByID: [UUID: Book] = [:]
    @ObservationIgnored private var booksByPersistentID: [Book.ID: Book] = [:]
    @ObservationIgnored private var sourceIndexByID: [UUID: Int] = [:]
    @ObservationIgnored private var sourceIndexByPersistentID: [Book.ID: Int] = [:]
    @ObservationIgnored private var smartCollections: [LibrarySmartCollectionSnapshot] = []
    @ObservationIgnored private var deviceFileNames: Set<String> = []
    @ObservationIgnored private var deviceIsConnected = false
    @ObservationIgnored private var updates: [LibraryReadModelUpdate] = []
    @ObservationIgnored private let worker = LibraryReadModelWorker()
    @ObservationIgnored private(set) var diagnostics = LibraryReadModelDiagnostics()

    func synchronize(
        books: [Book],
        collections: [BookCollection],
        delta: LibraryCatalogDelta,
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) async {
        let nextSmartCollections = Self.smartCollectionSnapshots(collections)
        let configurationChanged = nextSmartCollections != smartCollections
            || deviceFileNames != self.deviceFileNames
            || deviceIsConnected != self.deviceIsConnected

        if !didBootstrap || delta.requiresFullRebuild {
            await rebuild(
                books: books,
                smartCollections: nextSmartCollections,
                catalogRevision: delta.toRevision,
                deviceFileNames: deviceFileNames,
                deviceIsConnected: deviceIsConnected
            )
            return
        }

        if delta.changesBookMembership || books.count != bookCount {
            await rebuild(
                books: books,
                smartCollections: nextSmartCollections,
                catalogRevision: delta.toRevision,
                deviceFileNames: deviceFileNames,
                deviceIsConnected: deviceIsConnected
            )
            return
        }

        var recordChanges: [LibraryReadModelRecordChange] = []
        recordChanges.reserveCapacity(delta.affectedBookIDs.count)
        for id in delta.affectedBookIDs {
            guard let book = booksByID[id],
                  let old = recordsByID[id],
                  let index = sourceIndexByID[id] else {
                await rebuild(
                    books: books,
                    smartCollections: nextSmartCollections,
                    catalogRevision: delta.toRevision,
                    deviceFileNames: deviceFileNames,
                    deviceIsConnected: deviceIsConnected
                )
                return
            }
            let updated = LibraryDisplaySnapshot(
                book,
                sourceOrdinal: index,
                includeCollections: true,
                includeHighlights: true
            )
            guard old != updated else { continue }
            orderedRecords[index] = updated
            recordsByID[id] = updated
            recordChanges.append(
                LibraryReadModelRecordChange(id: id, old: old, new: updated)
            )
        }

        diagnostics.lastCapturedRecordCount = delta.affectedBookIDs.count
        diagnostics.incrementallyCapturedRecordCount += delta.affectedBookIDs.count
        catalogRevision = delta.toRevision

        if configurationChanged {
            let interval = Log.librarySignposter.beginInterval("SidebarFacets")
            let rebuiltFacets = await worker.makeFacets(
                records: orderedRecords,
                smartCollections: nextSmartCollections,
                deviceFileNames: deviceFileNames,
                deviceIsConnected: deviceIsConnected
            )
            Log.librarySignposter.endInterval("SidebarFacets", interval)
            guard !Task.isCancelled else { return }
            facets = rebuiltFacets
        } else if !recordChanges.isEmpty {
            var updatedFacets = facets
            updatedFacets.apply(
                recordChanges,
                smartCollections: smartCollections,
                deviceFileNames: self.deviceFileNames,
                deviceIsConnected: self.deviceIsConnected
            )
            facets = updatedFacets
        }

        smartCollections = nextSmartCollections
        self.deviceFileNames = deviceFileNames
        self.deviceIsConnected = deviceIsConnected
        guard !recordChanges.isEmpty || configurationChanged else { return }
        publish(
            changes: recordChanges,
            requiresFullDisplayRebuild: configurationChanged
        )
    }

    func recordSnapshot() -> [LibraryDisplaySnapshot] {
        orderedRecords
    }

    func displayIDs(query: LibraryDisplayQuery) async -> [UUID] {
        await worker.displayIDs(records: orderedRecords, query: query)
    }

    func record(for id: UUID) -> LibraryDisplaySnapshot? {
        recordsByID[id]
    }

    func book(id: Book.ID?) -> Book? {
        id.flatMap { booksByPersistentID[$0] }
    }

    func book(uuid: UUID) -> Book? {
        booksByID[uuid]
    }

    func books(for ids: [UUID]) -> [Book] {
        ids.compactMap { booksByID[$0] }
    }

    func selectedBooks(for ids: Set<Book.ID>) -> [Book] {
        ids.compactMap { id -> (Int, Book)? in
            guard let index = sourceIndexByPersistentID[id],
                  let book = booksByPersistentID[id] else {
                return nil
            }
            return (index, book)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    func displayDelta(since generation: Int) -> LibraryReadModelDisplayDelta {
        guard generation >= 0, generation <= self.generation else {
            return fullDisplayDelta(since: generation)
        }
        guard generation != self.generation else {
            return LibraryReadModelDisplayDelta(
                fromGeneration: generation,
                toGeneration: self.generation,
                changes: [],
                requiresFullRebuild: false
            )
        }

        let pending = updates.filter { $0.generation > generation }
        guard pending.first?.generation == generation + 1,
              pending.last?.generation == self.generation else {
            return fullDisplayDelta(since: generation)
        }
        if pending.contains(where: \.requiresFullDisplayRebuild) {
            return fullDisplayDelta(since: generation)
        }

        var order: [UUID] = []
        var merged: [UUID: LibraryReadModelRecordChange] = [:]
        for update in pending {
            for change in update.changes {
                if let previous = merged[change.id] {
                    merged[change.id] = LibraryReadModelRecordChange(
                        id: change.id,
                        old: previous.old,
                        new: change.new
                    )
                } else {
                    order.append(change.id)
                    merged[change.id] = change
                }
            }
        }
        return LibraryReadModelDisplayDelta(
            fromGeneration: generation,
            toGeneration: self.generation,
            changes: order.compactMap { merged[$0] },
            requiresFullRebuild: false
        )
    }

    func incrementallyUpdatingDisplayIDs(
        _ currentIDs: [UUID],
        with delta: LibraryReadModelDisplayDelta,
        query: LibraryDisplayQuery
    ) -> LibraryIncrementalDisplayUpdate? {
        guard !delta.requiresFullRebuild else { return nil }
        var updated = currentIDs
        var changed = false

        for change in delta.changes {
            let oldMatches = change.old.map {
                LibraryQuery.displayMatches($0, query: query)
            } ?? false
            let newMatches = change.new.map {
                LibraryQuery.displayMatches($0, query: query)
            } ?? false

            if oldMatches, newMatches,
               let old = change.old,
               let new = change.new,
               !LibraryQuery.displayOrderingChanged(from: old, to: new, query: query) {
                continue
            }
            if !oldMatches, !newMatches { continue }

            if oldMatches {
                guard let existingIndex = updated.firstIndex(of: change.id) else {
                    return nil
                }
                updated.remove(at: existingIndex)
                changed = true
            } else if updated.contains(change.id) {
                return nil
            }

            if newMatches {
                guard let new = change.new else { return nil }
                var lowerBound = 0
                var upperBound = updated.count
                while lowerBound < upperBound {
                    let middle = lowerBound + (upperBound - lowerBound) / 2
                    guard let existing = recordsByID[updated[middle]] else {
                        return nil
                    }
                    if LibraryQuery.displayOrdered(existing, before: new, query: query) {
                        lowerBound = middle + 1
                    } else {
                        upperBound = middle
                    }
                }
                updated.insert(change.id, at: lowerBound)
                changed = true
            }
        }
        return LibraryIncrementalDisplayUpdate(ids: updated, changed: changed)
    }

    private func rebuild(
        books: [Book],
        smartCollections: [LibrarySmartCollectionSnapshot],
        catalogRevision: Int,
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) async {
        let interval = Log.librarySignposter.beginInterval("LibrarySnapshot")
        var records: [LibraryDisplaySnapshot] = []
        var nextRecordsByID: [UUID: LibraryDisplaySnapshot] = [:]
        var nextBooksByID: [UUID: Book] = [:]
        var nextBooksByPersistentID: [Book.ID: Book] = [:]
        var nextSourceIndexByID: [UUID: Int] = [:]
        var nextSourceIndexByPersistentID: [Book.ID: Int] = [:]
        records.reserveCapacity(books.count)
        nextRecordsByID.reserveCapacity(books.count)
        nextBooksByID.reserveCapacity(books.count)
        nextBooksByPersistentID.reserveCapacity(books.count)
        nextSourceIndexByID.reserveCapacity(books.count)
        nextSourceIndexByPersistentID.reserveCapacity(books.count)
        for (index, book) in books.enumerated() {
            let record = LibraryDisplaySnapshot(
                book,
                sourceOrdinal: index,
                includeCollections: true,
                includeHighlights: true
            )
            records.append(record)
            nextRecordsByID[record.id] = record
            nextBooksByID[record.id] = book
            nextBooksByPersistentID[book.id] = book
            nextSourceIndexByID[record.id] = index
            nextSourceIndexByPersistentID[book.id] = index
            if (index + 1).isMultiple(of: 512) {
                await Task.yield()
                guard !Task.isCancelled else {
                    Log.librarySignposter.endInterval("LibrarySnapshot", interval)
                    return
                }
            }
        }
        Log.librarySignposter.endInterval("LibrarySnapshot", interval)

        let facetInterval = Log.librarySignposter.beginInterval("SidebarFacets")
        let nextFacets = await worker.makeFacets(
            records: records,
            smartCollections: smartCollections,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected
        )
        Log.librarySignposter.endInterval("SidebarFacets", facetInterval)
        guard !Task.isCancelled else { return }

        orderedRecords = records
        recordsByID = nextRecordsByID
        booksByID = nextBooksByID
        booksByPersistentID = nextBooksByPersistentID
        sourceIndexByID = nextSourceIndexByID
        sourceIndexByPersistentID = nextSourceIndexByPersistentID
        self.smartCollections = smartCollections
        self.deviceFileNames = deviceFileNames
        self.deviceIsConnected = deviceIsConnected
        self.catalogRevision = catalogRevision
        bookCount = books.count
        facets = nextFacets
        didBootstrap = true
        diagnostics.fullRebuildCount += 1
        diagnostics.lastCapturedRecordCount = books.count
        publish(changes: [], requiresFullDisplayRebuild: true)
    }

    private func publish(
        changes: [LibraryReadModelRecordChange],
        requiresFullDisplayRebuild: Bool
    ) {
        generation &+= 1
        updates.append(
            LibraryReadModelUpdate(
                generation: generation,
                changes: changes,
                requiresFullDisplayRebuild: requiresFullDisplayRebuild
            )
        )
        if updates.count > 128 {
            updates.removeFirst(updates.count - 128)
        }
    }

    private func fullDisplayDelta(since generation: Int) -> LibraryReadModelDisplayDelta {
        LibraryReadModelDisplayDelta(
            fromGeneration: generation,
            toGeneration: self.generation,
            changes: [],
            requiresFullRebuild: true
        )
    }

    private static func smartCollectionSnapshots(
        _ collections: [BookCollection]
    ) -> [LibrarySmartCollectionSnapshot] {
        collections.compactMap { collection in
            guard collection.isSmart, !collection.isWishlist else { return nil }
            let definition = collection.smartShelfDefinition
            guard definition != nil || collection.savedSearch?.isEmpty == false else {
                return nil
            }
            return LibrarySmartCollectionSnapshot(
                id: collection.id,
                savedSearch: definition == nil
                    ? collection.savedSearch.map {
                        LibraryQuery.NormalizedQuery(SearchQuery.parse($0))
                    }
                    : nil,
                definition: definition
            )
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
