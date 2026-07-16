import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class LibraryViewModel {
    private let modelContext: ModelContext
    private let settings: AppSettings
    private let toasts: ToastCenter

    let metadata: MetadataService
    let importer: ImportService
    let calibreImporter: CalibreImportService
    let conversion: ConversionService
    let highlights: HighlightsService
    let exporter: ExportService
    let covers: CoverService
    let health: LibraryHealthService
    let editions: EditionService
    let wishlist: WishlistService
    let notices: NoticeService

    init(modelContext: ModelContext, settings: AppSettings, toasts: ToastCenter,
         online: any OnlineMetadataFetching = OnlineMetadataService()) {
        self.modelContext = modelContext
        self.settings = settings
        self.toasts = toasts
        let wishlist = WishlistService(modelContext: modelContext, toasts: toasts)
        let metadata = MetadataService(modelContext: modelContext, settings: settings, online: online)
        self.wishlist = wishlist
        self.metadata = metadata
        self.notices = NoticeService(
            modelContext: modelContext,
            settings: settings,
            toasts: toasts,
            wishlist: wishlist
        )
        let editions = EditionService(modelContext: modelContext)
        self.editions = editions
        self.importer = ImportService(
            modelContext: modelContext,
            settings: settings,
            metadata: metadata,
            wishlist: wishlist,
            toasts: toasts,
            editions: editions
        )
        self.calibreImporter = CalibreImportService(
            modelContext: modelContext,
            settings: settings,
            metadata: metadata,
            wishlist: wishlist,
            toasts: toasts,
            editions: editions
        )
        self.conversion = ConversionService(modelContext: modelContext, toasts: toasts)
        self.highlights = HighlightsService(modelContext: modelContext)
        self.exporter = ExportService(modelContext: modelContext)
        self.covers = CoverService(modelContext: modelContext)
        self.health = LibraryHealthService(modelContext: modelContext)
    }

    // MARK: - Derived state (forwarded)

    var pendingMetadataUUIDs: Set<UUID> { importer.pendingMetadataUUIDs }
    var convertingUUIDs: Set<UUID> { conversion.convertingUUIDs }
    var enrichingUUIDs: Set<UUID> { metadata.enrichingUUIDs }
    var isExtracting: Bool { importer.isExtracting }
    var pendingMetadataCount: Int { importer.pendingMetadataCount }
    var isFetchingOnline: Bool { metadata.isFetchingOnline }
    var onlineMetadataEnabled: Bool { settings.onlineMetadataEnabled }
    var isImportingCalibre: Bool { calibreImporter.isImporting }
    var calibreImportSummary: String? { calibreImporter.summary }
    var calibreImportProgressText: String? { calibreImporter.progressText }
    var calibreImportFraction: Double? { calibreImporter.progressFraction }
    var isImportingHighlights: Bool { highlights.isImportingHighlights }
    var highlightImportSummary: String? { highlights.highlightImportSummary }
    var isExporting: Bool { exporter.isExporting }
    var metadataFetchSummary: String? { metadata.metadataFetchSummary }

    func isConverting(_ book: Book) -> Bool { conversion.isConverting(book) }

    // MARK: - Add / Remove

    func addBooks(from urls: [URL]) { importer.addBooks(from: urls) }
    func addEditions(from urls: [URL], to work: Work) { importer.addBooks(from: urls, assigningTo: work) }
    func importCalibreLibrary(at root: URL) { calibreImporter.importLibrary(at: root) }

    // MARK: - Integrity (forwarded)

    var missingFileUUIDs: Set<UUID> { health.missingFileUUIDs }
    func isMissing(_ book: Book) -> Bool { health.isMissing(book) }
    @discardableResult
    func scanForMissingFiles() async -> Int { await health.scanForMissingFiles() }
    func relink(_ book: Book, from url: URL) async { await health.relink(book, from: url) }

    func remove(_ book: Book) {
        guard let cleanup = forget(book),
              modelContext.saveQuietly(rollbackOnFailure: true) else { return }
        finishRemoval(cleanup)
        editions.refreshEditionCounts()
    }

    func removeBooks(_ books: [Book]) {
        var seen: Set<UUID> = []
        let cleanups = books.compactMap { book -> RemovedBook? in
            guard seen.insert(book.uuid).inserted else { return nil }
            return forget(book)
        }
        guard !cleanups.isEmpty,
              modelContext.saveQuietly(rollbackOnFailure: true) else { return }
        cleanups.forEach(finishRemoval)
        editions.refreshEditionCounts()
    }

    private struct RemovedBook {
        let uuid: UUID
        let fileNames: Set<String>
    }

    private func forget(_ book: Book) -> RemovedBook? {
        guard book.modelContext != nil else { return nil }
        let work = book.work
        let assetNames = book.assets.isEmpty ? [book.fileName] : book.assets.map(\.fileName)
        covers.cancelPending(for: book.uuid)
        book.work = nil
        modelContext.delete(book)
        WorkService.pruneIfOrphaned(work, context: modelContext, save: false)
        return RemovedBook(uuid: book.uuid, fileNames: Set(assetNames))
    }

    private func finishRemoval(_ removed: RemovedBook) {
        removed.fileNames.forEach { BookFileStore.delete(fileName: $0) }
        CoverStore.delete(for: removed.uuid)
        importer.cancelPending(removed.uuid)
        editions.removeProposals(referencing: removed.uuid)
    }

    // MARK: - Metadata (forwarded)

    func updateMetadata(
        for book: Book,
        title: String?, author: String?, publisher: String?, year: String?,
        series: String?, seriesIndex: String?, language: String?, translator: String?, isbn: String?,
        description: String?, tags: [String]
    ) {
        metadata.updateMetadata(
            for: book, title: title, author: author, publisher: publisher, year: year,
            series: series, seriesIndex: seriesIndex, language: language, translator: translator, isbn: isbn,
            description: description, tags: tags
        )
    }
    func updateRating(for book: Book, rating: Int?) { metadata.updateRating(for: book, rating: rating) }
    func updateNotes(_ notes: String, for book: Book) { metadata.updateNotes(notes, for: book) }
    func bulkUpdate(_ books: [Book], _ edit: BulkEdit) { metadata.bulkUpdate(books, edit) }
    func renameTag(_ old: String, to new: String) { metadata.renameTag(old, to: new) }
    func deleteTag(_ tag: String) { metadata.deleteTag(tag) }
    func renameSeries(_ old: String, to new: String) { metadata.renameSeries(old, to: new) }
    func renameAuthor(_ old: String, to new: String) { metadata.renameAuthor(old, to: new) }
    func applyMetadataFix(_ fix: MetadataFix) { metadata.applyMetadataFix(fix) }
    func applyMetadataFixes(_ fixes: [MetadataFix]) { metadata.applyMetadataFixes(fixes) }
    func backfillPageCount(for book: Book) async { await metadata.backfillPageCount(for: book) }
    func markNotSample(_ book: Book) { metadata.markNotSample(book) }
    func fetchOnlineMetadata(for book: Book) { metadata.fetchOnlineMetadata(for: book) }
    func fetchOnlineMetadata(for books: [Book]) { metadata.fetchOnlineMetadata(for: books) }
    func backfillOnlineMetadata() { metadata.backfillMissingOnlineMetadata() }

    // MARK: - Convert (forwarded)

    func convert(_ book: Book) { conversion.convert(book) }
    func convert(_ book: Book, to format: EbookConverter.OutputFormat) { conversion.convert(book, to: format) }
    func convertBooks(_ books: [Book]) { conversion.convertBooks(books) }
    func convertBooks(_ books: [Book], to format: EbookConverter.OutputFormat) { conversion.convertBooks(books, to: format) }

    // MARK: - Highlights / Export / Covers (forwarded)

    func importHighlights(via monitor: DeviceMonitor) { highlights.importHighlights(via: monitor) }
    func exportLibrary(to folder: URL) { exporter.exportLibrary(to: folder) }
    func setCustomCover(for book: Book, from url: URL) { covers.setCustomCover(for: book, from: url) }
    func resetCover(for book: Book) { covers.resetCover(for: book) }
    func duplicateGroups() async -> [DuplicateGroup] { await health.duplicateGroups() }
    func metadataFixes() async -> [MetadataFix] { await health.metadataFixes() }
    func seriesSuggestions() async -> [String] { await health.seriesSuggestions() }

    // MARK: - Maintenance (forwarded)

    func backfillMissingSizes() { importer.backfillMissingSizes() }
    func rescanMissingMetadata() { importer.rescanMissingMetadata() }
    func detectMissingDRM() { importer.detectMissingDRM() }
    func backfillMissingAssetHashes() async {
        await BookAssetMaintenance.backfillMissingHashes(context: modelContext)
    }

    func adoptConversionArtifact(for bookUUID: UUID, from url: URL) async {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.uuid == bookUUID })
        guard let book = try? modelContext.fetch(descriptor).first else { return }
        let format = url.pathExtension.lowercased()
        let primary = book.assets.first { $0.fileName == book.fileName }
        let primaryFileName = book.fileName
        let primaryDateAdded = primary?.dateAdded
        let primaryURL = book.fileURL
        let sourceHash: String?
        if let contentHash = primary?.contentHash {
            sourceHash = contentHash
        } else {
            sourceHash = await Task.detached(priority: .utility) {
                try? ContentHasher.sha256(of: primaryURL)
            }.value
        }
        guard book.modelContext != nil, book.fileName == primaryFileName,
              primary?.dateAdded == primaryDateAdded else { return }
        let artifactHash = await Task.detached(priority: .utility) {
            try? ContentHasher.sha256(of: url)
        }.value
        guard book.modelContext != nil, book.fileName == primaryFileName,
              primary?.dateAdded == primaryDateAdded else { return }
        let existing = book.assets.first {
            $0.origin == .generated && $0.format.lowercased() == format
        }
        let assetUUID = existing?.uuid ?? UUID()
        let oldFileName = existing?.fileName
        let fileName: String
        do {
            if let oldFileName {
                fileName = try BookFileStore.replacementCopy(
                    of: url, replacing: oldFileName, uuid: assetUUID
                )
            } else {
                fileName = try BookFileStore.importCopy(of: url, uuid: assetUUID)
            }
        } catch {
            return
        }
        let size = BookFileStore.size(of: fileName)
        if primary?.contentHash == nil { primary?.contentHash = sourceHash }
        if let existing {
            let wasPrimary = book.fileName == existing.fileName
            existing.fileName = fileName
            existing.sizeBytes = size
            existing.contentHash = artifactHash
            existing.generatedFromContentHash = sourceHash
            existing.validationStatus = .ok
            existing.dateAdded = Date()
            if wasPrimary {
                book.fileName = fileName
                book.fileSizeBytes = size
            }
        } else {
            let asset = BookAsset(
                uuid: assetUUID,
                fileName: fileName,
                origin: .generated,
                contentHash: artifactHash,
                generatedFromContentHash: sourceHash,
                sizeBytes: size,
                validationStatus: .ok,
                book: book
            )
            modelContext.insert(asset)
        }
        guard modelContext.saveQuietly(rollbackOnFailure: true) else {
            BookFileStore.delete(fileName: fileName)
            return
        }
        if let oldFileName, oldFileName != fileName {
            BookFileStore.delete(fileName: oldFileName)
        }
    }

    @discardableResult
    func addFile(to book: Book, from url: URL, origin: AssetOrigin = .imported) async -> BookAsset? {
        let uuid = UUID()
        guard let fileName = try? BookFileStore.importCopy(of: url, uuid: uuid) else { return nil }
        let managedURL = BookFileStore.url(for: fileName)
        let contentHash = await Task.detached(priority: .utility) {
            try? ContentHasher.sha256(of: managedURL)
        }.value
        guard book.modelContext != nil else {
            BookFileStore.delete(fileName: fileName)
            return nil
        }
        if let contentHash,
           let existing = book.assets.first(where: { $0.contentHash == contentHash }) {
            BookFileStore.delete(fileName: fileName)
            return existing
        }
        let asset = BookAsset(
            uuid: uuid,
            fileName: fileName,
            origin: origin,
            contentHash: contentHash,
            sizeBytes: BookFileStore.size(of: fileName),
            validationStatus: .ok,
            book: book
        )
        modelContext.insert(asset)
        do {
            try modelContext.save()
            LibraryMutationLog.shared.bump()
            return asset
        } catch {
            modelContext.rollback()
            BookFileStore.delete(fileName: fileName)
            return nil
        }
    }

    func replace(_ asset: BookAsset, in book: Book, from url: URL) async {
        guard asset.modelContext != nil, book.modelContext != nil,
              asset.book?.uuid == book.uuid else { return }
        let oldName = asset.fileName
        let wasPrimary = book.fileName == oldName
        guard let fileName = try? BookFileStore.replacementCopy(
            of: url, replacing: oldName, uuid: asset.uuid
        ) else { return }
        let replacementDate = Date()
        asset.fileName = fileName
        asset.sizeBytes = BookFileStore.size(of: fileName)
        asset.contentHash = nil
        asset.generatedFromContentHash = nil
        asset.origin = .imported
        asset.validationStatus = .ok
        asset.dateAdded = replacementDate
        if wasPrimary {
            book.fileName = fileName
            book.fileSizeBytes = asset.sizeBytes
            book.drmProtected = nil
            book.coverVersion += 1
        }
        guard modelContext.saveQuietly(rollbackOnFailure: true) else {
            BookFileStore.delete(fileName: fileName)
            return
        }
        if fileName != oldName { BookFileStore.delete(fileName: oldName) }

        let managedURL = BookFileStore.url(for: fileName)
        let analysis = await Task.detached(priority: .utility) {
            (
                try? ContentHasher.sha256(of: managedURL),
                DRMDetector.isProtected(url: managedURL)
            )
        }.value
        guard asset.modelContext != nil, book.modelContext != nil,
              asset.book?.uuid == book.uuid,
              asset.fileName == fileName,
              asset.dateAdded == replacementDate else { return }
        asset.contentHash = analysis.0
        if wasPrimary, book.fileName == fileName {
            book.drmProtected = analysis.1
        }
        modelContext.saveQuietly()
    }

    func makePrimary(_ asset: BookAsset, for book: Book) async {
        guard asset.book?.uuid == book.uuid,
              asset.validationStatus != .missing,
              asset.validationStatus != .corrupt else { return }
        let assetURL = asset.fileURL
        let assetFileName = asset.fileName
        let assetDateAdded = asset.dateAdded
        let analysis = await Task.detached(priority: .utility) {
            (
                DRMDetector.isProtected(url: assetURL),
                BookFileStore.size(of: assetFileName)
            )
        }.value
        guard asset.modelContext != nil, book.modelContext != nil,
              asset.book?.uuid == book.uuid,
              asset.fileName == assetFileName,
              asset.dateAdded == assetDateAdded,
              asset.validationStatus != .missing,
              asset.validationStatus != .corrupt else { return }
        if asset.sizeBytes == 0, analysis.1 > 0 { asset.sizeBytes = analysis.1 }
        book.fileName = assetFileName
        book.fileSizeBytes = asset.sizeBytes
        book.drmProtected = analysis.0
        book.coverVersion += 1
        modelContext.saveQuietly()
    }

    @discardableResult
    func removeFile(_ asset: BookAsset, from book: Book) -> Bool {
        guard asset.book?.uuid == book.uuid, book.assets.count > 1, asset.fileName != book.fileName else { return false }
        let fileName = asset.fileName
        modelContext.delete(asset)
        do {
            try modelContext.save()
            LibraryMutationLog.shared.bump()
            BookFileStore.delete(fileName: fileName)
            return true
        } catch {
            modelContext.rollback()
            return false
        }
    }

    func validate(_ asset: BookAsset) async {
        let url = asset.fileURL
        let fileName = asset.fileName
        let dateAdded = asset.dateAdded
        let status = await Task.detached(priority: .utility) {
            BookAssetValidator.validate(url: url)
        }.value
        guard asset.modelContext != nil,
              asset.fileName == fileName,
              asset.dateAdded == dateAdded else { return }
        asset.validationStatus = status
        modelContext.saveQuietly()
    }

    // MARK: - Reading status

    func setReadingStatus(_ status: ReadingStatus, for books: [Book]) {
        let newlyFinished = status == .finished
            ? books.filter { $0.readingStatus != .finished }
            : []
        for book in books { book.setStatus(status) }
        modelContext.saveQuietly()
        notices.booksDidFinish(newlyFinished)
    }

    // MARK: - Collections

    @discardableResult
    func createCollection(named name: String, adding books: [Book] = [], savedSearch: String? = nil) -> BookCollection {
        let collection = BookCollection(name: name, savedSearch: savedSearch)
        collection.books = books
        modelContext.insert(collection)
        modelContext.saveQuietly()
        return collection
    }

    @discardableResult
    func createSmartShelf(named name: String, definition: SmartShelfDefinition) -> BookCollection {
        let collection = BookCollection(name: name)
        collection.smartShelfDefinition = definition
        modelContext.insert(collection)
        modelContext.saveQuietly()
        return collection
    }

    func updateSmartShelf(
        _ collection: BookCollection,
        name: String,
        definition: SmartShelfDefinition
    ) {
        guard !collection.isSystem else { return }
        collection.name = name
        collection.savedSearch = nil
        collection.smartShelfDefinition = definition
        modelContext.saveQuietly()
    }

    func renameCollection(_ collection: BookCollection, to name: String) {
        guard !collection.isSystem else { return }
        collection.name = name
        modelContext.saveQuietly()
    }

    func deleteCollection(_ collection: BookCollection) {
        guard !collection.isSystem else { return }
        modelContext.delete(collection)
        modelContext.saveQuietly()
    }

    func add(_ books: [Book], to collection: BookCollection) {
        for book in books where !collection.books.contains(where: { $0.uuid == book.uuid }) {
            collection.books.append(book)
        }
        modelContext.saveQuietly()
    }

    func remove(_ books: [Book], from collection: BookCollection) {
        let ids = Set(books.map(\.uuid))
        collection.books.removeAll { ids.contains($0.uuid) }
        modelContext.saveQuietly()
    }
}
