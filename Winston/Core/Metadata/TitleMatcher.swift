import Foundation

nonisolated enum TitleMatcher {

    static func matches(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        let na = normalize(a), nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na.contains(nb) || nb.contains(na) { return true }
        let ta = Set(na.split(separator: " ")), tb = Set(nb.split(separator: " "))
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let overlap = Double(ta.intersection(tb).count) / Double(min(ta.count, tb.count))
        return overlap >= 0.6
    }

    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        let alphanumeric = folded.map { character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(alphanumeric)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
