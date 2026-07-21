import Foundation
import SwiftData
import AppKit

private nonisolated struct CalibreManagedFile: Sendable {
    let fileName: String
    let contentHash: String?
    let sizeBytes: Int64
}

private nonisolated enum CalibreFileImporter {
    static func copy(_ source: URL, uuid: UUID) -> CalibreManagedFile? {
        guard let fileName = try? BookFileStore.importCopy(of: source, uuid: uuid) else {
            return nil
        }
        let managedURL = BookFileStore.url(for: fileName)
        return CalibreManagedFile(
            fileName: fileName,
            contentHash: try? ContentHasher.sha256(of: managedURL),
            sizeBytes: BookFileStore.size(of: fileName)
        )
    }
}

@MainActor
@Observable
final class CalibreImportService {
    private let modelContext: ModelContext
    private let settings: AppSettings
    private let metadata: MetadataService
    private let wishlist: WishlistService
    private let toasts: ToastCenter
    private let editions: EditionService?
    private let covers: CoverRepository

    nonisolated static let kindlePreference = ["azw3", "mobi", "azw", "epub", "pdf", "txt"]

    private(set) var isImporting = false
    private(set) var progress: (done: Int, total: Int)?
    private(set) var summary: String?

    init(
        modelContext: ModelContext,
        settings: AppSettings,
        metadata: MetadataService,
        wishlist: WishlistService,
        toasts: ToastCenter,
        editions: EditionService? = nil,
        covers: CoverRepository = .shared
    ) {
        self.modelContext = modelContext
        self.settings = settings
        self.metadata = metadata
        self.wishlist = wishlist
        self.toasts = toasts
        self.editions = editions
        self.covers = covers
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
                guard let managedFile = await Task.detached(priority: .userInitiated, operation: {
                    CalibreFileImporter.copy(source, uuid: uuid)
                }).value else { skipped += 1; continue }
                let fileName = managedFile.fileName

                let book = Book(uuid: uuid, fileName: fileName, originalFileName: source.lastPathComponent)
                book.apply(Self.metadata(from: cb))
                book.rating = cb.rating
                if let dateAdded = cb.dateAdded { book.dateAdded = dateAdded }
                book.fileSizeBytes = managedFile.sizeBytes
                let work = Work(title: book.title, author: book.author, dateCreated: book.dateAdded)
                work.preferredEditionUUID = book.uuid
                let primaryAsset = BookAsset(
                    uuid: uuid,
                    fileName: fileName,
                    origin: .imported,
                    contentHash: managedFile.contentHash,
                    sizeBytes: book.fileSizeBytes,
                    dateAdded: book.dateAdded,
                    validationStatus: .ok,
                    book: book
                )
                modelContext.insert(work)
                modelContext.insert(book)
                modelContext.insert(primaryAsset)
                book.work = work

                for siblingURL in cb.additionalFileURLs {
                    let assetUUID = UUID()
                    guard let siblingFile = await Task.detached(priority: .userInitiated, operation: {
                        CalibreFileImporter.copy(siblingURL, uuid: assetUUID)
                    }).value else { continue }
                    let asset = BookAsset(
                        uuid: assetUUID,
                        fileName: siblingFile.fileName,
                        origin: .imported,
                        contentHash: siblingFile.contentHash,
                        sizeBytes: siblingFile.sizeBytes,
                        dateAdded: book.dateAdded,
                        validationStatus: .ok,
                        book: book
                    )
                    modelContext.insert(asset)
                }
                imported.append(book)

                if let isbn, !isbn.isEmpty { seenISBNs.insert(isbn) }
                seenKeys.insert(key)

                if let coverURL = cb.coverURL {
                    let token = await covers.beginBackgroundMutation(for: uuid)
                    let prepared = await Task.detached(priority: .utility) {
                        guard let image = NSImage(contentsOf: coverURL),
                              let data = ImageTranscoder.jpegData(from: image) else { return nil }
                        return (image, data)
                    }.value
                    if let (image, data) = prepared,
                       await covers.install(data, using: token, onlyIfMissing: true) != nil {
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
            if let editions {
                let previousKeys = Set(editions.pendingProposals.map(\.pairKey))
                let importedUUIDs = Set(imported.map(\.uuid))
                await editions.scanLibrary()
                if editions.pendingProposals.contains(where: {
                    !previousKeys.contains($0.pairKey)
                        && !$0.memberUUIDs.allSatisfy { !importedUUIDs.contains($0) }
                }) {
                    toasts.post(
                        String(localized: "Edition suggestions are ready to review."),
                        style: .info,
                        action: .reviewEditionProposals
                    )
                }
            }
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
