import Foundation
import SwiftData
import AppKit

@MainActor
@Observable
final class CalibreImportService {
    private let modelContext: ModelContext
    private let settings: AppSettings
    private let metadata: MetadataService
    private let wishlist: WishlistService
    private let toasts: ToastCenter

    nonisolated static let kindlePreference = ["azw3", "mobi", "azw", "epub", "pdf", "txt"]

    private(set) var isImporting = false
    private(set) var progress: (done: Int, total: Int)?
    private(set) var summary: String?

    init(
        modelContext: ModelContext,
        settings: AppSettings,
        metadata: MetadataService,
        wishlist: WishlistService,
        toasts: ToastCenter
    ) {
        self.modelContext = modelContext
        self.settings = settings
        self.metadata = metadata
        self.wishlist = wishlist
        self.toasts = toasts
    }

    var progressText: String? {
        guard let progress else { return nil }
        return String(localized: "Importing from Calibre\u{2026} \(progress.done)/\(progress.total)")
    }

    var progressFraction: Double? {
        guard let progress, progress.total > 0 else { return nil }
        return Double(progress.done) / Double(progress.total)
    }

    func importLibrary(at root: URL) {
        guard !isImporting else { return }
        isImporting = true
        summary = nil
        progress = nil

        Task {
            defer { isImporting = false }

            let calibreBooks: [CalibreBook]
            do {
                calibreBooks = try await Task.detached(priority: .userInitiated) {
                    try CalibreLibraryReader.read(libraryRoot: root, formatPreference: Self.kindlePreference)
                }.value
            } catch CalibreImportError.noLibrary {
                toasts.error(String(localized: "No Calibre library (metadata.db) found in that folder."))
                return
            } catch {
                toasts.error(String(localized: "Couldn\u{2019}t read the Calibre library."))
                return
            }

            guard !calibreBooks.isEmpty else {
                toasts.error(String(localized: "No importable books found in that Calibre library."))
                return
            }

            let existing = modelContext.allBooks()
            var seenISBNs = Set(existing.compactMap { $0.isbn?.lowercased() }.filter { !$0.isEmpty })
            var seenKeys = Set(existing.map { Self.titleAuthorKey($0.displayTitle, $0.displayAuthor) })

            let total = calibreBooks.count
            progress = (0, total)
            var imported: [Book] = []
            var skipped = 0

            for (index, cb) in calibreBooks.enumerated() {
                progress = (Self.displayedPosition(for: index), total)

                let isbn = cb.isbn?.lowercased()
                let key = Self.titleAuthorKey(cb.title, cb.authors.joined(separator: ", "))
                if let isbn, !isbn.isEmpty, seenISBNs.contains(isbn) { skipped += 1; continue }
                if seenKeys.contains(key) { skipped += 1; continue }

                let uuid = UUID()
                let source = cb.fileURL
                guard let fileName = await Task.detached(priority: .userInitiated, operation: {
                    try? BookFileStore.importCopy(of: source, uuid: uuid)
                }).value else { skipped += 1; continue }

                let book = Book(uuid: uuid, fileName: fileName, originalFileName: source.lastPathComponent)
                book.apply(Self.metadata(from: cb))
                book.rating = cb.rating
                if let dateAdded = cb.dateAdded { book.dateAdded = dateAdded }
                book.fileSizeBytes = BookFileStore.size(of: fileName)
                modelContext.insert(book)
                imported.append(book)

                if let isbn, !isbn.isEmpty { seenISBNs.insert(isbn) }
                seenKeys.insert(key)

                if let coverURL = cb.coverURL {
                    let image = await Task.detached(priority: .utility) { NSImage(contentsOf: coverURL) }.value
                    if let image {
                        CoverStore.save(image, for: uuid)
                        await CoverCache.shared.replace(image, for: book.fileURL)
                    }
                }

                if imported.count % 25 == 0 { modelContext.saveQuietly() }
            }

            if !imported.isEmpty {
                let collection = BookCollection(name: Self.collectionName())
                collection.books = imported
                modelContext.insert(collection)
            }
            modelContext.saveQuietly()
            wishlist.fulfil(with: imported)
            progress = nil

            finish(summary: Self.summaryText(imported: imported.count, total: total, skipped: skipped))

            if settings.onlineMetadataEnabled { metadata.backfillMissingOnlineMetadata() }
        }
    }

    nonisolated static func displayedPosition(for zeroBasedIndex: Int) -> Int {
        zeroBasedIndex + 1
    }

    // MARK: - Helpers

    private func finish(summary: String) {
        self.summary = summary
        Task {
            try? await Task.sleep(for: .seconds(6))
            if !isImporting { self.summary = nil }
        }
    }

    private static func metadata(from cb: CalibreBook) -> BookMetadata {
        var meta = BookMetadata()
        meta.title = cb.title
        meta.author = cb.authors.isEmpty ? nil : cb.authors.joined(separator: ", ")
        meta.publisher = cb.publisher
        meta.year = cb.year
        meta.language = cb.language
        meta.isbn = cb.isbn
        meta.series = cb.series
        meta.seriesIndex = cb.seriesIndex
        meta.tags = cb.tags
        meta.description = cb.bookDescription
        return meta
    }

    private static func titleAuthorKey(_ title: String, _ author: String?) -> String {
        BookMatchKey(title: title, author: author).storageValue
    }

    private static func collectionName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Calibre Import \(formatter.string(from: Date()))"
    }

    private static func summaryText(imported: Int, total: Int, skipped: Int) -> String {
        if skipped > 0 {
            return String(localized: "Imported \(imported) of \(total) from Calibre (\(skipped) skipped).")
        }
        return String(localized: "Imported \(imported) of \(total) from Calibre.")
    }
}
