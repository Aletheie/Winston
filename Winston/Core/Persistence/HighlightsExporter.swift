import Foundation

nonisolated enum HighlightsExporter {

    struct BookHighlights: Sendable {
        var title: String
        var author: String?
        var entries: [Entry]

        struct Entry: Sendable {
            var text: String
            var isNote: Bool
            var location: String?
        }
    }

    struct Result: Sendable { var written: Int; var failed: Int }

    @discardableResult
    static func export(_ books: [BookHighlights], to folder: URL) -> Result {
        var written = 0, failed = 0
        var usedNames = Set<String>()
        for book in books where !book.entries.isEmpty {
            let name = FileNaming.uniqueName(fileName(for: book), in: &usedNames)
            let url = folder.appending(path: name)
            do {
                try markdown(for: book).data(using: .utf8)?.write(to: url, options: .atomic)
                written += 1
            } catch {
                failed += 1
            }
        }
        return Result(written: written, failed: failed)
    }

    static func markdown(for book: BookHighlights) -> String {
        var lines = ["# \(book.title)"]
        if let author = book.author, !author.isEmpty { lines.append("_\(author)_") }
        lines.append("")
        for entry in book.entries {
            if entry.isNote {
                lines.append("**Note:** \(entry.text)")
            } else {
                lines.append("> \(entry.text)")
            }
            if let location = entry.location, !location.isEmpty {
                lines.append("— location \(location)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - File naming

    static func fileName(for book: BookHighlights) -> String {
        let base = [book.author, book.title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " - ")
        let stem = FileNaming.sanitized(base.isEmpty ? book.title : base, separator: " ")
        return "\(stem.isEmpty ? "Untitled" : stem).md"
    }
}
