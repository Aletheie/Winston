import Foundation
import SwiftData
import OSLog

enum LegacyLibraryMigrator {
    private struct LegacyMetadata: Decodable {
        var title: String?
        var author: String?
        var publisher: String?
        var year: String?
        var language: String?
        var isbn: String?
        var series: String?
        var seriesIndex: String?
        var tags: [String]?
        var description: String?
    }

    private struct LegacyBook: Decodable {
        let id: UUID
        var fileURL: URL
        var bookmarkData: Data?
        var metadata: LegacyMetadata
        var rating: Int?
        let dateAdded: Date
    }

    static func migrateIfNeeded(context: ModelContext) {
        let legacyFile = AppPaths.appSupportDirectory.appending(path: "library.json")
        guard FileManager.default.fileExists(atPath: legacyFile.path(percentEncoded: false)) else { return }

        guard let data = try? Data(contentsOf: legacyFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let legacyBooks = try? decoder.decode([LegacyBook].self, from: data) else { return }

        for legacy in legacyBooks {
            let sourceURL = resolveURL(for: legacy)
            guard FileManager.default.fileExists(atPath: sourceURL.path),
                  let fileName = try? BookFileStore.importCopy(of: sourceURL, uuid: legacy.id)
            else { continue }

            let book = Book(
                uuid: legacy.id,
                fileName: fileName,
                originalFileName: legacy.fileURL.lastPathComponent,
                dateAdded: legacy.dateAdded
            )
            book.fileSizeBytes = BookFileStore.size(of: fileName)
            book.title = legacy.metadata.title
            book.author = legacy.metadata.author
            book.publisher = legacy.metadata.publisher
            book.year = legacy.metadata.year
            book.language = legacy.metadata.language
            book.isbn = legacy.metadata.isbn
            book.series = legacy.metadata.series
            book.seriesIndex = legacy.metadata.seriesIndex
            book.tags = legacy.metadata.tags ?? []
            book.bookDescription = legacy.metadata.description
            book.rating = legacy.rating
            context.insert(book)
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            Log.persistence.error("Legacy migration save failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let backup = AppPaths.appSupportDirectory.appending(path: "library.v1.bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: legacyFile, to: backup)
    }

    private static func resolveURL(for legacy: LegacyBook) -> URL {
        guard let bookmarkData = legacy.bookmarkData else { return legacy.fileURL }
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            _ = url.startAccessingSecurityScopedResource()
            return url
        }
        return legacy.fileURL
    }
}
