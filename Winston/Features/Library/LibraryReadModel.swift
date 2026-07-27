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
        records: [LibraryBookRecord],
        smartCollections: [LibrarySmartCollectionSnapshot],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool,
        now: Date = .now
    ) -> LibraryFacetSnapshot {
        var facets = LibraryFacetSnapshot()
        let recentCutoff = now.addingTimeInterval(-14 * 24 * 3600)
        for record in records {
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
        _ record: LibraryBookRecord,
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
        _ record: LibraryBookRecord,
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
        records: [LibraryBookRecord],
        smartCollections: [LibrarySmartCollectionSnapshot],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) -> [UUID: Int] {
        guard !smartCollections.isEmpty else { return [:] }
        var counts: [UUID: Int] = [:]
        for record in records {
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
        _ record: LibraryBookRecord,
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) -> Bool {
        if let definition {
            return definition.matches(
                record,
                deviceFileNames: deviceFileNames,
                deviceIsConnected: deviceIsConnected
            )
        }
        if let savedSearch {
            return record.normalized.matches(savedSearch)
        }
        return false
    }
}

nonisolated struct LibraryReadModelRecordChange: Equatable, Sendable {
    let id: UUID
    let old: LibraryBookRecord?
    let new: LibraryBookRecord?
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
    let fromGeneration: Int
    let toGeneration: Int
    let changes: [LibraryReadModelRecordChange]
    let requiresFullDisplayRebuild: Bool
}

nonisolated struct LibraryReadModelQueryResult: Equatable, Sendable {
    let generation: Int
    let ids: [UUID]
}

nonisolated struct LibraryReadModelRecordQueryResult: Equatable, Sendable {
    let generation: Int
    let records: [LibraryBookRecord]
}

/// Exact-match facet indexes used only by the metadata query engine.
private nonisolated struct LibraryMetadataFacetIndexes: Sendable {
    var all: Set<UUID> = []
    var collections: [UUID: Set<UUID>] = [:]
    var statuses: [ReadingStatus: Set<UUID>] = [:]
    var formats: [String: Set<UUID>] = [:]
    var authors: [String: Set<UUID>] = [:]
    var series: [String: Set<UUID>] = [:]
    var tags: [String: Set<UUID>] = [:]
    var deviceKeys: [String: Set<UUID>] = [:]
    var rated: Set<UUID> = []

    mutating func add(_ record: LibraryBookRecord) {
        all.insert(record.id)
        Self.insert(record.id, for: record.readingStatus, into: &statuses)
        Self.insert(record.id, for: record.format, into: &formats)
        if !record.displayAuthor.isEmpty {
            Self.insert(record.id, for: record.displayAuthor, into: &authors)
        }
        if let series = record.series, !series.isEmpty {
            Self.insert(record.id, for: series, into: &self.series)
        }
        for id in record.collectionIDs {
            Self.insert(record.id, for: id, into: &collections)
        }
        for tag in record.tags {
            Self.insert(record.id, for: tag, into: &tags)
        }
        for key in record.deviceMatchKeys {
            Self.insert(record.id, for: key, into: &deviceKeys)
        }
        if record.rating > 0 { rated.insert(record.id) }
    }

    mutating func remove(_ record: LibraryBookRecord) {
        all.remove(record.id)
        Self.remove(record.id, for: record.readingStatus, from: &statuses)
        Self.remove(record.id, for: record.format, from: &formats)
        if !record.displayAuthor.isEmpty {
            Self.remove(record.id, for: record.displayAuthor, from: &authors)
        }
        if let series = record.series, !series.isEmpty {
            Self.remove(record.id, for: series, from: &self.series)
        }
        for id in record.collectionIDs {
            Self.remove(record.id, for: id, from: &collections)
        }
        for tag in record.tags {
            Self.remove(record.id, for: tag, from: &tags)
        }
        for key in record.deviceMatchKeys {
            Self.remove(record.id, for: key, from: &deviceKeys)
        }
        rated.remove(record.id)
    }

    func candidates(for filter: LibraryFilter) -> Set<UUID> {
        switch filter {
        case .all, .recentlyAdded:
            all
        case .status(let status):
            statuses[status] ?? []
        case .collection(let id):
            collections[id] ?? []
        case .format(let format):
            formats[format] ?? []
        case .author(let author):
            authors[author] ?? []
        case .series(let series):
            self.series[series] ?? []
        case .tag(let tag):
            tags[tag] ?? []
        case .rated:
            rated
        }
    }

    func onDevice(fileNames: Set<String>) -> Set<UUID> {
        fileNames.reduce(into: Set<UUID>()) { result, fileName in
            result.formUnion(deviceKeys[fileName] ?? [])
        }
    }

    private static func insert<Key: Hashable>(
        _ id: UUID,
        for key: Key,
        into index: inout [Key: Set<UUID>]
    ) {
        index[key, default: []].insert(id)
    }

    private static func remove<Key: Hashable>(
        _ id: UUID,
        for key: Key,
        from index: inout [Key: Set<UUID>]
    ) {
        guard var ids = index[key] else { return }
        ids.remove(id)
        if ids.isEmpty {
            index.removeValue(forKey: key)
        } else {
            index[key] = ids
        }
    }
}

/// Stable, precomputed values used by metadata result ordering.
private nonisolated struct LibraryMetadataSortKeys: Sendable {
    let title: String
    let author: String
    let dateAdded: Date
    let rating: Int
    let seriesIndex: Double

    init(_ record: LibraryBookRecord) {
        title = record.displayTitle
        author = record.displayAuthor
        dateAdded = record.dateAdded
        rating = record.rating
        seriesIndex = record.seriesIndex
    }
}

private nonisolated struct LibraryReadModelSnapshot: Sendable {
    var generation = 0
    var recordsByID: [UUID: LibraryBookRecord] = [:]
    var sortKeysByID: [UUID: LibraryMetadataSortKeys] = [:]
    var sourceOrder: [UUID] = []
    var sourceRank: [UUID: Int] = [:]
    var pluginOrder: [UUID] = []
    var indexes = LibraryMetadataFacetIndexes()

    init(
        generation: Int = 0,
        records: [LibraryBookRecord] = [],
        sourceOrder: [UUID] = []
    ) {
        self.generation = generation
        self.recordsByID = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id, $0) }
        )
        sortKeysByID = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id, LibraryMetadataSortKeys($0)) }
        )
        self.sourceOrder = sourceOrder
        sourceRank = Dictionary(
            uniqueKeysWithValues: sourceOrder.enumerated().map { ($0.element, $0.offset) }
        )
        for record in records {
            indexes.add(record)
        }
        pluginOrder = records.compactMap { $0.pluginBook == nil ? nil : $0.id }
            .sorted { lhs, rhs in
                guard let left = recordsByID[lhs]?.pluginBook,
                      let right = recordsByID[rhs]?.pluginBook else {
                    return lhs.uuidString < rhs.uuidString
                }
                return PluginBookDTO.precedes(left, right)
            }
    }

    mutating func apply(
        changes: [LibraryReadModelRecordChange],
        sourceOrder nextSourceOrder: [UUID]?,
        generation: Int
    ) {
        for change in changes {
            if let old = change.old {
                indexes.remove(old)
                recordsByID.removeValue(forKey: old.id)
                sortKeysByID.removeValue(forKey: old.id)
                pluginOrder.removeAll { $0 == old.id }
            }
            if let new = change.new {
                recordsByID[new.id] = new
                sortKeysByID[new.id] = LibraryMetadataSortKeys(new)
                indexes.add(new)
                if new.pluginBook != nil {
                    insertIntoPluginOrder(new.id)
                }
            }
        }
        if let nextSourceOrder {
            sourceOrder = nextSourceOrder
            sourceRank = Dictionary(
                uniqueKeysWithValues: nextSourceOrder.enumerated().map {
                    ($0.element, $0.offset)
                }
            )
        }
        self.generation = generation
    }

    func orderedRecords() -> [LibraryBookRecord] {
        sourceOrder.compactMap { recordsByID[$0] }
    }

    private mutating func insertIntoPluginOrder(_ id: UUID) {
        guard let candidate = recordsByID[id]?.pluginBook else { return }
        var lowerBound = 0
        var upperBound = pluginOrder.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            guard let existing = recordsByID[pluginOrder[middle]]?.pluginBook else {
                lowerBound = middle + 1
                continue
            }
            if PluginBookDTO.precedes(existing, candidate) {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        pluginOrder.insert(id, at: lowerBound)
    }
}

/// The metadata search engine. It owns the read-model snapshot, facet indexes,
/// cancellation checks, and sort keys; it has no dependency on SQLite FTS.
private actor LibraryMetadataQueryEngine {
    private var snapshot = LibraryReadModelSnapshot()

    func rebuild(
        records: [LibraryBookRecord],
        sourceOrder: [UUID],
        generation: Int
    ) {
        snapshot = LibraryReadModelSnapshot(
            generation: generation,
            records: records,
            sourceOrder: sourceOrder
        )
    }

    func apply(
        changes: [LibraryReadModelRecordChange],
        sourceOrder: [UUID]?,
        generation: Int
    ) {
        snapshot.apply(
            changes: changes,
            sourceOrder: sourceOrder,
            generation: generation
        )
    }

    func makeFacets(
        smartCollections: [LibrarySmartCollectionSnapshot],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) -> LibraryFacetSnapshot {
        LibraryFacetSnapshot.build(
            records: snapshot.orderedRecords(),
            smartCollections: smartCollections,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected
        )
    }

    func query(_ spec: LibraryQuerySpec) -> LibraryReadModelQueryResult {
        var candidates = spec.smartShelf != nil || spec.savedSearch != nil
            ? snapshot.indexes.all
            : snapshot.indexes.candidates(for: spec.filter)
        if spec.deviceIsConnected, spec.kindlePresenceFilter != .all {
            let onDevice = snapshot.indexes.onDevice(fileNames: spec.deviceFileNames)
            switch spec.kindlePresenceFilter {
            case .all:
                break
            case .onKindle:
                candidates.formIntersection(onDevice)
            case .notOnKindle:
                candidates.subtract(onDevice)
            }
        }

        let visibleQuery = LibraryQuery.NormalizedQuery(
            SearchQuery.parse(spec.searchText)
        )
        let savedQuery = spec.savedSearch.map {
            LibraryQuery.NormalizedQuery(SearchQuery.parse($0))
        }
        let recentCutoff = Date.now.addingTimeInterval(-14 * 24 * 3600)
        candidates = candidates.filter { id in
            guard !Task.isCancelled, let record = snapshot.recordsByID[id] else {
                return false
            }
            let belongs: Bool
            if let smartShelf = spec.smartShelf {
                belongs = smartShelf.matches(
                    record,
                    deviceFileNames: spec.deviceFileNames,
                    deviceIsConnected: spec.deviceIsConnected
                )
            } else if let savedQuery {
                belongs = record.normalized.matches(savedQuery)
            } else if case .recentlyAdded = spec.filter {
                belongs = record.dateAdded > recentCutoff
            } else {
                belongs = true
            }
            return belongs && record.normalized.matches(visibleQuery)
        }

        let ids: [UUID]
        if case .series = spec.filter {
            ids = candidates.sorted {
                ordered($0, before: $1, spec: spec, forceSeriesOrder: true)
            }
        } else if spec.sort.field == .source {
            ids = snapshot.sourceOrder.filter(candidates.contains)
        } else {
            ids = candidates.sorted {
                ordered($0, before: $1, spec: spec, forceSeriesOrder: false)
            }
        }
        return LibraryReadModelQueryResult(
            generation: snapshot.generation,
            ids: Task.isCancelled ? [] : ids
        )
    }

    func records(
        matching spec: LibraryQuerySpec
    ) -> LibraryReadModelRecordQueryResult {
        let result = query(spec)
        return LibraryReadModelRecordQueryResult(
            generation: result.generation,
            records: result.ids.compactMap { snapshot.recordsByID[$0] }
        )
    }

    func pluginBooks(
        matching searchText: String,
        offset: Int,
        limit: Int,
        scanLimit: Int,
        maximumOffset: Int
    ) -> PluginBookReadPage {
        guard offset < snapshot.pluginOrder.count else {
            return PluginBookReadPage(items: [], nextOffset: nil)
        }
        let upperBound = min(snapshot.pluginOrder.count, offset + scanLimit)
        let normalizedSearch = LibraryNormalizedStrings.normalize(searchText)
        var items: [PluginBookDTO] = []
        items.reserveCapacity(limit)
        var consumed = 0
        for id in snapshot.pluginOrder[offset ..< upperBound] {
            guard !Task.isCancelled else { break }
            consumed += 1
            guard let libraryRecord = snapshot.recordsByID[id],
                  let pluginBook = libraryRecord.pluginBook,
                  normalizedSearch.isEmpty
                    || libraryRecord.normalized.title.contains(normalizedSearch)
                    || libraryRecord.normalized.author.contains(normalizedSearch)
            else { continue }
            items.append(pluginBook)
            if items.count == limit { break }
        }
        let nextOffset = offset + consumed
        return PluginBookReadPage(
            items: items,
            nextOffset: nextOffset < snapshot.pluginOrder.count
                && nextOffset <= maximumOffset ? nextOffset : nil
        )
    }

    func kindleCandidates() -> [KindleSyncCandidate] {
        snapshot.sourceOrder.compactMap {
            snapshot.recordsByID[$0]?.kindleCandidate
        }
    }

    func kindleTransferDescriptors(
        for bookIDs: [UUID]
    ) -> [KindleSendDescriptor] {
        bookIDs.compactMap {
            snapshot.recordsByID[$0]?.kindleTransferDescriptor
        }
    }

    func deviceMetadata() -> LibraryDeviceMetadataSnapshot {
        var authors: [String: String] = [:]
        for record in snapshot.recordsByID.values {
            guard let author = record.author else { continue }
            for key in record.deviceMatchKeys where authors[key] == nil {
                authors[key] = author
            }
        }
        return LibraryDeviceMetadataSnapshot(
            generation: snapshot.generation,
            libraryKeys: Set(snapshot.indexes.deviceKeys.keys),
            authorByDeviceKey: authors
        )
    }

    private func ordered(
        _ lhsID: UUID,
        before rhsID: UUID,
        spec: LibraryQuerySpec,
        forceSeriesOrder: Bool
    ) -> Bool {
        guard let lhs = snapshot.sortKeysByID[lhsID],
              let rhs = snapshot.sortKeysByID[rhsID] else {
            return lhsID.uuidString < rhsID.uuidString
        }
        if forceSeriesOrder {
            if lhs.seriesIndex != rhs.seriesIndex {
                return lhs.seriesIndex < rhs.seriesIndex
            }
            return sourcePrecedes(lhsID, rhsID)
        }

        let comparison: ComparisonResult
        switch spec.sort.field {
        case .source:
            return sourcePrecedes(lhsID, rhsID)
        case .title:
            comparison = lhs.title.compare(rhs.title)
        case .author:
            comparison = lhs.author.compare(rhs.author)
        case .dateAdded:
            comparison = lhs.dateAdded == rhs.dateAdded
                ? .orderedSame
                : (lhs.dateAdded < rhs.dateAdded ? .orderedAscending : .orderedDescending)
        case .rating:
            comparison = lhs.rating == rhs.rating
                ? .orderedSame
                : (lhs.rating < rhs.rating ? .orderedAscending : .orderedDescending)
        }
        if comparison == .orderedSame {
            return sourcePrecedes(lhsID, rhsID)
        }
        return spec.sort.ascending
            ? comparison == .orderedAscending
            : comparison == .orderedDescending
    }

    private func sourcePrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        let left = snapshot.sourceRank[lhs] ?? .max
        let right = snapshot.sourceRank[rhs] ?? .max
        if left != right { return left < right }
        return lhs.uuidString < rhs.uuidString
    }
}

nonisolated struct LibraryDeviceMetadataSnapshot: Equatable, Sendable {
    let generation: Int
    let libraryKeys: Set<String>
    let authorByDeviceKey: [String: String]
}

@MainActor
@Observable
final class LibraryReadModel {
    private(set) var generation = 0
    private(set) var isReady = false
    private(set) var bookCount = 0
    private(set) var facets = LibraryFacetSnapshot()

    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var orderedRecords: [LibraryBookRecord] = []
    @ObservationIgnored private var recordsByID: [UUID: LibraryBookRecord] = [:]
    @ObservationIgnored private var booksByID: [UUID: Book] = [:]
    @ObservationIgnored private var booksByPersistentID: [Book.ID: Book] = [:]
    @ObservationIgnored private var sourceIndexByID: [UUID: Int] = [:]
    @ObservationIgnored private var sourceIndexByPersistentID: [Book.ID: Int] = [:]
    @ObservationIgnored private var smartCollections: [LibrarySmartCollectionSnapshot] = []
    @ObservationIgnored private var deviceFileNames: Set<String> = []
    @ObservationIgnored private var deviceIsConnected = false
    @ObservationIgnored private var updates: [LibraryReadModelUpdate] = []
    @ObservationIgnored private let metadataEngine = LibraryMetadataQueryEngine()
    @ObservationIgnored private(set) var diagnostics = LibraryReadModelDiagnostics()

    /// Applies the semantic change set returned by `CatalogMutationService`.
    /// The journal-backed synchronization path below remains the recovery mechanism
    /// when a consumer misses one or more individual mutations.
    func apply(
        _ changeSet: CatalogChangeSet,
        catalogGeneration: Int,
        books: [Book],
        collections: [BookCollection],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) async {
        await synchronize(
            books: books,
            collections: collections,
            delta: LibraryCatalogDelta(
                fromRevision: generation,
                toRevision: catalogGeneration,
                affectedBookIDs: changeSet.affectedBookIDs,
                affectedWorkIDs: changeSet.affectedWorkIDs,
                affectedAssetIDs: changeSet.affectedAssetIDs,
                affectedCollectionIDs: changeSet.affectedCollectionIDs,
                fields: changeSet.fields,
                requiresFullRebuild: catalogGeneration != generation + 1,
                changesBookMembership: changeSet.command.changesBookMembership
            ),
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected
        )
    }

    func synchronize(
        books: [Book],
        collections: [BookCollection],
        delta: LibraryCatalogDelta,
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) async {
        guard delta.toRevision >= generation else { return }
        let nextSmartCollections = Self.smartCollectionSnapshots(collections)
        let configurationChanged = nextSmartCollections != smartCollections
            || deviceFileNames != self.deviceFileNames
            || deviceIsConnected != self.deviceIsConnected

        if !didBootstrap
            || delta.requiresFullRebuild
            || delta.fromRevision != generation {
            await rebuild(
                books: books,
                smartCollections: nextSmartCollections,
                catalogGeneration: delta.toRevision,
                deviceFileNames: deviceFileNames,
                deviceIsConnected: deviceIsConnected
            )
            return
        }

        let recordRelevantFields: CatalogChangeFields = [
            .identity,
            .displayMetadata,
            .assetAvailability,
            .collectionMembership,
            .readingState,
            .cover,
            .workMembership,
        ]
        if !configurationChanged,
           !delta.changesBookMembership,
           delta.fields.isDisjoint(with: recordRelevantFields) {
            diagnostics.lastCapturedRecordCount = 0
            await metadataEngine.apply(
                changes: [],
                sourceOrder: nil,
                generation: delta.toRevision
            )
            publish(
                fromGeneration: generation,
                toGeneration: delta.toRevision,
                changes: [],
                requiresFullDisplayRebuild: false
            )
            return
        }

        let currentSourceOrder = books.map(\.uuid)
        let currentSourceIndex = Dictionary(
            uniqueKeysWithValues: currentSourceOrder.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        let currentBooksByID: [UUID: Book]
        if delta.changesBookMembership || books.count != bookCount {
            currentBooksByID = Dictionary(
                uniqueKeysWithValues: books.map { ($0.uuid, $0) }
            )
        } else {
            currentBooksByID = booksByID
        }

        var affectedIDs = delta.affectedBookIDs
        if delta.changesBookMembership || books.count != bookCount {
            let previousIDs = Set(recordsByID.keys)
            let currentIDs = Set(currentBooksByID.keys)
            affectedIDs.formUnion(previousIDs.symmetricDifference(currentIDs))
        }

        var recordChanges: [LibraryReadModelRecordChange] = []
        recordChanges.reserveCapacity(affectedIDs.count)
        for id in affectedIDs {
            let old = recordsByID[id]
            guard let book = currentBooksByID[id] else {
                guard let old else {
                    await rebuild(
                        books: books,
                        smartCollections: nextSmartCollections,
                        catalogGeneration: delta.toRevision,
                        deviceFileNames: deviceFileNames,
                        deviceIsConnected: deviceIsConnected
                    )
                    return
                }
                recordsByID.removeValue(forKey: id)
                booksByID.removeValue(forKey: id)
                if let persistentID = booksByPersistentID.first(where: {
                    $0.value.uuid == id
                })?.key {
                    booksByPersistentID.removeValue(forKey: persistentID)
                }
                recordChanges.append(
                    LibraryReadModelRecordChange(id: id, old: old, new: nil)
                )
                continue
            }
            guard let index = currentSourceIndex[id] else {
                await rebuild(
                    books: books,
                    smartCollections: nextSmartCollections,
                    catalogGeneration: delta.toRevision,
                    deviceFileNames: deviceFileNames,
                    deviceIsConnected: deviceIsConnected
                )
                return
            }
            let updated = LibraryBookRecord(
                book,
                sourceOrdinal: index,
                includeCollections: true,
                includeHighlights: true
            )
            guard old != updated else { continue }
            recordsByID[id] = updated
            booksByID[id] = book
            booksByPersistentID[book.id] = book
            recordChanges.append(
                LibraryReadModelRecordChange(id: id, old: old, new: updated)
            )
        }

        let membershipChanged = delta.changesBookMembership || books.count != bookCount
        let sourceOrderChanged = membershipChanged
            || currentSourceOrder != orderedRecords.map(\.id)
        if sourceOrderChanged {
            guard recordsByID.count == books.count else {
                await rebuild(
                    books: books,
                    smartCollections: nextSmartCollections,
                    catalogGeneration: delta.toRevision,
                    deviceFileNames: deviceFileNames,
                    deviceIsConnected: deviceIsConnected
                )
                return
            }
            orderedRecords = currentSourceOrder.compactMap { recordsByID[$0] }
            booksByID = currentBooksByID
            booksByPersistentID = Dictionary(
                uniqueKeysWithValues: books.map { ($0.id, $0) }
            )
            sourceIndexByID = currentSourceIndex
            sourceIndexByPersistentID = Dictionary(
                uniqueKeysWithValues: books.enumerated().map {
                    ($0.element.id, $0.offset)
                }
            )
            bookCount = books.count
        } else if !recordChanges.isEmpty {
            for change in recordChanges {
                guard let new = change.new,
                      let index = sourceIndexByID[change.id] else { continue }
                orderedRecords[index] = new
            }
        }

        diagnostics.lastCapturedRecordCount = affectedIDs.count
        diagnostics.incrementallyCapturedRecordCount += affectedIDs.count
        let sourceOrderUpdate = sourceOrderChanged ? currentSourceOrder : nil
        await metadataEngine.apply(
            changes: recordChanges,
            sourceOrder: sourceOrderUpdate,
            generation: delta.toRevision
        )

        if configurationChanged {
            let interval = Log.librarySignposter.beginInterval("SidebarFacets")
            LibraryPerformanceDiagnostics.beginSQLScope("sidebar_facets")
            let rebuiltFacets = await metadataEngine.makeFacets(
                smartCollections: nextSmartCollections,
                deviceFileNames: deviceFileNames,
                deviceIsConnected: deviceIsConnected
            )
            LibraryPerformanceDiagnostics.endSQLScope("sidebar_facets")
            Log.librarySignposter.endInterval("SidebarFacets", interval)
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
        publish(
            fromGeneration: generation,
            toGeneration: delta.toRevision,
            changes: recordChanges,
            requiresFullDisplayRebuild: configurationChanged || sourceOrderChanged
        )
    }

    func recordSnapshot() -> [LibraryBookRecord] {
        orderedRecords
    }

    func query(_ spec: LibraryQuerySpec) async -> LibraryReadModelQueryResult {
        await metadataEngine.query(spec)
    }

    func records(matching spec: LibraryQuerySpec) async -> LibraryReadModelRecordQueryResult {
        await metadataEngine.records(matching: spec)
    }

    func displayIDs(query: LibraryQuerySpec) async -> [UUID] {
        await metadataEngine.query(query).ids
    }

    func pluginBooks(
        matching searchText: String,
        offset: Int,
        limit: Int,
        scanLimit: Int,
        maximumOffset: Int
    ) async -> PluginBookReadPage? {
        guard didBootstrap else { return nil }
        return await metadataEngine.pluginBooks(
            matching: searchText,
            offset: offset,
            limit: limit,
            scanLimit: scanLimit,
            maximumOffset: maximumOffset
        )
    }

    func pluginBook(uuid: UUID) -> PluginBookDTO? {
        recordsByID[uuid]?.pluginBook
    }

    func kindleCandidates() async -> [KindleSyncCandidate]? {
        guard didBootstrap else { return nil }
        return await metadataEngine.kindleCandidates()
    }

    func kindleTransferDescriptors(
        for bookIDs: [UUID]
    ) async -> [KindleSendDescriptor]? {
        guard didBootstrap else { return nil }
        return await metadataEngine.kindleTransferDescriptors(for: bookIDs)
    }

    func deviceMetadata() async -> LibraryDeviceMetadataSnapshot? {
        guard didBootstrap else { return nil }
        return await metadataEngine.deviceMetadata()
    }

    func record(for id: UUID) -> LibraryBookRecord? {
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

        let pending = updates.filter { $0.toGeneration > generation }
        let isContiguous = zip(pending, pending.dropFirst()).allSatisfy {
            $0.toGeneration == $1.fromGeneration
        }
        guard pending.first?.fromGeneration == generation,
              pending.last?.toGeneration == self.generation,
              isContiguous else {
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
        query: LibraryQuerySpec
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
        catalogGeneration: Int,
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) async {
        let interval = Log.librarySignposter.beginInterval("LibrarySnapshot")
        LibraryPerformanceDiagnostics.beginSQLScope("library_snapshot")
        var records: [LibraryBookRecord] = []
        var nextRecordsByID: [UUID: LibraryBookRecord] = [:]
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
            let record = LibraryBookRecord(
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
                    LibraryPerformanceDiagnostics.endSQLScope("library_snapshot")
                    Log.librarySignposter.endInterval("LibrarySnapshot", interval)
                    return
                }
            }
        }
        LibraryPerformanceDiagnostics.endSQLScope("library_snapshot")
        Log.librarySignposter.endInterval("LibrarySnapshot", interval)

        let facetInterval = Log.librarySignposter.beginInterval("SidebarFacets")
        LibraryPerformanceDiagnostics.beginSQLScope("sidebar_facets")
        await metadataEngine.rebuild(
            records: records,
            sourceOrder: records.map(\.id),
            generation: catalogGeneration
        )
        let nextFacets = await metadataEngine.makeFacets(
            smartCollections: smartCollections,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected
        )
        LibraryPerformanceDiagnostics.endSQLScope("sidebar_facets")
        Log.librarySignposter.endInterval("SidebarFacets", facetInterval)

        orderedRecords = records
        recordsByID = nextRecordsByID
        booksByID = nextBooksByID
        booksByPersistentID = nextBooksByPersistentID
        sourceIndexByID = nextSourceIndexByID
        sourceIndexByPersistentID = nextSourceIndexByPersistentID
        self.smartCollections = smartCollections
        self.deviceFileNames = deviceFileNames
        self.deviceIsConnected = deviceIsConnected
        bookCount = books.count
        facets = nextFacets
        didBootstrap = true
        isReady = true
        diagnostics.fullRebuildCount += 1
        diagnostics.lastCapturedRecordCount = books.count
        publish(
            fromGeneration: generation,
            toGeneration: catalogGeneration,
            changes: [],
            requiresFullDisplayRebuild: true
        )
    }

    private func publish(
        fromGeneration: Int,
        toGeneration: Int,
        changes: [LibraryReadModelRecordChange],
        requiresFullDisplayRebuild: Bool
    ) {
        generation = toGeneration
        updates.append(
            LibraryReadModelUpdate(
                fromGeneration: fromGeneration,
                toGeneration: toGeneration,
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
