import Foundation
import SwiftData
import OSLog

extension ModelContext {
    // Fetch-all on purpose: callers match on computed/fuzzy keys #Predicate can't express.
    func allBooks() -> [Book] {
        (try? fetch(FetchDescriptor<Book>())) ?? []
    }

    func saveAndPublish(
        catalogChanged: Bool = true,
        affectedBookIDs: Set<UUID>? = nil,
        affectedCollectionIDs: Set<UUID> = [],
        changesBookMembership: Bool = false,
        fullTextAffectedBookIDs: Set<UUID>? = []
    ) throws {
        try save()
        LibraryMutationLog.shared.bump(
            catalogChanged: catalogChanged,
            affectedBookIDs: affectedBookIDs,
            affectedCollectionIDs: affectedCollectionIDs,
            changesBookMembership: changesBookMembership,
            fullTextAffectedBookIDs: fullTextAffectedBookIDs
        )
    }

    @discardableResult
    func saveQuietly(
        rollbackOnFailure _: Bool = true,
        catalogChanged: Bool = true,
        affectedBookIDs: Set<UUID>? = nil,
        affectedCollectionIDs: Set<UUID> = [],
        changesBookMembership: Bool = false,
        fullTextAffectedBookIDs: Set<UUID>? = []
    ) -> Bool {
        do {
            try saveAndPublish(
                catalogChanged: catalogChanged,
                affectedBookIDs: affectedBookIDs,
                affectedCollectionIDs: affectedCollectionIDs,
                changesBookMembership: changesBookMembership,
                fullTextAffectedBookIDs: fullTextAffectedBookIDs
            )
            return true
        } catch {
            rollback()
            Log.persistence.error("Best-effort SwiftData save failed and rolled back: \(error.localizedDescription, privacy: .public)")
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
