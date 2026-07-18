import Foundation

nonisolated enum EditionVerdict: String, Codable, CaseIterable, Sendable {
    case duplicateFile
    case sameEditionOtherFormat
    case sameWorkOtherEdition
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
    case sameTitle

    var label: LocalizedStringResource {
        switch self {
        case .identicalContent: "Identical file content"
        case .sameISBN: "Same ISBN"
        case .sameOpenLibraryWork: "Same Open Library work"
        case .sameTitleAndAuthor: "Same title and author"
        case .differentLanguage: "Different language"
        case .differentTranslator: "Different translator"
        case .sameTitle: "Same title"
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
        case .sameTitle: "SAME_TITLE"
        }
    }
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
        openLibraryWorkKey: String? = nil
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
}

nonisolated enum EditionMatcher {
    struct CandidateIndex: Sendable {
        private var candidates: [UUID: EditionCandidate]
        private var buckets: [String: [UUID]] = [:]

        init(_ candidates: [EditionCandidate]) {
            self.candidates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.uuid, $0) })
            for candidate in candidates {
                for key in EditionMatcher.bucketKeys(for: candidate) {
                    buckets[key, default: []].append(candidate.uuid)
                }
            }
        }

        func matches(for candidate: EditionCandidate) -> [EditionCandidate] {
            var seen: Set<UUID> = [candidate.uuid]
            return EditionMatcher.bucketKeys(for: candidate).flatMap { buckets[$0] ?? [] }
                .compactMap { uuid in
                    guard seen.insert(uuid).inserted else { return nil }
                    return candidates[uuid]
                }
        }

        mutating func update(_ candidate: EditionCandidate) {
            candidates[candidate.uuid] = candidate
        }
    }

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
        var buckets: [String: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() {
            for hash in candidate.contentHashes { buckets["h:\(hash)", default: []].append(index) }
            if !candidate.isbn.isEmpty { buckets["i:\(candidate.isbn)", default: []].append(index) }
            if !candidate.openLibraryWorkKey.isEmpty {
                buckets["o:\(candidate.openLibraryWorkKey)", default: []].append(index)
            }
            if let matchKey = candidate.matchKey { buckets["k:\(matchKey)", default: []].append(index) }
            if !candidate.title.isEmpty { buckets["t:\(candidate.title)", default: []].append(index) }
        }

        var seen: Set<String> = []
        var proposals: [EditionMatchProposal] = []
        for indices in buckets.values where indices.count > 1 {
            for leftOffset in indices.indices {
                for rightOffset in indices.index(after: leftOffset)..<indices.endIndex {
                    let lhs = candidates[indices[leftOffset]]
                    let rhs = candidates[indices[rightOffset]]
                    let key = pairKey(lhs.uuid, rhs.uuid)
                    guard seen.insert(key).inserted,
                          lhs.workUUID == nil || lhs.workUUID != rhs.workUUID,
                          let proposal = proposal(between: lhs, and: rhs)
                    else { continue }
                    proposals.append(proposal)
                }
            }
        }
        return proposals.sorted(by: proposalPrecedes)
    }

    static func pairKey(_ lhs: UUID, _ rhs: UUID) -> String {
        [lhs.uuidString.lowercased(), rhs.uuidString.lowercased()].sorted().joined(separator: ":")
    }

    private static func bucketKeys(for candidate: EditionCandidate) -> [String] {
        var keys = candidate.contentHashes.map { "h:\($0)" }
        if !candidate.isbn.isEmpty { keys.append("i:\(candidate.isbn)") }
        if !candidate.openLibraryWorkKey.isEmpty { keys.append("o:\(candidate.openLibraryWorkKey)") }
        if let matchKey = candidate.matchKey { keys.append("k:\(matchKey)") }
        if !candidate.title.isEmpty { keys.append("t:\(candidate.title)") }
        return keys
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
        if !lhs.openLibraryWorkKey.isEmpty, lhs.openLibraryWorkKey == rhs.openLibraryWorkKey {
            return EditionMatchProposal(
                memberUUIDs: members,
                verdict: .sameWorkOtherEdition,
                confidence: .high,
                signals: [.sameOpenLibraryWork],
                pairKey: pair
            )
        }
        if let key = lhs.matchKey, key == rhs.matchKey {
            var signals: [MatchSignal] = [.sameTitleAndAuthor]
            let differentLanguage = valuesDiffer(lhs.language, rhs.language)
            let differentTranslator = valuesDiffer(lhs.translator, rhs.translator)
            if differentLanguage { signals.append(.differentLanguage) }
            if differentTranslator { signals.append(.differentTranslator) }
            return EditionMatchProposal(
                memberUUIDs: members,
                verdict: .sameWorkOtherEdition,
                confidence: differentLanguage || differentTranslator ? .likely : .uncertain,
                signals: signals,
                pairKey: pair
            )
        }
        if !lhs.title.isEmpty, lhs.title == rhs.title, lhs.author.isEmpty || rhs.author.isEmpty {
            return EditionMatchProposal(
                memberUUIDs: members,
                verdict: .sameWorkOtherEdition,
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
        }
    }
}
