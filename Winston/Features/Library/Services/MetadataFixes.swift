import Foundation

nonisolated struct MetadataFix: Sendable, Identifiable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case author
        case series
        case seriesAssignment
    }

    let kind: Kind
    let original: String
    let suggestion: String
    let bookCount: Int
    let bookID: UUID?
    let seriesIndex: String?

    init(
        kind: Kind,
        original: String,
        suggestion: String,
        bookCount: Int,
        bookID: UUID? = nil,
        seriesIndex: String? = nil
    ) {
        self.kind = kind
        self.original = original
        self.suggestion = suggestion
        self.bookCount = bookCount
        self.bookID = bookID
        self.seriesIndex = seriesIndex
    }

    var id: String {
        if kind == .seriesAssignment, let bookID {
            return "\(kind.rawValue):\(bookID.uuidString)"
        }
        return "\(kind.rawValue):\(original)"
    }
}

nonisolated struct MetadataFixRow: Sendable {
    let bookID: UUID?
    let title: String?
    let originalFileName: String?
    let author: String?
    let series: String?
    let seriesIndex: String?

    init(
        bookID: UUID? = nil,
        title: String? = nil,
        originalFileName: String? = nil,
        author: String?,
        series: String?,
        seriesIndex: String? = nil
    ) {
        self.bookID = bookID
        self.title = title
        self.originalFileName = originalFileName
        self.author = author
        self.series = series
        self.seriesIndex = seriesIndex
    }
}

nonisolated struct MetadataFixAnalysis: Sendable, Equatable {
    let fixes: [MetadataFix]
    let seriesSuggestions: [String]
}

nonisolated enum MetadataFixFinder {
    static func reversedAuthorSuggestion(_ name: String) -> String? {
        let parts = name.components(separatedBy: ",")
        guard parts.count == 2 else { return nil }
        let last = parts[0].trimmingCharacters(in: .whitespaces)
        let first = parts[1].trimmingCharacters(in: .whitespaces)
        guard !last.isEmpty, !first.isEmpty, !last.contains(" ") else { return nil }
        return "\(first) \(last)"
    }

    static func fixes(rows: [MetadataFixRow]) -> [MetadataFix] {
        analysis(rows: rows).fixes
    }

    static func analysis(rows: [MetadataFixRow]) -> MetadataFixAnalysis {
        var authorCounts: [String: Int] = [:]
        var seriesCounts: [String: Int] = [:]

        for row in rows {
            if let author = nonempty(row.author) {
                authorCounts[author, default: 0] += 1
            }
            if let series = row.series,
               !series.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                seriesCounts[series, default: 0] += 1
            }
        }

        let authorFixes = authorCounts.keys
            .compactMap { original -> MetadataFix? in
                guard let suggestion = reversedAuthorSuggestion(original) else { return nil }
                return MetadataFix(
                    kind: .author,
                    original: original,
                    suggestion: suggestion,
                    bookCount: authorCounts[original, default: 0]
                )
            }
            .sorted(by: compareOriginals)

        let seriesFixes = SeriesSuggestions.unificationTips(counts: seriesCounts)
            .map { tip in
                MetadataFix(
                    kind: .series,
                    original: tip.original,
                    suggestion: tip.suggestion,
                    bookCount: seriesCounts[tip.original, default: 0]
                )
            }

        let canonicalSeries = SeriesSuggestions.canonicalNamesByMatchKey(counts: seriesCounts)
        let assignmentCandidates = rows.compactMap {
            assignmentCandidate(for: $0, canonicalSeries: canonicalSeries)
        }
        var candidateNameCounts: [String: Int] = [:]
        var candidateFamilyCounts: [String: Int] = [:]
        for candidate in assignmentCandidates {
            candidateNameCounts[candidate.parsed.name, default: 0] += 1
            candidateFamilyCounts[
                SeriesSuggestions.familyMatchKey(candidate.parsed.name),
                default: 0
            ] += 1
        }
        let inferredSeries = SeriesSuggestions.canonicalNamesByMatchKey(counts: candidateNameCounts)
        let assignmentFixes = assignmentCandidates
            .compactMap {
                assignmentFix(
                    from: $0,
                    canonicalSeries: canonicalSeries,
                    inferredSeries: inferredSeries,
                    candidateFamilyCounts: candidateFamilyCounts
                )
            }
            .sorted(by: compareOriginals)

        return MetadataFixAnalysis(
            fixes: authorFixes + seriesFixes + assignmentFixes,
            seriesSuggestions: SeriesSuggestions.ranked(counts: seriesCounts)
        )
    }

    private struct ParsedSeriesAssignment {
        let name: String
        let index: String?
        let requiresExistingSeries: Bool
    }

    private struct SeriesAssignmentCandidate {
        let bookID: UUID
        let title: String
        let existingIndex: String?
        let parsed: ParsedSeriesAssignment
    }

    private static func assignmentCandidate(
        for row: MetadataFixRow,
        canonicalSeries: [String: String]
    ) -> SeriesAssignmentCandidate? {
        guard nonempty(row.series) == nil,
              let bookID = row.bookID,
              let title = nonempty(row.title) else { return nil }

        var sources = [title]
        if let originalFileName = nonempty(row.originalFileName) {
            let withoutExtension = (originalFileName as NSString).deletingPathExtension
            if withoutExtension != title { sources.append(withoutExtension) }
        }

        for source in sources {
            guard let parsed = parsedAssignment(in: source, canonicalSeries: canonicalSeries) else {
                continue
            }
            return SeriesAssignmentCandidate(
                bookID: bookID,
                title: title,
                existingIndex: nonempty(row.seriesIndex),
                parsed: parsed
            )
        }
        return nil
    }

    private static func assignmentFix(
        from candidate: SeriesAssignmentCandidate,
        canonicalSeries: [String: String],
        inferredSeries: [String: String],
        candidateFamilyCounts: [String: Int]
    ) -> MetadataFix? {
        let parsed = candidate.parsed
        let key = SeriesSuggestions.familyMatchKey(parsed.name)
        let suggestion: String
        if let canonical = canonicalSeries[key] {
            suggestion = canonical
        } else if parsed.name.normalizedMatchKey.count >= 3,
                  !parsed.requiresExistingSeries || candidateFamilyCounts[key, default: 0] >= 2 {
            suggestion = inferredSeries[key] ?? parsed.name
        } else {
            return nil
        }

        return MetadataFix(
            kind: .seriesAssignment,
            original: candidate.title,
            suggestion: suggestion,
            bookCount: 1,
            bookID: candidate.bookID,
            seriesIndex: candidate.existingIndex ?? parsed.index
        )
    }

    private static func parsedAssignment(
        in text: String,
        canonicalSeries: [String: String]
    ) -> ParsedSeriesAssignment? {
        for content in parentheticalContents(in: text).reversed() {
            if let explicit = explicitBookMarker(in: content) {
                return explicit
            }
            let name = trimmedSeriesName(content)
            if canonicalSeries[SeriesSuggestions.familyMatchKey(name)] != nil {
                return ParsedSeriesAssignment(name: name, index: nil, requiresExistingSeries: true)
            }
        }

        return numberedPrefix(in: text)
    }

    private static func parentheticalContents(in text: String) -> [String] {
        var result: [String] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let open = text[searchStart...].firstIndex(of: "("),
              let close = text[text.index(after: open)...].firstIndex(of: ")") {
            let contentStart = text.index(after: open)
            result.append(String(text[contentStart..<close]))
            searchStart = text.index(after: close)
        }
        return result
    }

    private static func explicitBookMarker(in content: String) -> ParsedSeriesAssignment? {
        let tokens = content.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 3,
              let index = normalizedSeriesIndex(tokens.last) else { return nil }

        var markerIndex = tokens.count - 2
        let optionalNumberMarker = tokenKey(tokens[markerIndex])
        if optionalNumberMarker == "no" || optionalNumberMarker == "number" {
            guard markerIndex > 0 else { return nil }
            markerIndex -= 1
        }

        switch tokenKey(tokens[markerIndex]) {
        case "book", "volume", "vol":
            break
        default:
            return nil
        }

        let name = trimmedSeriesName(tokens[..<markerIndex].joined(separator: " "))
        guard !name.isEmpty else { return nil }
        return ParsedSeriesAssignment(name: name, index: index, requiresExistingSeries: false)
    }

    private static func numberedPrefix(in text: String) -> ParsedSeriesAssignment? {
        let delimiters = [" - ", " – ", " — ", ": ", "_ "]
        let delimiter = delimiters
            .compactMap { text.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        guard let delimiter else { return nil }

        let prefix = text[..<delimiter.lowerBound]
        var tokens = prefix.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 2,
              let index = normalizedSeriesIndex(tokens.removeLast()) else { return nil }

        var requiresExistingSeries = true
        if let marker = tokens.last {
            switch tokenKey(marker) {
            case "book", "volume", "vol":
                tokens.removeLast()
                requiresExistingSeries = false
            default:
                break
            }
        }

        let name = trimmedSeriesName(tokens.joined(separator: " "))
        guard !name.isEmpty else { return nil }
        return ParsedSeriesAssignment(
            name: name,
            index: index,
            requiresExistingSeries: requiresExistingSeries
        )
    }

    private static func normalizedSeriesIndex(_ token: String?) -> String? {
        guard let token else { return nil }
        let cleaned = token.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "#.,;:()[]"))
        )
        guard let value = Double(cleaned), value > 0, value.isFinite else { return nil }
        if value == value.rounded() { return String(Int(value)) }
        return String(value)
    }

    private static func tokenKey(_ token: String) -> String {
        token
            .trimmingCharacters(in: CharacterSet(charactersIn: "#.,;:()[]"))
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
    }

    private static func trimmedSeriesName<S: StringProtocol>(_ value: S) -> String {
        String(value).trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—,;:"))
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func compareOriginals(_ lhs: MetadataFix, _ rhs: MetadataFix) -> Bool {
        let order = lhs.original.localizedCaseInsensitiveCompare(rhs.original)
        if order != .orderedSame { return order == .orderedAscending }
        if lhs.original != rhs.original { return lhs.original < rhs.original }
        return lhs.id < rhs.id
    }
}
