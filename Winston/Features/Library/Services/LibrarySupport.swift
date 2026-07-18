import Foundation
import SwiftData
import OSLog

extension ModelContext {
    // Fetch-all on purpose: callers match on computed/fuzzy keys #Predicate can't express.
    func allBooks() -> [Book] {
        (try? fetch(FetchDescriptor<Book>())) ?? []
    }

    @discardableResult
    func saveQuietly(rollbackOnFailure: Bool = false, catalogChanged: Bool = true) -> Bool {
        do {
            try save()
            LibraryMutationLog.shared.bump(catalogChanged: catalogChanged)
            return true
        } catch {
            if rollbackOnFailure {
                rollback()
                Log.persistence.error("SwiftData save failed; rolled back: \(error.localizedDescription, privacy: .public)")
            } else {
                Log.persistence.error("SwiftData save failed; changes remain pending: \(error.localizedDescription, privacy: .public)")
            }
            return false
        }
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
