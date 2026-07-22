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
    private let editions: EditionService?
    private let mutations: CatalogMutationService
    private let managedFiles: ManagedFileCoordinator

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
        mutations: CatalogMutationService? = nil,
        managedFiles: ManagedFileCoordinator = .shared
    ) {
        self.modelContext = modelContext
        self.settings = settings
        self.metadata = metadata
        self.wishlist = wishlist
        self.toasts = toasts
        self.editions = editions
        self.mutations = mutations ?? CatalogMutationService(
            modelContext: modelContext,
            managedFiles: managedFiles
        )
        self.managedFiles = managedFiles
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

            for (index, calibreBook) in calibreBooks.enumerated() {
                progress = (Self.displayedPosition(for: index), total)

                let isbn = calibreBook.isbn?.lowercased()
                let key = Self.titleAuthorKey(
                    calibreBook.title,
                    calibreBook.authors.joined(separator: ", ")
                )
                if let isbn, !isbn.isEmpty, seenISBNs.contains(isbn) {
                    skipped += 1
                    continue
                }
                if seenKeys.contains(key) {
                    skipped += 1
                    continue
                }

                do {
                    guard let book = try await importOne(calibreBook) else {
                        skipped += 1
                        continue
                    }
                    imported.append(book)
                    if let isbn, !isbn.isEmpty { seenISBNs.insert(isbn) }
                    seenKeys.insert(key)
                } catch {
                    progress = nil
                    toasts.error(String(localized: "Couldn’t save library changes."))
                    return
                }
            }

            if !imported.isEmpty {
                do {
                    let collection = BookCollection(name: Self.collectionName())
                    let collectionID = collection.id
                    try mutations.commit(
                        .createCollection(
                            collectionID: collectionID,
                            bookIDs: imported.map(\.uuid)
                        ),
                        affectedBookIDs: Set(imported.map(\.uuid)),
                        affectedCollectionIDs: [collectionID]
                    ) {
                        collection.books = imported
                        modelContext.insert(collection)
                    }
                } catch {
                    progress = nil
                    toasts.error(String(localized: "Couldn’t save library changes."))
                    return
                }
            }

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

    private func importOne(_ calibreBook: CalibreBook) async throws -> Book? {
        let bookID = UUID()
        var assetSources: [(id: UUID, source: ManagedFileSource)] = []
        assetSources.append((
            bookID,
            try .book(sourceURL: calibreBook.fileURL, fileID: bookID)
        ))
        for url in calibreBook.additionalFileURLs {
            let assetID = UUID()
            assetSources.append((assetID, try .book(sourceURL: url, fileID: assetID)))
        }

        let preparedCover = await Task.detached(priority: .utility) { () -> (NSImage, Data)? in
            guard let coverURL = calibreBook.coverURL,
                  let image = NSImage(contentsOf: coverURL),
                  let data = ImageTranscoder.jpegData(from: image) else { return nil }
            return (image, data)
        }.value

        var sources = assetSources.map(\.source)
        if let coverData = preparedCover?.1 {
            sources.append(.cover(data: coverData, bookID: bookID))
        }
        let fileNames = Set(assetSources.map { $0.source.finalRelativeName })
        let transaction = try await managedFiles.stage(
            intent: .calibreImport,
            sources: sources,
            requirement: ManagedFileRequirement(
                presentBookIDs: [bookID],
                referencedBookFileNames: fileNames,
                coverVersions: preparedCover == nil ? [:] : [bookID: 1]
            )
        )

        let stagedByName = Dictionary(
            uniqueKeysWithValues: transaction.files.map { ($0.finalRelativeName, $0) }
        )
        guard let primary = stagedByName[assetSources[0].source.finalRelativeName] else {
            await managedFiles.abort(transaction)
            return nil
        }

        let book = Book(
            uuid: bookID,
            fileName: primary.finalRelativeName,
            originalFileName: calibreBook.fileURL.lastPathComponent
        )
        book.apply(Self.metadata(from: calibreBook))
        book.rating = calibreBook.rating
        if let dateAdded = calibreBook.dateAdded { book.dateAdded = dateAdded }
        book.fileSizeBytes = primary.byteCount
        if preparedCover != nil { book.coverVersion = 1 }

        let work = Work(title: book.title, author: book.author, dateCreated: book.dateAdded)
        work.preferredEditionUUID = book.uuid
        modelContext.insert(work)
        modelContext.insert(book)
        book.work = work

        for assetSource in assetSources {
            guard let staged = stagedByName[assetSource.source.finalRelativeName] else {
                modelContext.rollback()
                await managedFiles.abort(transaction)
                return nil
            }
            let asset = BookAsset(
                uuid: assetSource.id,
                fileName: staged.finalRelativeName,
                origin: .imported,
                contentHash: staged.sha256,
                sizeBytes: staged.byteCount,
                dateAdded: book.dateAdded,
                validationStatus: .ok,
                book: book
            )
            modelContext.insert(asset)
        }

        let result = try await mutations.commitStagedFiles(
            .calibreImport(bookIDs: [bookID]),
            transactions: [transaction],
            affectedBookIDs: [bookID]
        )
        guard result.isFullyPublished else {
            throw CatalogMutationError.fileTransactionFailed(transaction.id.uuidString)
        }
        if let image = preparedCover?.0 {
            await CoverCache.shared.replace(image, for: book.fileURL)
        }
        return book
    }

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
