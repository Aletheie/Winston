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
