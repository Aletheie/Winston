import Foundation

nonisolated enum EditionVerdict: String, Codable, CaseIterable, Sendable {
    case duplicateFile
    case sameEditionOtherFormat
    case sameWorkOtherEdition
    case similarItem
}

nonisolated enum MatchConfidence: String, Codable, CaseIterable, Sendable {
    case high
    case likely
    case uncertain

    var label: LocalizedStringResource {
        switch self {
        case .high: "Exact"
        case .likely: "Likely"
        case .uncertain: "Uncertain"
        }
    }

    var terminalLabel: String {
        switch self {
        case .high: "MATCH"
        case .likely: "LIKELY"
        case .uncertain: "UNSURE"
        }
    }
}

nonisolated enum MatchSignal: String, Codable, CaseIterable, Hashable, Sendable {
    case identicalContent
    case sameISBN
    case sameOpenLibraryWork
    case sameTitleAndAuthor
    case differentLanguage
    case differentTranslator
    case differentISBN
    case differentPublisher
    case differentPublicationYear
    case sameTitle
    case broadCandidateBucket

    var label: LocalizedStringResource {
        switch self {
        case .identicalContent: "Identical file content"
        case .sameISBN: "Same ISBN"
        case .sameOpenLibraryWork: "Same Open Library work"
        case .sameTitleAndAuthor: "Same title and author"
        case .differentLanguage: "Different language"
        case .differentTranslator: "Different translator"
        case .differentISBN: "Different ISBN"
        case .differentPublisher: "Different publisher"
        case .differentPublicationYear: "Different publication year"
        case .sameTitle: "Same title"
        case .broadCandidateBucket: "Too many similar catalog candidates"
        }
    }

    var terminalLabel: String {
        switch self {
        case .identicalContent: "IDENTICAL_CONTENT"
        case .sameISBN: "SAME_ISBN"
        case .sameOpenLibraryWork: "SAME_OL_WORK"
        case .sameTitleAndAuthor: "SAME_TITLE_AUTHOR"
        case .differentLanguage: "DIFFERENT_LANGUAGE"
        case .differentTranslator: "DIFFERENT_TRANSLATOR"
        case .differentISBN: "DIFFERENT_ISBN"
        case .differentPublisher: "DIFFERENT_PUBLISHER"
        case .differentPublicationYear: "DIFFERENT_YEAR"
        case .sameTitle: "SAME_TITLE"
        case .broadCandidateBucket: "BROAD_CANDIDATE_BUCKET"
        }
    }
}

nonisolated enum ReconciliationAssetPolicy: String, Codable, Sendable {
    case removeExactContentDuplicates
    case retainAll
    case unchanged
    case reviewOnly
}

/// Immutable description of the catalog and file effects that an approved
/// reconciliation proposal is allowed to perform.
nonisolated struct ReconciliationChangePlan: Hashable, Sendable {
    let mergesEditionRecords: Bool
    let groupsEditionsUnderWork: Bool
    let assetPolicy: ReconciliationAssetPolicy
    let preservesMetadata: Bool
    let preservesReadingHistory: Bool
    let preservesHighlights: Bool
    let preservesCollections: Bool
}

nonisolated struct EditionCandidate: Hashable, Sendable {
    let uuid: UUID
    let workUUID: UUID?
    let title: String
    let author: String
    let language: String
    let translator: String
    let isbn: String
    let publisher: String
    let year: String
    let format: String
    let sizeBytes: Int64
    let contentHashes: Set<String>
    let openLibraryWorkKey: String
    let workMatchKey: String

    init(
        uuid: UUID,
        workUUID: UUID?,
        title: String?,
        author: String?,
        language: String?,
        translator: String?,
        isbn: String?,
        publisher: String?,
        year: String?,
        format: String,
        sizeBytes: Int64,
        contentHashes: Set<String> = [],
        openLibraryWorkKey: String? = nil,
        workMatchKey: String? = nil
    ) {
        self.uuid = uuid
        self.workUUID = workUUID
        self.title = (title ?? "").normalizedMatchKey
        self.author = (author ?? "").normalizedMatchKey
        self.language = (language ?? "").normalizedMatchKey
        self.translator = (translator ?? "").normalizedMatchKey
        self.isbn = EditionMatcher.normalizedISBN(isbn)
        self.publisher = (publisher ?? "").normalizedMatchKey
        self.year = (year ?? "").normalizedMatchKey
        self.format = format.lowercased()
        self.sizeBytes = sizeBytes
        self.contentHashes = Set(contentHashes.map { $0.lowercased() }.filter { !$0.isEmpty })
        self.openLibraryWorkKey = (openLibraryWorkKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.workMatchKey = (workMatchKey ?? "").normalizedMatchKey
    }

    var matchKey: String? {
        guard !title.isEmpty, !author.isEmpty else { return nil }
        return "\(title)|\(author)"
    }
}

nonisolated struct EditionMatchProposal: Identifiable, Hashable, Sendable {
    let memberUUIDs: [UUID]
    let verdict: EditionVerdict
    let confidence: MatchConfidence
    let signals: [MatchSignal]
    let pairKey: String

    var id: String { pairKey }

    var isExactContentDuplicate: Bool {
        verdict == .duplicateFile
            && confidence == .high
            && signals.contains(.identicalContent)
    }

    /// Exact bytes are the only evidence strong enough to authorize physical
    /// cleanup. Other proposals always retain every asset.
    var isAutomaticallySafe: Bool { isExactContentDuplicate }

    var canApply: Bool { verdict != .similarItem }

    var needsManualReview: Bool {
        signals.contains(.broadCandidateBucket)
    }

    var changePlan: ReconciliationChangePlan {
        switch verdict {
        case .duplicateFile:
            ReconciliationChangePlan(
                mergesEditionRecords: true,
                groupsEditionsUnderWork: false,
                assetPolicy: isExactContentDuplicate ? .removeExactContentDuplicates : .reviewOnly,
                preservesMetadata: true,
                preservesReadingHistory: true,
                preservesHighlights: true,
                preservesCollections: true
            )
        case .sameEditionOtherFormat:
            ReconciliationChangePlan(
                mergesEditionRecords: true,
                groupsEditionsUnderWork: false,
                assetPolicy: .retainAll,
                preservesMetadata: true,
                preservesReadingHistory: true,
                preservesHighlights: true,
                preservesCollections: true
            )
        case .sameWorkOtherEdition:
            ReconciliationChangePlan(
                mergesEditionRecords: false,
                groupsEditionsUnderWork: true,
                assetPolicy: .unchanged,
                preservesMetadata: true,
                preservesReadingHistory: true,
                preservesHighlights: true,
                preservesCollections: true
            )
        case .similarItem:
            ReconciliationChangePlan(
                mergesEditionRecords: false,
                groupsEditionsUnderWork: false,
                assetPolicy: .reviewOnly,
                preservesMetadata: true,
                preservesReadingHistory: true,
                preservesHighlights: true,
                preservesCollections: true
            )
        }
    }
}

nonisolated struct EditionCountPatch: Sendable, Equatable {
    let removedBookIDs: Set<UUID>
    let countsByBookID: [UUID: Int]
}

nonisolated struct EditionCandidateLookup: Sendable, Equatable {
    let matches: [EditionCandidate]
    let manualReviewProposals: [EditionMatchProposal]
    let bucketCandidateCount: Int
    let truncatedBucketCount: Int
}

nonisolated struct EditionMatcherMetrics: Sendable, Equatable {
    var candidateCount = 0
    var bucketCount = 0
    var pairComparisonCount = 0
    var truncatedBucketCount = 0
    var maximumBucketSize = 0
}

nonisolated struct EditionMatcherScanResult: Sendable, Equatable {
    let proposals: [EditionMatchProposal]
    let metrics: EditionMatcherMetrics
}

/// Rebuildable read index. Updates remove the previous candidate from every
/// bucket before inserting its new generation, so identity edits never leave
/// stale candidate keys behind.
nonisolated struct EditionCandidateIndex: Sendable {
    private var candidates: [UUID: EditionCandidate] = [:]
    private var buckets: [String: Set<UUID>] = [:]
    private var keysByCandidate: [UUID: Set<String>] = [:]
    private var membersByWork: [UUID: Set<UUID>] = [:]

    init(_ candidates: [EditionCandidate] = []) {
        for candidate in candidates {
            insert(candidate)
        }
    }

    var count: Int { candidates.count }
    var allCandidates: [EditionCandidate] {
        candidates.values.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
    }

    func candidate(id: UUID) -> EditionCandidate? {
        candidates[id]
    }

    func editionCounts() -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for members in membersByWork.values where members.count > 1 {
            for id in members { result[id] = members.count }
        }
        return result
    }

    @discardableResult
    mutating func update(_ candidate: EditionCandidate) -> EditionCountPatch {
        update([candidate])
    }

    @discardableResult
    mutating func update(_ values: [EditionCandidate]) -> EditionCountPatch {
        let workIDs = Set(values.flatMap {
            [candidates[$0.uuid]?.workUUID, $0.workUUID].compactMap { $0 }
        })
        let oldMembers = members(in: workIDs)
        for candidate in values { removeCandidate(id: candidate.uuid) }
        for candidate in values { insert(candidate) }
        return countPatch(workIDs: workIDs, oldMembers: oldMembers)
    }

    @discardableResult
    mutating func remove(id: UUID) -> EditionCountPatch {
        remove(ids: [id])
    }

    @discardableResult
    mutating func remove(ids: Set<UUID>) -> EditionCountPatch {
        let workIDs = Set(ids.compactMap { candidates[$0]?.workUUID })
        let oldMembers = members(in: workIDs)
        for id in ids { removeCandidate(id: id) }
        return countPatch(workIDs: workIDs, oldMembers: oldMembers)
    }

    func lookup(for candidate: EditionCandidate) -> EditionCandidateLookup {
        var seen: Set<UUID> = [candidate.uuid]
        var matches: [EditionCandidate] = []
        var manualReviewProposals: [EditionMatchProposal] = []
        var bucketCandidateCount = 0
        var truncatedBucketCount = 0

        for key in EditionMatcher.bucketKeys(for: candidate).sorted() {
            let bucket = buckets[key] ?? []
            let memberCount = bucket.count - (bucket.contains(candidate.uuid) ? 1 : 0)
            bucketCandidateCount += memberCount
            let limit = EditionMatcher.isStrongBucket(key)
                ? EditionMatcher.maximumStrongBucketComparisons
                : EditionMatcher.maximumFuzzyBucketSize
            let memberIDs = Array(
                bucket.lazy
                    .filter { $0 != candidate.uuid }
                    .prefix(limit)
            ).sorted { $0.uuidString < $1.uuidString }
            if memberCount > limit {
                truncatedBucketCount += 1
                let requiresReview = key.hasPrefix("h:")
                    || key.hasPrefix("i:")
                    || candidate.workUUID == nil
                    || bucket.contains { id in
                        guard id != candidate.uuid else { return false }
                        return candidates[id]?.workUUID != candidate.workUUID
                    }
                let bucketCandidates = ([candidate.uuid] + memberIDs).compactMap {
                    $0 == candidate.uuid ? candidate : candidates[$0]
                }
                if let proposal = EditionMatcher.manualReviewProposal(
                    bucketKey: key,
                    candidates: bucketCandidates,
                    requiresReview: requiresReview
                ) {
                    manualReviewProposals.append(proposal)
                }
                guard EditionMatcher.isStrongBucket(key) else { continue }
            }
            for id in memberIDs.prefix(limit) {
                guard seen.insert(id).inserted, let match = candidates[id] else { continue }
                matches.append(match)
            }
        }
        return EditionCandidateLookup(
            matches: matches,
            manualReviewProposals: manualReviewProposals,
            bucketCandidateCount: bucketCandidateCount,
            truncatedBucketCount: truncatedBucketCount
        )
    }

    private mutating func insert(_ candidate: EditionCandidate) {
        candidates[candidate.uuid] = candidate
        let keys = Set(EditionMatcher.bucketKeys(for: candidate))
        keysByCandidate[candidate.uuid] = keys
        for key in keys { buckets[key, default: []].insert(candidate.uuid) }
        if let workID = candidate.workUUID {
            membersByWork[workID, default: []].insert(candidate.uuid)
        }
    }

    private mutating func removeCandidate(id: UUID) {
        guard let candidate = candidates.removeValue(forKey: id) else { return }
        for key in keysByCandidate.removeValue(forKey: id) ?? [] {
            buckets[key]?.remove(id)
            if buckets[key]?.isEmpty == true { buckets.removeValue(forKey: key) }
        }
        if let workID = candidate.workUUID {
            membersByWork[workID]?.remove(id)
            if membersByWork[workID]?.isEmpty == true {
                membersByWork.removeValue(forKey: workID)
            }
        }
    }

    private func members(in workIDs: Set<UUID>) -> Set<UUID> {
        workIDs.reduce(into: Set<UUID>()) { result, workID in
            result.formUnion(membersByWork[workID] ?? [])
        }
    }

    private func countPatch(
        workIDs: Set<UUID>,
        oldMembers: Set<UUID>
    ) -> EditionCountPatch {
        let newMembers = members(in: workIDs)
        var counts: [UUID: Int] = [:]
        for workID in workIDs {
            let members = membersByWork[workID] ?? []
            guard members.count > 1 else { continue }
            for id in members { counts[id] = members.count }
        }
        return EditionCountPatch(
            removedBookIDs: oldMembers.union(newMembers),
            countsByBookID: counts
        )
    }
}

nonisolated enum EditionMatcher {
    typealias CandidateIndex = EditionCandidateIndex

    static let maximumFuzzyBucketSize = 64
    static let maximumStrongBucketComparisons = 512
    static let maximumScanPairComparisons = 25_000
    static let maximumManualReviewMembers = 64

    static func normalizedISBN(_ value: String?) -> String {
        (value ?? "")
            .uppercased()
            .filter { $0.isNumber || $0 == "X" }
    }

    static func proposals(
        for candidate: EditionCandidate,
        against others: [EditionCandidate]
    ) -> [EditionMatchProposal] {
        others.compactMap { proposal(between: candidate, and: $0) }
            .sorted(by: proposalPrecedes)
    }

    @concurrent
    static func scan(_ candidates: [EditionCandidate]) async -> [EditionMatchProposal] {
        await scanWithMetrics(candidates).proposals
    }

    @concurrent
    static func scanWithMetrics(
        _ candidates: [EditionCandidate]
    ) async -> EditionMatcherScanResult {
        var buckets: [String: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() {
            for key in bucketKeys(for: candidate) {
                buckets[key, default: []].append(index)
            }
        }

        var seen: Set<String> = []
        var proposals: [EditionMatchProposal] = []
        var metrics = EditionMatcherMetrics(
            candidateCount: candidates.count,
            bucketCount: buckets.count
        )
        for key in buckets.keys.sorted() {
            guard let indices = buckets[key], indices.count > 1 else { continue }
            metrics.maximumBucketSize = max(metrics.maximumBucketSize, indices.count)
            let isStrong = isStrongBucket(key)
            if (!isStrong && indices.count > maximumFuzzyBucketSize)
                || metrics.pairComparisonCount >= maximumScanPairComparisons {
                metrics.truncatedBucketCount += 1
                if let proposal = manualReviewProposal(
                    bucketKey: key,
                    candidates: indices.map { candidates[$0] }
                ) {
                    proposals.append(proposal)
                }
                continue
            }

            if isStrong, indices.count > maximumFuzzyBucketSize {
                metrics.truncatedBucketCount += 1
                if let proposal = manualReviewProposal(
                    bucketKey: key,
                    candidates: indices.map { candidates[$0] }
                ) {
                    proposals.append(proposal)
                }
                let lhs = candidates[indices[0]]
                for index in indices.dropFirst().prefix(maximumStrongBucketComparisons) {
                    let rhs = candidates[index]
                    let pair = pairKey(lhs.uuid, rhs.uuid)
                    guard seen.insert(pair).inserted else { continue }
                    guard metrics.pairComparisonCount < maximumScanPairComparisons else { break }
                    metrics.pairComparisonCount += 1
                    guard let proposal = proposal(between: lhs, and: rhs) else { continue }
                    proposals.append(proposal)
                }
                continue
            }

            comparisonLoop: for leftOffset in indices.indices {
                for rightOffset in indices.index(after: leftOffset)..<indices.endIndex {
                    let lhs = candidates[indices[leftOffset]]
                    let rhs = candidates[indices[rightOffset]]
                    let pair = pairKey(lhs.uuid, rhs.uuid)
                    guard seen.insert(pair).inserted else { continue }
                    guard metrics.pairComparisonCount < maximumScanPairComparisons else {
                        metrics.truncatedBucketCount += 1
                        if let proposal = manualReviewProposal(
                            bucketKey: key,
                            candidates: indices.map { candidates[$0] }
                        ) {
                            proposals.append(proposal)
                        }
                        break comparisonLoop
                    }
                    metrics.pairComparisonCount += 1
                    guard
                          let proposal = proposal(between: lhs, and: rhs)
                    else { continue }
                    proposals.append(proposal)
                }
            }
        }
        let unique = Dictionary(
            proposals.map { ($0.pairKey, $0) },
            uniquingKeysWith: { first, second in
                proposalPrecedes(first, second) ? first : second
            }
        )
        return EditionMatcherScanResult(
            proposals: unique.values.sorted(by: proposalPrecedes),
            metrics: metrics
        )
    }

    static func pairKey(_ lhs: UUID, _ rhs: UUID) -> String {
        [lhs.uuidString.lowercased(), rhs.uuidString.lowercased()].sorted().joined(separator: ":")
    }

    static func bucketKeys(for candidate: EditionCandidate) -> [String] {
        var keys = candidate.contentHashes.map { "h:\($0)" }
        if !candidate.isbn.isEmpty { keys.append("i:\(candidate.isbn)") }
        if !candidate.openLibraryWorkKey.isEmpty { keys.append("o:\(candidate.openLibraryWorkKey)") }
        if !candidate.workMatchKey.isEmpty { keys.append("w:\(candidate.workMatchKey)") }
        if let matchKey = candidate.matchKey { keys.append("k:\(matchKey)") }
        if !candidate.title.isEmpty { keys.append("t:\(candidate.title)") }
        return keys
    }

    static func isStrongBucket(_ key: String) -> Bool {
        key.hasPrefix("h:") || key.hasPrefix("i:") || key.hasPrefix("o:")
    }

    static func manualReviewProposal(
        bucketKey: String,
        candidates: [EditionCandidate],
        requiresReview: Bool? = nil
    ) -> EditionMatchProposal? {
        guard let first = candidates.first,
              requiresReview
                ?? (
                    bucketKey.hasPrefix("h:")
                        || bucketKey.hasPrefix("i:")
                        || first.workUUID == nil
                        || candidates.contains(where: { $0.workUUID != first.workUUID })
                )
        else { return nil }
        let members = candidates
            .prefix(maximumManualReviewMembers)
            .map(\.uuid)
            .sorted { $0.uuidString < $1.uuidString }
        return EditionMatchProposal(
            memberUUIDs: members,
            verdict: .similarItem,
            confidence: .uncertain,
            signals: [.broadCandidateBucket],
            pairKey: manualReviewPairKey(bucketKey: bucketKey)
        )
    }

    static func manualReviewPairKey(bucketKey: String) -> String {
        "manual:\(stableBucketToken(bucketKey))"
    }

    private static func stableBucketToken(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func proposal(
        between lhs: EditionCandidate,
        and rhs: EditionCandidate
    ) -> EditionMatchProposal? {
        let pair = pairKey(lhs.uuid, rhs.uuid)
        let members = [lhs.uuid, rhs.uuid].sorted { $0.uuidString < $1.uuidString }

        if !lhs.contentHashes.isDisjoint(with: rhs.contentHashes) {
            return EditionMatchProposal(
                memberUUIDs: members,
                verdict: .duplicateFile,
                confidence: .high,
                signals: [.identicalContent],
                pairKey: pair
            )
        }
        if !lhs.isbn.isEmpty, lhs.isbn == rhs.isbn {
            return EditionMatchProposal(
                memberUUIDs: members,
                verdict: .sameEditionOtherFormat,
                confidence: .high,
                signals: [.sameISBN],
                pairKey: pair
            )
        }
        let alreadyInOneWork = lhs.workUUID != nil && lhs.workUUID == rhs.workUUID
        if alreadyInOneWork { return nil }
        if !lhs.openLibraryWorkKey.isEmpty, lhs.openLibraryWorkKey == rhs.openLibraryWorkKey {
            return EditionMatchProposal(
                memberUUIDs: members,
                verdict: .sameWorkOtherEdition,
                confidence: .high,
                signals: [.sameOpenLibraryWork],
                pairKey: pair
            )
        }
        let sharesTitleAuthor = lhs.matchKey.map { $0 == rhs.matchKey } == true
            || (!lhs.workMatchKey.isEmpty && lhs.workMatchKey == rhs.workMatchKey)
        if sharesTitleAuthor {
            var signals: [MatchSignal] = [.sameTitleAndAuthor]
            let differentLanguage = valuesDiffer(lhs.language, rhs.language)
            let differentTranslator = valuesDiffer(lhs.translator, rhs.translator)
            let differentISBN = valuesDiffer(lhs.isbn, rhs.isbn)
            let differentPublisher = valuesDiffer(lhs.publisher, rhs.publisher)
            let differentPublicationYear = valuesDiffer(lhs.year, rhs.year)
            if differentLanguage { signals.append(.differentLanguage) }
            if differentTranslator { signals.append(.differentTranslator) }
            if differentISBN { signals.append(.differentISBN) }
            if differentPublisher { signals.append(.differentPublisher) }
            if differentPublicationYear { signals.append(.differentPublicationYear) }
            let hasEditionDifference = differentLanguage
                || differentTranslator
                || differentISBN
                || differentPublisher
                || differentPublicationYear
            return EditionMatchProposal(
                memberUUIDs: members,
                verdict: hasEditionDifference ? .sameWorkOtherEdition : .similarItem,
                confidence: hasEditionDifference ? .likely : .uncertain,
                signals: signals,
                pairKey: pair
            )
        }
        if !lhs.title.isEmpty, lhs.title == rhs.title {
            return EditionMatchProposal(
                memberUUIDs: members,
                verdict: .similarItem,
                confidence: .uncertain,
                signals: [.sameTitle],
                pairKey: pair
            )
        }
        return nil
    }

    private static func valuesDiffer(_ lhs: String, _ rhs: String) -> Bool {
        !lhs.isEmpty && !rhs.isEmpty && lhs != rhs
    }

    static func proposalPrecedes(_ lhs: EditionMatchProposal, _ rhs: EditionMatchProposal) -> Bool {
        let left = (confidenceRank(lhs.confidence), verdictRank(lhs.verdict), lhs.pairKey)
        let right = (confidenceRank(rhs.confidence), verdictRank(rhs.verdict), rhs.pairKey)
        return left < right
    }

    private static func confidenceRank(_ confidence: MatchConfidence) -> Int {
        switch confidence {
        case .high: 0
        case .likely: 1
        case .uncertain: 2
        }
    }

    private static func verdictRank(_ verdict: EditionVerdict) -> Int {
        switch verdict {
        case .duplicateFile: 0
        case .sameEditionOtherFormat: 1
        case .sameWorkOtherEdition: 2
        case .similarItem: 3
        }
    }
}
