import Foundation

nonisolated enum KindleClippings {
    struct Clipping: Sendable, Equatable {
        var title: String
        var author: String?
        var isNote: Bool
        var isBookmark: Bool
        var location: String?
        var addedDate: Date?
        var text: String
    }

    static func parse(_ raw: String) -> [Clipping] {
        let blocks = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: "==========")
        return blocks.compactMap(parseBlock)
    }

    private static func parseBlock(_ block: String) -> Clipping? {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let titleLine = trimmed.first(where: { !$0.isEmpty }) else { return nil }
        guard let titleIndex = trimmed.firstIndex(of: titleLine) else { return nil }
        guard titleIndex + 1 < trimmed.count else { return nil }

        let metaLine = trimmed[titleIndex + 1]
        guard metaLine.hasPrefix("-") else { return nil }

        let (title, author) = splitTitleAuthor(titleLine)
        let lower = metaLine.lowercased()
        let isBookmark = lower.contains("bookmark")
        let isNote = lower.contains("note")

        let body = trimmed[(titleIndex + 2)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isBookmark || !body.isEmpty else { return nil }

        return Clipping(
            title: title,
            author: author,
            isNote: isNote,
            isBookmark: isBookmark,
            location: extractLocation(metaLine),
            addedDate: extractDate(metaLine),
            text: body
        )
    }

    private static func splitTitleAuthor(_ line: String) -> (String, String?) {
        guard line.hasSuffix(")"), let open = line.lastIndex(of: "(") else {
            return (line, nil)
        }
        let author = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
        let title = String(line[..<open]).trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? line : title, author.trimmingCharacters(in: .whitespaces))
    }

    private static func extractLocation(_ meta: String) -> String? {
        guard let range = meta.range(of: "location ", options: .caseInsensitive) else { return nil }
        let rest = meta[range.upperBound...]
        let value = rest.prefix { $0.isNumber || $0 == "-" }
        return value.isEmpty ? nil : String(value)
    }

    private static func extractDate(_ meta: String) -> Date? {
        guard let range = meta.range(of: "Added on ", options: .caseInsensitive) else { return nil }
        let raw = String(meta[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        let formats = [
            "EEEE, MMMM d, yyyy h:mm:ss a",
            "EEEE, d MMMM yyyy HH:mm:ss",
            "EEEE, MMMM d, yyyy h:mm a",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
