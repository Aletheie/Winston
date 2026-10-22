import Foundation
import SwiftData
import OSLog

extension ModelContext {
    /// Explicit global scan for recovery/analysis paths whose fuzzy or
    /// relationship logic cannot be represented by a SwiftData predicate.
    /// Callers must decide how a fetch failure affects their operation.
    func fetchAllBooksForGlobalAnalysis() throws -> [Book] {
        let interval = Log.librarySignposter.beginInterval("GlobalBookFetch")
        LibraryPerformanceDiagnostics.beginSQLScope("global_book_fetch")
        defer {
            LibraryPerformanceDiagnostics.endSQLScope("global_book_fetch")
            Log.librarySignposter.endInterval("GlobalBookFetch", interval)
        }
        return try fetch(FetchDescriptor<Book>())
    }

}

/// Cursor for bounded catalog scans ordered by date and UUID. The offset only
/// skips books at the boundary date, including when that date spans many pages.
nonisolated struct BookPageCursor: Sendable {
    private var dateAdded: Date?
    private var offset = 0

    init() {}

    func descriptor(limit: Int) -> FetchDescriptor<Book> {
        var descriptor = FetchDescriptor<Book>(
            sortBy: [SortDescriptor(\Book.dateAdded), SortDescriptor(\Book.uuid)]
        )
        if let dateAdded {
            descriptor.predicate = #Predicate { $0.dateAdded >= dateAdded }
            descriptor.fetchOffset = offset
        }
        descriptor.fetchLimit = max(1, limit)
        return descriptor
    }

    /// Call synchronously on the executor that fetched these models.
    func advancing(past books: [Book]) -> Self {
        guard let lastDate = books.last?.dateAdded else { return self }
        let trailingCount = books.reversed().prefix { $0.dateAdded == lastDate }.count
        var next = self
        next.dateAdded = lastDate
        next.offset = dateAdded == lastDate ? offset + trailingCount : trailingCount
        return next
    }
}

nonisolated let libraryEbookExtensions: Set<String> = ["epub", "mobi", "azw", "azw3", "pdf", "txt", "html", "htm"]

nonisolated enum FileNaming {
    static func sanitized(_ name: String, separator: String = "-") -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: separator)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func uniqueName(_ base: String, in used: inout Set<String>) -> String {
        guard used.contains(base) else { used.insert(base); return base }
        let ext = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            if !used.contains(candidate) { used.insert(candidate); return candidate }
            i += 1
        }
    }
}
