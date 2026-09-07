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
            var isFavorite: Bool = false
            var tags: [String] = []
            var reflection: String? = nil
        }
    }

    struct Result: Sendable { var written: Int; var failed: Int }

    static func books(from items: [HighlightWorkspaceItem]) -> [BookHighlights] {
        var orderedBookIDs: [UUID] = []
        var entriesByBookID: [UUID: [BookHighlights.Entry]] = [:]
        var identityByBookID: [UUID: (title: String, author: String?)] = [:]

        for item in items {
            if entriesByBookID[item.bookID] == nil {
                orderedBookIDs.append(item.bookID)
                identityByBookID[item.bookID] = (item.bookTitle, item.bookAuthor)
            }
            entriesByBookID[item.bookID, default: []].append(.init(
                text: item.text,
                isNote: item.isNote,
                location: item.location,
                isFavorite: item.isFavorite,
                tags: item.tags,
                reflection: item.reflection
            ))
        }

        return orderedBookIDs.compactMap { bookID in
            guard let identity = identityByBookID[bookID],
                  let entries = entriesByBookID[bookID] else { return nil }
            return BookHighlights(
                title: identity.title,
                author: identity.author,
                entries: entries
            )
        }
    }

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
            if entry.isFavorite {
                lines.append("**Favorite**")
            }
            if entry.isNote {
                lines.append("**Note:** \(entry.text)")
            } else {
                lines.append("> \(entry.text)")
            }
            if let location = entry.location, !location.isEmpty {
                lines.append("— location \(location)")
            }
            if !entry.tags.isEmpty {
                lines.append("Tags: \(entry.tags.map { "`\($0)`" }.joined(separator: ", "))")
            }
            if let reflection = entry.reflection?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !reflection.isEmpty {
                lines.append("")
                lines.append("**Reflection:**")
                lines.append(reflection)
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
