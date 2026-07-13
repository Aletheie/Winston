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
    let wishlist: WishlistService

    init(modelContext: ModelContext, settings: AppSettings, toasts: ToastCenter,
         online: any OnlineMetadataFetching = OnlineMetadataService()) {
        self.modelContext = modelContext
        self.settings = settings
        self.toasts = toasts
        let wishlist = WishlistService(modelContext: modelContext, toasts: toasts)
        let metadata = MetadataService(modelContext: modelContext, settings: settings, online: online)
        self.wishlist = wishlist
        self.metadata = metadata
        self.importer = ImportService(
            modelContext: modelContext,
            settings: settings,
            metadata: metadata,
            wishlist: wishlist,
            toasts: toasts
        )
        self.calibreImporter = CalibreImportService(
            modelContext: modelContext,
            settings: settings,
            metadata: metadata,
            wishlist: wishlist,
            toasts: toasts
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
    func importCalibreLibrary(at root: URL) { calibreImporter.importLibrary(at: root) }

    // MARK: - Integrity (forwarded)

    var missingFileUUIDs: Set<UUID> { health.missingFileUUIDs }
    func isMissing(_ book: Book) -> Bool { health.isMissing(book) }
    @discardableResult
    func scanForMissingFiles() async -> Int { await health.scanForMissingFiles() }
    func relink(_ book: Book, from url: URL) { health.relink(book, from: url) }

    func remove(_ book: Book) {
        forget(book)
        modelContext.saveQuietly()
    }

    func removeBooks(_ books: [Book]) {
        for book in books { forget(book) }
        modelContext.saveQuietly()
    }

    private func forget(_ book: Book) {
        BookFileStore.delete(fileName: book.fileName)
        CoverStore.delete(for: book.uuid)
        importer.cancelPending(book.uuid)
        modelContext.delete(book)
    }

    // MARK: - Metadata (forwarded)

    func updateMetadata(
        for book: Book,
        title: String?, author: String?, publisher: String?, year: String?,
        series: String?, seriesIndex: String?, language: String?, isbn: String?,
        description: String?, tags: [String]
    ) {
        metadata.updateMetadata(
            for: book, title: title, author: author, publisher: publisher, year: year,
            series: series, seriesIndex: seriesIndex, language: language, isbn: isbn,
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

    // MARK: - Maintenance (forwarded)

    func backfillMissingSizes() { importer.backfillMissingSizes() }
    func rescanMissingMetadata() { importer.rescanMissingMetadata() }
    func detectMissingDRM() { importer.detectMissingDRM() }

    // MARK: - Reading status

    func setReadingStatus(_ status: ReadingStatus, for books: [Book]) {
        for book in books { book.setStatus(status) }
        modelContext.saveQuietly()
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
