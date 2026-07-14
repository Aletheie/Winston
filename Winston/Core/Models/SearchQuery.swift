import Foundation

nonisolated struct SearchQuery: Equatable, Sendable {
    enum Field: String { case author, tag, series, title, format, year, language, translator }

    struct YearConstraint: Equatable, Sendable {
        enum Op: Equatable, Sendable { case greaterThan, lessThan, equal }
        var op: Op
        var value: Int
    }

    var freeText: String = ""
    var authors: [String] = []
    var tags: [String] = []
    var series: [String] = []
    var titles: [String] = []
    var formats: [String] = []
    var languages: [String] = []
    var translators: [String] = []
    var year: YearConstraint?

    var isEmpty: Bool {
        freeText.isEmpty && authors.isEmpty && tags.isEmpty && series.isEmpty
            && titles.isEmpty && formats.isEmpty && languages.isEmpty && translators.isEmpty && year == nil
    }

    static func parse(_ raw: String) -> SearchQuery {
        var query = SearchQuery()
        var freeWords: [String] = []

        for token in tokenize(raw) {
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex,
                  let field = Field(rawValue: token[..<colon].lowercased()) else {
                freeWords.append(token)
                continue
            }
            let value = String(token[token.index(after: colon)...])
            guard !value.isEmpty else { freeWords.append(token); continue }
            switch field {
            case .author: query.authors.append(value)
            case .tag:    query.tags.append(value)
            case .series: query.series.append(value)
            case .title:  query.titles.append(value)
            case .format: query.formats.append(value.lowercased())
            case .language: query.languages.append(value.lowercased())
            case .translator: query.translators.append(value)
            case .year:   if let constraint = parseYear(value) { query.year = constraint }
            }
        }

        query.freeText = freeWords.joined(separator: " ")
        return query
    }

    private static func tokenize(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in raw {
            switch character {
            case "\"":
                inQuotes.toggle()
            case " " where !inQuotes:
                if !current.isEmpty { tokens.append(current); current = "" }
            default:
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func parseYear(_ value: String) -> YearConstraint? {
        var op = YearConstraint.Op.equal
        var number = value
        switch value.first {
        case ">": op = .greaterThan; number = String(value.dropFirst())
        case "<": op = .lessThan;    number = String(value.dropFirst())
        case "=": op = .equal;       number = String(value.dropFirst())
        default:  break
        }
        guard let year = Int(number) else { return nil }
        return YearConstraint(op: op, value: year)
    }
}
