import Foundation
import Observation
import OSLog
import SwiftData

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
    private var tagCountsByComparisonKey: [String: Int] = [:]
    private var tagSpellingsByComparisonKey: [String: [String: Int]] = [:]

    static func build(
        records: [LibraryBookRecord],
        smartCollections: [LibrarySmartCollectionSnapshot],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool,
        now: Date = .now
    ) -> LibraryFacetSnapshot {
        var facets = LibraryFacetSnapshot()
        let recentCutoff = LibraryRelativeDateFilter
            .recentlyAddedCutoff(relativeTo: now)
        for record in records {
            facets.adjust(record, by: 1, recentCutoff: recentCutoff)
        }
        facets.refreshKeys()
        facets.smartCounts = Self.makeSmartCounts(
            records: records,
            smartCollections: smartCollections,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected
        )
        return facets
    }

    @discardableResult
    mutating func apply(
        _ changes: [LibraryReadModelRecordChange],
        smartCollections: [LibrarySmartCollectionSnapshot],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool,
        now: Date = .now
    ) -> Int {
        let recentCutoff = LibraryRelativeDateFilter
            .recentlyAddedCutoff(relativeTo: now)
        var shouldRefreshKeys = false
        var smartShelfEvaluationCount = 0
        for change in changes {
            if let old = change.old {
                adjust(old, by: -1, comparedTo: change.new, recentCutoff: recentCutoff)
            }
            if let new = change.new {
                adjust(new, by: 1, comparedTo: change.old, recentCutoff: recentCutoff)
            }
            if change.old?.format != change.new?.format
                || change.old?.displayAuthor != change.new?.displayAuthor
                || change.old?.series != change.new?.series
                || change.old?.tags != change.new?.tags {
                shouldRefreshKeys = true
            }

            let changedDependencies = change.smartShelfChangedDependencies
            let searchFieldsChanged = change.old?.normalized != change.new?.normalized
            for collection in smartCollections {
                let needsEvaluation = collection.compiledDefinition != nil
                    ? !collection.dependencies.isDisjoint(with: changedDependencies)
                    : collection.savedSearch != nil && searchFieldsChanged
                guard needsEvaluation else { continue }
                let oldMatches = change.old.map {
                    smartShelfEvaluationCount += 1
                    return collection.matches(
                        $0,
                        deviceFileNames: deviceFileNames,
                        deviceIsConnected: deviceIsConnected
                    )
                } ?? false
                let newMatches = change.new.map {
                    smartShelfEvaluationCount += 1
                    return collection.matches(
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
        if shouldRefreshKeys { refreshKeys() }
        return smartShelfEvaluationCount
    }

    @discardableResult
    mutating func refreshRecentCount(
        records: [LibraryBookRecord],
        now: Date = .now
    ) -> Bool {
        let recentCutoff = LibraryRelativeDateFilter
            .recentlyAddedCutoff(relativeTo: now)
        let refreshedRecent = records.count {
            $0.dateAdded > recentCutoff
        }
        guard refreshedRecent != recent else { return false }
        recent = refreshedRecent
        return true
    }

    @discardableResult
    mutating func applyDeviceConfigurationChange(
        records: [LibraryBookRecord],
        smartCollections: [LibrarySmartCollectionSnapshot],
        oldDeviceFileNames: Set<String>,
        newDeviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) -> Int {
        let deviceCollections = smartCollections.filter(\.hasDeviceDependency)
        guard !records.isEmpty, !deviceCollections.isEmpty else { return 0 }
        var evaluationCount = 0
        for record in records {
            for collection in deviceCollections {
                evaluationCount += 2
                let oldMatches = collection.matches(
                    record,
                    deviceFileNames: oldDeviceFileNames,
                    deviceIsConnected: deviceIsConnected
                )
                let newMatches = collection.matches(
                    record,
                    deviceFileNames: newDeviceFileNames,
                    deviceIsConnected: deviceIsConnected
                )
                guard oldMatches != newMatches else { continue }
                if newMatches {
                    smartCounts[collection.id, default: 0] += 1
                } else {
                    Self.decrement(&smartCounts, key: collection.id)
                }
            }
        }
        return evaluationCount
    }

    private mutating func adjust(
        _ record: LibraryBookRecord,
        by delta: Int,
        comparedTo other: LibraryBookRecord? = nil,
        recentCutoff: Date
    ) {
        if record.format != other?.format {
            Self.adjust(&formats, key: record.format, by: delta)
        }
        if record.displayAuthor != other?.displayAuthor, !record.displayAuthor.isEmpty {
            Self.adjust(&authors, key: record.displayAuthor, by: delta)
        }
        if record.series != other?.series, let series = record.series, !series.isEmpty {
            Self.adjust(&self.series, key: series, by: delta)
        }
        if record.tags != other?.tags {
            for (tag, key) in zip(record.tags, record.normalized.tags) where !key.isEmpty {
                Self.adjust(&tagCountsByComparisonKey, key: key, by: delta)
                Self.adjust(&tagSpellingsByComparisonKey[key, default: [:]], key: tag, by: delta)
                if tagSpellingsByComparisonKey[key]?.isEmpty == true {
                    tagSpellingsByComparisonKey.removeValue(forKey: key)
                }
            }
        }
        if record.rating > 0, other?.rating ?? 0 <= 0 {
            rated = max(0, rated + delta)
        }
        if record.readingStatus != other?.readingStatus {
            Self.adjust(&statusCounts, key: record.readingStatus, by: delta)
        }
        if record.dateAdded > recentCutoff,
           other.map({ $0.dateAdded > recentCutoff }) != true {
            recent = max(0, recent + delta)
        }
    }

    private mutating func refreshKeys() {
        formatKeys = formats.keys.sorted()
        authorKeys = authors.keys.sorted()
        seriesKeys = series.compactMap { name, count in
            count > 1 ? name : nil
        }.sorted()
        tags = Dictionary(uniqueKeysWithValues:
            tagCountsByComparisonKey.compactMap { key, count in
                guard let spellings = tagSpellingsByComparisonKey[key],
                      let preferred = spellings.keys.sorted(by: { lhs, rhs in
                          let leftCount = spellings[lhs, default: 0]
                          let rightCount = spellings[rhs, default: 0]
                          if leftCount != rightCount {
                              return leftCount > rightCount
                          }
                          let order = lhs.localizedStandardCompare(rhs)
                          return order == .orderedSame
                              ? lhs < rhs
                              : order == .orderedAscending
                      }).first else {
                    return nil
                }
                return (preferred, count)
            }
        )
        tagKeys = tags.keys.sorted()
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
        adjust(&counts, key: key, by: -1)
    }

    private static func adjust<Key: Hashable>(
        _ counts: inout [Key: Int], key: Key, by delta: Int
    ) {
        let updated = counts[key, default: 0] + delta
        if updated <= 0 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = updated
        }
    }
}

nonisolated struct LibrarySmartCollectionSnapshot: Equatable, Sendable {
    let id: UUID
    let savedSearch: LibraryQuery.NormalizedQuery?
    let compiledDefinition: CompiledSmartShelfDefinition?

    var dependencies: SmartShelfFieldDependencies {
        compiledDefinition?.dependencies ?? .all
    }

    var hasDeviceDependency: Bool {
        compiledDefinition?.dependencies.contains(.devicePresence) == true
    }

    func matches(
        _ record: LibraryBookRecord,
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) -> Bool {
        if let compiledDefinition {
            return compiledDefinition.matches(
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

    var smartShelfChangedDependencies: SmartShelfFieldDependencies {
        guard let old, let new else { return .all }
        var dependencies: SmartShelfFieldDependencies = []
        if old.readingStatus != new.readingStatus {
            dependencies.insert(.readingStatus)
        }
        if old.language != new.language {
            dependencies.insert(.language)
        }
        if old.pageCount != new.pageCount {
            dependencies.insert(.pageCount)
        }
        if old.format != new.format {
            dependencies.insert(.format)
        }
        if old.userRating != new.userRating {
            dependencies.insert(.rating)
        }
        if old.translator != new.translator {
            dependencies.insert(.translator)
        }
        if old.tags != new.tags {
            dependencies.insert(.tags)
        }
        if old.author != new.author {
            dependencies.insert(.author)
        }
        if old.title != new.title {
            dependencies.insert(.title)
        }
        if old.series != new.series {
            dependencies.insert(.series)
        }
        if old.publisher != new.publisher {
            dependencies.insert(.publisher)
        }
        if old.hasHighlights != new.hasHighlights {
            dependencies.insert(.highlights)
        }
        if old.drmProtected != new.drmProtected {
            dependencies.insert(.drmProtected)
        }
        if old.deviceMatchKeys != new.deviceMatchKeys {
            dependencies.insert(.devicePresence)
        }
        if old.hasMissingMetadata != new.hasMissingMetadata {
            dependencies.insert(.missingMetadata)
        }
        return dependencies
    }
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
    var lastSmartShelfEvaluationCount = 0
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
        Self.insert(
            record.id,
            for: MetadataNormalizer.formatFilterKey(record.format),
            into: &formats
        )
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
            Self.insert(
                record.id,
                for: MetadataNormalizer.tagComparisonKey(tag),
                into: &tags
            )
        }
        for key in record.deviceMatchKeys {
            Self.insert(record.id, for: key, into: &deviceKeys)
        }
        if record.rating > 0 { rated.insert(record.id) }
    }

    mutating func remove(_ record: LibraryBookRecord) {
        all.remove(record.id)
        Self.remove(record.id, for: record.readingStatus, from: &statuses)
        Self.remove(
            record.id,
            for: MetadataNormalizer.formatFilterKey(record.format),
            from: &formats
        )
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
            Self.remove(
                record.id,
                for: MetadataNormalizer.tagComparisonKey(tag),
                from: &tags
            )
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
            formats[MetadataNormalizer.formatFilterKey(format)] ?? []
        case .author(let author):
            authors[author] ?? []
        case .series(let series):
            self.series[series] ?? []
        case .tag(let tag):
            tags[MetadataNormalizer.tagComparisonKey(tag)] ?? []
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
        // Mutate the dictionary's value in place; extracting a Set first copies
        // an entire facet bucket on every individual catalog mutation.
        index[key]?.remove(id)
        if index[key]?.isEmpty == true {
            index.removeValue(forKey: key)
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
        let reorderedPluginIDs = Set(changes.compactMap { change in
            recordsByID[change.id]?.pluginBook?.displayTitle != change.new?.pluginBook?.displayTitle
                ? change.id : nil
        })
        if !reorderedPluginIDs.isEmpty {
            pluginOrder.removeAll { reorderedPluginIDs.contains($0) }
        }
        for change in changes {
            // A superseded synchronization may have reached this actor before
            // publishing on MainActor. Remove the actual indexed version.
            if let old = recordsByID[change.id] {
                indexes.remove(old)
                recordsByID.removeValue(forKey: old.id)
                sortKeysByID.removeValue(forKey: old.id)
            }
            if let new = change.new {
                recordsByID[new.id] = new
                sortKeysByID[new.id] = LibraryMetadataSortKeys(new)
                indexes.add(new)
            }
        }
        if !reorderedPluginIDs.isEmpty {
            let additions = reorderedPluginIDs.filter {
                recordsByID[$0]?.pluginBook != nil
            }.sorted(by: pluginPrecedes)
            pluginOrder = mergingLibraryIDs(pluginOrder, additions, by: pluginPrecedes)
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

    private func pluginPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        guard let left = recordsByID[lhs]?.pluginBook,
              let right = recordsByID[rhs]?.pluginBook else {
            return lhs.uuidString < rhs.uuidString
        }
        return PluginBookDTO.precedes(left, right)
    }
}

/// Apply a sorted batch in one pass instead of repeatedly shifting a full array.
private nonisolated func mergingLibraryIDs(
    _ existing: [UUID],
    _ additions: [UUID],
    by precedes: (UUID, UUID) -> Bool
) -> [UUID] {
    guard !additions.isEmpty else { return existing }
    var result: [UUID] = []
    result.reserveCapacity(existing.count + additions.count)
    var index = 0
    for addition in additions {
        while index < existing.count, precedes(existing[index], addition) {
            result.append(existing[index])
            index += 1
        }
        result.append(addition)
    }
    result.append(contentsOf: existing[index...])
    return result
}

/// The metadata search engine. It owns the read-model snapshot, facet indexes,
/// cancellation checks, and sort keys; it has no dependency on SQLite FTS.
actor LibraryMetadataQueryEngine {
    private var snapshot = LibraryReadModelSnapshot()
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    func rebuild(
        records: [LibraryBookRecord],
        sourceOrder: [UUID],
        generation: Int
    ) {
        guard generation >= snapshot.generation else { return }
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
        guard generation >= snapshot.generation else { return }
        snapshot.apply(
            changes: changes,
            sourceOrder: sourceOrder,
            generation: generation
        )
    }

    func makeFacets(
        smartCollections: [LibrarySmartCollectionSnapshot],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool,
        evaluatedAt: Date? = nil
    ) -> LibraryFacetSnapshot {
        LibraryFacetSnapshot.build(
            records: snapshot.orderedRecords(),
            smartCollections: smartCollections,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected,
            now: evaluatedAt ?? now()
        )
    }

    func query(_ spec: LibraryQuerySpec) -> LibraryReadModelQueryResult {
        let cancelled = LibraryReadModelQueryResult(generation: snapshot.generation, ids: [])
        guard !Task.isCancelled else { return cancelled }
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

        let matcher = LibraryQuery.Matcher(spec, now: now())
        var matching: [UUID] = []
        matching.reserveCapacity(candidates.count)
        for id in candidates {
            guard !Task.isCancelled else { return cancelled }
            if let record = snapshot.recordsByID[id], matcher.matches(record) {
                matching.append(id)
            }
        }
        guard !Task.isCancelled else { return cancelled }

        let ids: [UUID]
        if case .series = spec.filter {
            ids = sortedIDs(matching, spec: spec, forceSeriesOrder: true)
        } else if spec.sort.field == .source,
                  matching.count >= snapshot.sourceOrder.count / 4 {
            let membership = Set(matching)
            var sourceMatches: [UUID] = []
            sourceMatches.reserveCapacity(matching.count)
            for id in snapshot.sourceOrder {
                guard !Task.isCancelled else { return cancelled }
                if membership.contains(id) { sourceMatches.append(id) }
            }
            ids = sourceMatches
        } else {
            ids = sortedIDs(matching, spec: spec, forceSeriesOrder: false)
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

    func records(matchingDeviceKeys keys: Set<String>) -> [LibraryBookRecord] {
        let ids = keys.reduce(into: Set<UUID>()) { result, key in
            result.formUnion(snapshot.indexes.deviceKeys[key] ?? [])
        }
        return ids.compactMap { snapshot.recordsByID[$0] }
    }

    private func sortedIDs(
        _ ids: [UUID], spec: LibraryQuerySpec, forceSeriesOrder: Bool
    ) -> [UUID] {
        var comparisons = 0
        return (try? ids.sorted {
            if comparisons.isMultiple(of: 256) { try Task.checkCancellation() }
            comparisons += 1
            return ordered($0, before: $1, spec: spec, forceSeriesOrder: forceSeriesOrder)
        }) ?? []
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
    private(set) var relativeFilterRevision = 0
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
    @ObservationIgnored private var deviceGeneration = -1
    @ObservationIgnored private var nextRecentExpiration: Date?
    @ObservationIgnored private var lastRelativeFacetCheck: Date?
    @ObservationIgnored private var updates: [LibraryReadModelUpdate] = []
    @ObservationIgnored private let metadataEngine: LibraryMetadataQueryEngine
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let synchronizationHook: @Sendable (Int) async -> Void
    @ObservationIgnored private var synchronizationEpoch = 0
    @ObservationIgnored private var highestRequestedGeneration = -1
    @ObservationIgnored private(set) var diagnostics = LibraryReadModelDiagnostics()

    init(
        now: @escaping @Sendable () -> Date = { .now },
        synchronizationHook: @escaping @Sendable (Int) async -> Void = { _ in }
    ) {
        self.now = now
        metadataEngine = LibraryMetadataQueryEngine(now: now)
        self.synchronizationHook = synchronizationHook
    }

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
        deviceIsConnected: Bool,
        deviceInventoryDelta: DeviceInventoryDelta? = nil
    ) async {
        guard delta.toRevision >= generation,
              delta.toRevision >= highestRequestedGeneration else { return }
        highestRequestedGeneration = max(
            highestRequestedGeneration,
            delta.toRevision
        )
        synchronizationEpoch &+= 1
        let requestEpoch = synchronizationEpoch
        await synchronizationHook(delta.toRevision)
        guard requestIsCurrent(
            requestEpoch,
            generation: delta.toRevision
        ) else { return }
        let synchronizationNow = now()
        let nextSmartCollections = Self.smartCollectionSnapshots(collections)
        let smartCollectionsChanged = nextSmartCollections != smartCollections
        let deviceFilesChanged = deviceFileNames != self.deviceFileNames
        let deviceConnectionChanged = deviceIsConnected != self.deviceIsConnected
        let configurationChanged = smartCollectionsChanged
            || deviceFilesChanged
            || deviceConnectionChanged

        if !didBootstrap
            || delta.requiresFullRebuild
            || delta.fromRevision != generation {
            await rebuild(
                books: books,
                smartCollections: nextSmartCollections,
                catalogGeneration: delta.toRevision,
                deviceFileNames: deviceFileNames,
                deviceIsConnected: deviceIsConnected,
                deviceGeneration: deviceInventoryDelta?.toGeneration,
                requestEpoch: requestEpoch
            )
            return
        }

        refreshRelativeFacets(now: synchronizationNow)

        if delta.isEmpty,
           !smartCollectionsChanged,
           deviceFilesChanged,
           !deviceConnectionChanged,
           let deviceInventoryDelta,
           deviceInventoryDelta.fromGeneration == deviceGeneration {
            let affectedRecords = await metadataEngine.records(
                matchingDeviceKeys: deviceInventoryDelta.changedMatchKeys
            )
            guard requestIsCurrent(
                requestEpoch,
                generation: delta.toRevision
            ) else { return }
            var updatedFacets = facets
            diagnostics.lastSmartShelfEvaluationCount =
                updatedFacets.applyDeviceConfigurationChange(
                    records: affectedRecords,
                    smartCollections: smartCollections,
                    oldDeviceFileNames: self.deviceFileNames,
                    newDeviceFileNames: deviceFileNames,
                    deviceIsConnected: deviceIsConnected
                )
            facets = updatedFacets
            self.deviceFileNames = deviceFileNames
            self.deviceGeneration = deviceInventoryDelta.toGeneration
            diagnostics.lastCapturedRecordCount = affectedRecords.count
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
            await metadataEngine.apply(
                changes: [],
                sourceOrder: nil,
                generation: delta.toRevision
            )
            guard requestIsCurrent(
                requestEpoch,
                generation: delta.toRevision
            ) else { return }
            diagnostics.lastCapturedRecordCount = 0
            diagnostics.lastSmartShelfEvaluationCount = 0
            publish(
                fromGeneration: generation,
                toGeneration: delta.toRevision,
                changes: [],
                requiresFullDisplayRebuild: false
            )
            return
        }

        let membershipChanged = delta.changesBookMembership || books.count != bookCount
        let currentSourceOrder = membershipChanged || delta.fields.contains(.identity)
            ? books.map(\.uuid) : nil
        let sourceOrderChanged = membershipChanged || currentSourceOrder?.enumerated().contains {
            sourceIndexByID[$0.element] != $0.offset
        } == true
        let currentSourceIndex = sourceOrderChanged
            ? Dictionary(uniqueKeysWithValues: (currentSourceOrder ?? []).enumerated().map {
                ($0.element, $0.offset)
            }) : sourceIndexByID
        let currentBooksByID: [UUID: Book]
        if membershipChanged {
            currentBooksByID = Dictionary(
                uniqueKeysWithValues: books.map { ($0.uuid, $0) }
            )
        } else {
            currentBooksByID = booksByID
        }

        var affectedIDs = delta.affectedBookIDs
        if membershipChanged {
            let previousIDs = Set(recordsByID.keys)
            let currentIDs = Set(currentBooksByID.keys)
            affectedIDs.formUnion(previousIDs.symmetricDifference(currentIDs))
        }

        var recordChanges: [LibraryReadModelRecordChange] = []
        recordChanges.reserveCapacity(affectedIDs.count)
        let captureClock = ContinuousClock()
        var nextCaptureYield = captureClock.now.advanced(by: .milliseconds(4))
        for id in affectedIDs {
            if captureClock.now >= nextCaptureYield {
                await Task.yield()
                guard requestIsCurrent(requestEpoch, generation: delta.toRevision) else { return }
                nextCaptureYield = captureClock.now.advanced(by: .milliseconds(4))
            }
            let old = recordsByID[id]
            guard let book = currentBooksByID[id] else {
                guard let old else {
                    await rebuild(
                        books: books,
                        smartCollections: nextSmartCollections,
                        catalogGeneration: delta.toRevision,
                        deviceFileNames: deviceFileNames,
                        deviceIsConnected: deviceIsConnected,
                        deviceGeneration: deviceInventoryDelta?.toGeneration,
                        requestEpoch: requestEpoch
                    )
                    return
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
                    deviceIsConnected: deviceIsConnected,
                    deviceGeneration: deviceInventoryDelta?.toGeneration,
                    requestEpoch: requestEpoch
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
            recordChanges.append(
                LibraryReadModelRecordChange(id: id, old: old, new: updated)
            )
        }

        if sourceOrderChanged {
            let deletedCount = recordChanges.count {
                $0.old != nil && $0.new == nil
            }
            let insertedCount = recordChanges.count {
                $0.old == nil && $0.new != nil
            }
            guard recordsByID.count - deletedCount + insertedCount == books.count else {
                await rebuild(
                    books: books,
                    smartCollections: nextSmartCollections,
                    catalogGeneration: delta.toRevision,
                    deviceFileNames: deviceFileNames,
                    deviceIsConnected: deviceIsConnected,
                    deviceGeneration: deviceInventoryDelta?.toGeneration,
                    requestEpoch: requestEpoch
                )
                return
            }
        }

        let sourceOrderUpdate = sourceOrderChanged ? currentSourceOrder : nil
        await metadataEngine.apply(
            changes: recordChanges,
            sourceOrder: sourceOrderUpdate,
            generation: delta.toRevision
        )

        let rebuiltFacets: LibraryFacetSnapshot?
        if configurationChanged {
            let interval = Log.librarySignposter.beginInterval("SidebarFacets")
            LibraryPerformanceDiagnostics.beginSQLScope("sidebar_facets")
            rebuiltFacets = await metadataEngine.makeFacets(
                smartCollections: nextSmartCollections,
                deviceFileNames: deviceFileNames,
                deviceIsConnected: deviceIsConnected,
                evaluatedAt: synchronizationNow
            )
            LibraryPerformanceDiagnostics.endSQLScope("sidebar_facets")
            Log.librarySignposter.endInterval("SidebarFacets", interval)
        } else {
            rebuiltFacets = nil
        }

        guard requestIsCurrent(
            requestEpoch,
            generation: delta.toRevision
        ) else { return }

        for change in recordChanges {
            if let new = change.new,
               let book = currentBooksByID[change.id] {
                if let previous = booksByID[change.id], previous.id != book.id {
                    booksByPersistentID.removeValue(forKey: previous.id)
                }
                recordsByID[change.id] = new
                booksByID[change.id] = book
                booksByPersistentID[book.id] = book
            } else {
                recordsByID.removeValue(forKey: change.id)
                if let previous = booksByID.removeValue(forKey: change.id) {
                    booksByPersistentID.removeValue(forKey: previous.id)
                }
            }
        }

        if sourceOrderChanged {
            orderedRecords = (currentSourceOrder ?? []).compactMap { recordsByID[$0] }
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
        if let rebuiltFacets {
            facets = rebuiltFacets
            diagnostics.lastSmartShelfEvaluationCount =
                orderedRecords.count * nextSmartCollections.count
        } else if !recordChanges.isEmpty {
            var updatedFacets = facets
            diagnostics.lastSmartShelfEvaluationCount = updatedFacets.apply(
                recordChanges,
                smartCollections: smartCollections,
                deviceFileNames: self.deviceFileNames,
                deviceIsConnected: self.deviceIsConnected,
                now: synchronizationNow
            )
            facets = updatedFacets
        } else {
            diagnostics.lastSmartShelfEvaluationCount = 0
        }
        for change in recordChanges {
            if let dateAdded = change.new?.dateAdded {
                scheduleRecentExpiration(dateAdded: dateAdded, now: synchronizationNow)
            }
        }

        smartCollections = nextSmartCollections
        self.deviceFileNames = deviceFileNames
        self.deviceIsConnected = deviceIsConnected
        if let deviceInventoryDelta {
            deviceGeneration = deviceInventoryDelta.toGeneration
        }
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

    func refreshRelativeFacets() {
        refreshRelativeFacets(now: now())
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
        let matcher = LibraryQuery.Matcher(query, now: now())
        var removed: Set<UUID> = []
        var added: Set<UUID> = []

        for change in delta.changes {
            let oldMatches = change.old.map(matcher.matches) ?? false
            let newMatches = change.new.map(matcher.matches) ?? false

            if oldMatches, newMatches,
               let old = change.old,
               let new = change.new,
               !LibraryQuery.displayOrderingChanged(from: old, to: new, query: query) {
                continue
            }
            if !oldMatches, !newMatches { continue }

            if oldMatches { removed.insert(change.id) }
            if newMatches { added.insert(change.id) }
        }
        guard !removed.isEmpty || !added.isEmpty else {
            return LibraryIncrementalDisplayUpdate(ids: currentIDs, changed: false)
        }
        guard removed.count <= currentIDs.count,
              added.allSatisfy({ recordsByID[$0] != nil }) else { return nil }
        var unmatchedRemovals = removed
        var remaining: [UUID] = []
        remaining.reserveCapacity(currentIDs.count - removed.count)
        for id in currentIDs {
            if removed.contains(id) {
                unmatchedRemovals.remove(id)
            } else {
                guard !added.contains(id), recordsByID[id] != nil else { return nil }
                remaining.append(id)
            }
        }
        guard unmatchedRemovals.isEmpty else { return nil }
        let precedes = { (lhs: UUID, rhs: UUID) in
            LibraryQuery.displayOrdered(
                self.recordsByID[lhs]!,
                before: self.recordsByID[rhs]!,
                query: query,
                sourceOrdinals: (
                    self.sourceIndexByID[lhs] ?? .max,
                    self.sourceIndexByID[rhs] ?? .max
                )
            )
        }
        return LibraryIncrementalDisplayUpdate(
            ids: mergingLibraryIDs(remaining, added.sorted(by: precedes), by: precedes),
            changed: true
        )
    }

    private func refreshRelativeFacets(now: Date) {
        guard didBootstrap else { return }
        defer { lastRelativeFacetCheck = now }
        // Ordinary catalog/device changes cannot affect relative dates until
        // a book crosses the cutoff. Also support a clock moving backwards.
        guard nextRecentExpiration.map({ now >= $0 }) == true
            || lastRelativeFacetCheck.map({ now < $0 }) == true else { return }
        var refreshed = facets
        let changed = refreshed.refreshRecentCount(
            records: orderedRecords,
            now: now
        )
        scheduleRecentExpirations(now: now)
        guard changed else { return }
        facets = refreshed
        relativeFilterRevision &+= 1
    }

    private func scheduleRecentExpiration(dateAdded: Date, now: Date) {
        let expiration = dateAdded.addingTimeInterval(LibraryRelativeDateFilter.recentlyAddedInterval)
        guard expiration > now else { return }
        nextRecentExpiration = min(nextRecentExpiration ?? expiration, expiration)
    }

    private func scheduleRecentExpirations(now: Date) {
        nextRecentExpiration = nil
        lastRelativeFacetCheck = now
        for record in orderedRecords {
            scheduleRecentExpiration(dateAdded: record.dateAdded, now: now)
        }
    }

    private func rebuild(
        books: [Book],
        smartCollections: [LibrarySmartCollectionSnapshot],
        catalogGeneration: Int,
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool,
        deviceGeneration: Int?,
        requestEpoch: Int
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
        let captureClock = ContinuousClock()
        var nextYield = captureClock.now.advanced(by: .milliseconds(4))
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
            if captureClock.now >= nextYield {
                await Task.yield()
                nextYield = captureClock.now.advanced(by: .milliseconds(4))
                guard !Task.isCancelled,
                      requestIsCurrent(
                        requestEpoch,
                        generation: catalogGeneration
                      ) else {
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
        let facetEvaluationDate = now()
        let nextFacets = await metadataEngine.makeFacets(
            smartCollections: smartCollections,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected,
            evaluatedAt: facetEvaluationDate
        )
        LibraryPerformanceDiagnostics.endSQLScope("sidebar_facets")
        Log.librarySignposter.endInterval("SidebarFacets", facetInterval)

        guard requestIsCurrent(
            requestEpoch,
            generation: catalogGeneration
        ) else { return }
        orderedRecords = records
        recordsByID = nextRecordsByID
        booksByID = nextBooksByID
        booksByPersistentID = nextBooksByPersistentID
        sourceIndexByID = nextSourceIndexByID
        sourceIndexByPersistentID = nextSourceIndexByPersistentID
        self.smartCollections = smartCollections
        self.deviceFileNames = deviceFileNames
        self.deviceIsConnected = deviceIsConnected
        if let deviceGeneration {
            self.deviceGeneration = deviceGeneration
        }
        bookCount = books.count
        facets = nextFacets
        scheduleRecentExpirations(now: facetEvaluationDate)
        didBootstrap = true
        isReady = true
        diagnostics.fullRebuildCount += 1
        diagnostics.lastCapturedRecordCount = books.count
        diagnostics.lastSmartShelfEvaluationCount =
            books.count * smartCollections.count
        publish(
            fromGeneration: generation,
            toGeneration: catalogGeneration,
            changes: [],
            requiresFullDisplayRebuild: true
        )
    }

    private func requestIsCurrent(
        _ epoch: Int,
        generation requestedGeneration: Int
    ) -> Bool {
        !Task.isCancelled
            && epoch == synchronizationEpoch
            && requestedGeneration >= generation
            && requestedGeneration >= highestRequestedGeneration
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
                compiledDefinition: definition?.compiled
            )
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
