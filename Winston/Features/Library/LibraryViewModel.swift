import Foundation
import SwiftData
import Observation

struct PhysicalBookDraft: Sendable {
    var title: String
    var author: String
    var publisher: String
    var year: String
    var isbn: String
    var shelfLocation: String
    var notes: String
    var readingStatus: ReadingStatus
}

@MainActor
@Observable
final class LibraryViewModel {
    private let modelContext: ModelContext
    private let settings: AppSettings
    private let toasts: ToastCenter
    private let mutations: CatalogMutationService
    private let managedFiles: ManagedFileCoordinator

    let metadata: MetadataService
    let importer: ImportService
    let calibreImporter: CalibreImportService
    let conversion: ConversionService
    let highlights: HighlightsService
    let exporter: ExportService
    let covers: CoverService
    let health: LibraryHealthService
    let editions: CatalogReconciliationService
    let wishlist: WishlistService
    let notices: NoticeService
    let maintenance: MaintenanceScheduler

    init(modelContext: ModelContext, settings: AppSettings, toasts: ToastCenter,
         online: any OnlineMetadataFetching = OnlineMetadataService(),
         saveAdapter: CatalogSaveAdapter = .live,
         managedFiles: ManagedFileCoordinator = .shared) {
        self.modelContext = modelContext
        self.settings = settings
        self.toasts = toasts
        let mutations = CatalogMutationService(
            modelContext: modelContext,
            saveAdapter: saveAdapter,
            managedFiles: managedFiles
        )
        self.mutations = mutations
        self.managedFiles = managedFiles
        let wishlist = WishlistService(modelContext: modelContext, toasts: toasts)
        let metadata = MetadataService(
            modelContext: modelContext,
            settings: settings,
            online: online,
            mutations: mutations
        )
        self.wishlist = wishlist
        self.metadata = metadata
        self.notices = NoticeService(
            modelContext: modelContext,
            settings: settings,
            toasts: toasts,
            wishlist: wishlist
        )
        let editions = CatalogReconciliationService(
            modelContext: modelContext,
            mutations: mutations,
            managedFiles: managedFiles,
            toasts: toasts,
            loadEditionCountsImmediately: false
        )
        self.editions = editions
        let importer = ImportService(
            modelContext: modelContext,
            settings: settings,
            metadata: metadata,
            wishlist: wishlist,
            toasts: toasts,
            editions: editions,
            mutations: mutations,
            managedFiles: managedFiles
        )
        self.importer = importer
        self.calibreImporter = CalibreImportService(
            modelContext: modelContext,
            settings: settings,
            metadata: metadata,
            wishlist: wishlist,
            toasts: toasts,
            editions: editions,
            mutations: mutations,
            managedFiles: managedFiles
        )
        self.conversion = ConversionService(
            modelContext: modelContext,
            toasts: toasts,
            mutations: mutations,
            managedFiles: managedFiles
        )
        self.highlights = HighlightsService(
            modelContext: modelContext,
            mutations: mutations
        )
        self.exporter = ExportService(modelContext: modelContext)
        self.covers = CoverService(
            modelContext: modelContext,
            mutations: mutations,
            managedFiles: managedFiles
        )
        self.health = LibraryHealthService(
            modelContext: modelContext,
            analysisCoordinator: mutations.analysisCoordinator,
            mutations: mutations,
            managedFiles: managedFiles
        )
        self.maintenance = MaintenanceScheduler(
            context: modelContext,
            mutations: mutations,
            managedFiles: managedFiles,
            importer: importer,
            editions: editions,
            settings: settings,
            toasts: toasts
        )
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
    var isCancellingCalibreImport: Bool { calibreImporter.isCancelling }
    var calibreImportSummary: String? { calibreImporter.summary }
    var calibreImportSummaryStyle: CalibreImportSummaryStyle { calibreImporter.summaryStyle }
    var calibreImportProgressText: String? { calibreImporter.progressText }
    var calibreImportFraction: Double? { calibreImporter.progressFraction }
    var isImportingHighlights: Bool { highlights.isImportingHighlights }
    var highlightImportSummary: String? { highlights.highlightImportSummary }
    var isExporting: Bool { exporter.isExporting }
    var metadataFetchSummary: String? { metadata.metadataFetchSummary }
    private(set) var activeBulkOperationPlan: BulkOperationPlan?
    private(set) var lastBulkOperationResult: BulkOperationResult?
    @ObservationIgnored private var activeBulkOperationSession: BulkOperationSession?
    private var managedFileProgressByID: [UUID: ManagedFileProgress] = [:]
    private var managedFileOperationOrder: [UUID] = []

    var managedFileProgress: ManagedFileProgress? {
        managedFileOperationOrder.lazy.compactMap { self.managedFileProgressByID[$0] }.first
    }

    var managedFileOperationCount: Int {
        managedFileProgressByID.count
    }

    func isConverting(_ book: Book) -> Bool { conversion.isConverting(book) }

    // MARK: - Add / Remove

    @discardableResult
    func addBooks(
        from urls: [URL],
        completion: ImportService.ImportCompletion? = nil
    ) -> ImportSession? {
        importer.addBooks(from: urls, completion: completion)
    }
    @discardableResult
    func addEditions(from urls: [URL], to work: Work) -> ImportSession? {
        importer.addBooks(from: urls, assigningTo: work)
    }
    func importCalibreLibrary(at root: URL) { calibreImporter.importLibrary(at: root) }
    func cancelCalibreImport() { calibreImporter.cancelImport() }

    @discardableResult
    func addPhysicalBook(_ draft: PhysicalBookDraft) -> Book? {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        func optional(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let author = optional(draft.author)
        let bookID = UUID()
        let workID = UUID()
        let payload = CatalogPhysicalBookPayload(
            bookID: bookID,
            workID: workID,
            title: title,
            author: author,
            publisher: optional(draft.publisher),
            year: optional(draft.year),
            isbn: optional(draft.isbn),
            shelfLocation: optional(draft.shelfLocation),
            notes: optional(draft.notes),
            readingStatus: draft.readingStatus
        )
        switch mutations.execute(.addPhysicalBook(payload)) {
        case .success:
            editions.refreshEditionCounts()
            toasts.success(String(localized: "Added physical book “\(title)”"))
            return try? mutations.book(id: bookID)
        case .failure:
            toasts.error(String(localized: "Couldn’t add the physical book."))
            return nil
        }
    }

    // MARK: - Integrity (forwarded)

    var missingFileUUIDs: Set<UUID> { health.missingFileUUIDs }
    func isMissing(_ book: Book) -> Bool { health.isMissing(book) }
    @discardableResult
    func scanForMissingFiles() async -> Int { await health.scanForMissingFiles() }
    func relink(_ book: Book, from url: URL) async { await health.relink(book, from: url) }

    @discardableResult
    func remove(_ book: Book) async -> BulkOperationResult {
        await removeBooks(bookIDs: [book.uuid])
    }

    func planRemoval(bookIDs: Set<UUID>) async -> BulkOperationPlan {
        let orderedIDs = bookIDs.sorted { $0.uuidString < $1.uuidString }
        let candidates = orderedIDs.map { bookID -> BulkOperationCandidate in
            let targetID = BulkOperationTargetID.catalogBook(bookID)
            guard let book = try? mutations.book(id: bookID),
                  removalSnapshot(for: book) != nil else {
                return .conflict(targetID, reason: .missingTarget)
            }
            return .change(targetID)
        }
        return await BulkOperationPlanner.shared.makePlan(
            operation: .catalogDelete,
            requestedTargetIDs: orderedIDs.map(BulkOperationTargetID.catalogBook),
            candidates: candidates,
            chunkSize: 25
        )
    }

    @discardableResult
    func removeBooks(_ books: [Book]) async -> BulkOperationResult {
        await removeBooks(bookIDs: Set(books.map(\.uuid)))
    }

    @discardableResult
    func removeBooks(bookIDs: Set<UUID>) async -> BulkOperationResult {
        let plan = await planRemoval(bookIDs: bookIDs)
        let result = await runBulkOperation(plan: plan) { [weak self] chunk in
            guard let self else {
                throw BulkOperationDurableError(.executionFailed)
            }
            return try await self.applyRemovalChunk(chunk)
        }
        if result.appliedTargetCount > 0 {
            editions.refreshEditionCounts()
        }
        if !result.warnings.isEmpty {
            toasts.error(String(localized: "Book removal is waiting for file cleanup."))
        }
        reportBulkOperationResult(result)
        return result
    }

    private func applyRemovalChunk(
        _ chunk: BulkOperationChunk
    ) async throws -> BulkOperationChunkOutcome {
        var removals: [RemovedBook] = []
        var conflicts: [BulkOperationConflict] = []
        for targetID in chunk.targetIDs {
            guard let bookID = targetID.catalogBookID else {
                conflicts.append(BulkOperationConflict(
                    targetID: targetID,
                    reason: .invalidTarget
                ))
                continue
            }
            guard let book = try? mutations.book(id: bookID),
                  let removal = removalSnapshot(for: book) else {
                conflicts.append(BulkOperationConflict(
                    targetID: targetID,
                    reason: .missingTarget
                ))
                continue
            }
            removals.append(removal)
        }
        guard !removals.isEmpty else {
            return BulkOperationChunkOutcome(conflicts: conflicts)
        }

        let operationID = UUID()
        let progress = beginManagedFileOperation(id: operationID, intent: .deleteBook)
        defer { endManagedFileOperation(id: operationID) }

        let fileNames = Set(removals.flatMap(\.fileNames))
        let bookIDs = Set(removals.map(\.uuid))
        let cleanup: [ManagedFileCleanup]
        do {
            let references = fileNames.sorted().map(ManagedFileReference.book)
                + removals
                    .map(\.uuid)
                    .sorted { $0.uuidString < $1.uuidString }
                    .map { .cover(bookID: $0) }
            cleanup = try await managedFiles.captureIdentities(of: references).map {
                .file($0, disposition: $0.reference.kind == .book ? .trash : .delete)
            }
        } catch {
            throw BulkOperationDurableError(
                .fileTransaction,
                detail: error.localizedDescription
            )
        }
        let transaction: ManagedFileTransaction
        do {
            transaction = try await managedFiles.prepareCleanup(
                intent: .deleteBook,
                requirement: ManagedFileRequirement(
                    absentBookIDs: bookIDs,
                    unreferencedBookFileNames: fileNames
                ),
                cleanups: cleanup,
                operationID: operationID,
                progress: progress
            )
        } catch {
            throw BulkOperationDurableError(
                .fileTransaction,
                detail: error.localizedDescription
            )
        }

        if Task.isCancelled {
            await managedFiles.abort(transaction)
            throw CancellationError()
        }
        guard removals.allSatisfy(removalSnapshotIsCurrent) else {
            await managedFiles.abort(transaction)
            conflicts.append(contentsOf: removals.map {
                BulkOperationConflict(
                    targetID: .catalogBook($0.uuid),
                    reason: .sourceChanged
                )
            })
            return BulkOperationChunkOutcome(conflicts: conflicts)
        }
        let removalPreimages = removals.compactMap { removal -> (Book, Work?, UUID?)? in
            guard let book = try? mutations.book(id: removal.uuid) else { return nil }
            return (book, book.work, book.work?.preferredEditionUUID)
        }
        guard removalPreimages.count == removals.count else {
            await managedFiles.abort(transaction)
            conflicts.append(contentsOf: removals.map {
                BulkOperationConflict(
                    targetID: .catalogBook($0.uuid),
                    reason: .sourceChanged
                )
            })
            return BulkOperationChunkOutcome(conflicts: conflicts)
        }
        let affectedWorkIDs = Set(removalPreimages.compactMap { $0.1?.uuid })
        do {
            let result = try await mutations.commitFileMutation(
                .removeBooks(bookIDs: Array(bookIDs)),
                transaction: transaction,
                affectedBookIDs: bookIDs,
                affectedWorkIDs: affectedWorkIDs,
                progress: progress,
                revertingOnFailure: {
                    for (book, work, preferredEditionUUID) in removalPreimages {
                        if let work, work.modelContext == nil { modelContext.insert(work) }
                        if book.modelContext == nil { modelContext.insert(book) }
                        book.work = work
                        if let work {
                            work.preferredEditionUUID = preferredEditionUUID
                            if !work.editions.contains(where: { $0 === book }) {
                                work.editions.append(book)
                            }
                        }
                    }
                }
            ) {
                for removal in removals {
                    guard let book = try? mutations.book(id: removal.uuid),
                          removalSnapshot(for: book) == removal else {
                        throw CatalogMutationError.modelNotFound
                    }
                    forget(book)
                }
            }
            removals.forEach(finishRemoval)
            let warnings = result.isFullyPublished
                ? []
                : [BulkOperationWarning(
                    targetIDs: removals.map { .catalogBook($0.uuid) },
                    reason: .publicationPending
                )]
            return BulkOperationChunkOutcome(
                appliedTargetIDs: Set(removals.map { .catalogBook($0.uuid) }),
                conflicts: conflicts,
                warnings: warnings
            )
        } catch {
            throw BulkOperationDurableError(
                .catalogSave,
                detail: error.localizedDescription
            )
        }
    }

    private struct RemovedBook: Equatable {
        let uuid: UUID
        let fileNames: Set<String>
    }

    private func removalSnapshot(for book: Book) -> RemovedBook? {
        guard book.modelContext != nil else { return nil }
        let assetNames = (book.assets.isEmpty ? [book.fileName] : book.assets.map(\.fileName))
            .filter { ManagedLeafName(rawValue: $0) != nil }
        return RemovedBook(uuid: book.uuid, fileNames: Set(assetNames))
    }

    private func removalSnapshotIsCurrent(_ removal: RemovedBook) -> Bool {
        guard let book = try? mutations.book(id: removal.uuid) else { return false }
        return removalSnapshot(for: book) == removal
    }

    private func forget(_ book: Book) {
        let work = book.work
        book.work = nil
        modelContext.delete(book)
        WorkService.pruneIfOrphaned(work, context: modelContext)
    }

    private func finishRemoval(_ removed: RemovedBook) {
        importer.cancelPending(removed.uuid)
        editions.removeProposals(referencing: removed.uuid)
    }

    func recoverManagedFiles() async -> ManagedFileRecoveryReport {
        await mutations.recoverManagedFiles()
    }

    func migrateLegacyLibraryIfNeeded() async -> Bool {
        await LegacyLibraryMigrator.migrateIfNeeded(
            context: modelContext,
            mutations: mutations,
            managedFiles: managedFiles
        )
    }

    // MARK: - Metadata (forwarded)

    @discardableResult
    func updateMetadata(
        for book: Book,
        title: String?, author: String?, publisher: String?, year: String?,
        series: String?, seriesIndex: String?, language: String?, translator: String?, isbn: String?,
        description: String?, tags: [String], shelfLocation: String?,
        identityScope: EditionIdentityScope = .editionOnly
    ) -> Bool {
        reportMutationResult(metadata.updateMetadata(
            for: book, title: title, author: author, publisher: publisher, year: year,
            series: series, seriesIndex: seriesIndex, language: language, translator: translator, isbn: isbn,
            description: description, tags: tags, shelfLocation: shelfLocation,
            identityScope: identityScope
        ))
    }
    @discardableResult
    func updateRating(for book: Book, rating: Int?) -> Bool {
        reportMutationResult(metadata.updateRating(for: book, rating: rating))
    }
    @discardableResult
    func updateNotes(_ notes: String, for book: Book) -> Bool {
        reportMutationResult(metadata.updateNotes(notes, for: book))
    }
    func planBulkUpdate(
        bookIDs: Set<UUID>,
        edit: BulkEdit
    ) async -> BulkOperationPlan {
        await metadata.planBulkUpdate(bookIDs: bookIDs, edit: edit)
    }

    @discardableResult
    func bulkUpdate(
        bookIDs: Set<UUID>,
        edit: BulkEdit
    ) async -> BulkOperationResult {
        let plan = await metadata.planBulkUpdate(bookIDs: bookIDs, edit: edit)
        let result = await runBulkOperation(plan: plan) { [metadata] chunk in
            try metadata.applyBulkUpdateChunk(chunk, edit: edit)
        }
        reportBulkOperationResult(result)
        return result
    }

    @discardableResult
    func bulkUpdate(
        _ books: [Book],
        _ edit: BulkEdit
    ) async -> BulkOperationResult {
        await bulkUpdate(bookIDs: Set(books.map(\.uuid)), edit: edit)
    }
    @discardableResult
    func renameTag(_ old: String, to new: String) -> Bool {
        reportMutationResult(metadata.renameTag(old, to: new))
    }
    @discardableResult
    func deleteTag(_ tag: String) -> Bool {
        reportMutationResult(metadata.deleteTag(tag))
    }
    @discardableResult
    func renameSeries(_ old: String, to new: String) -> Bool {
        reportMutationResult(metadata.renameSeries(old, to: new))
    }
    @discardableResult
    func renameAuthor(_ old: String, to new: String) -> Bool {
        reportMutationResult(metadata.renameAuthor(old, to: new))
    }
    @discardableResult
    func applyMetadataFix(_ fix: MetadataFix) -> Bool {
        reportMutationResult(metadata.applyMetadataFix(fix))
    }
    @discardableResult
    func applyMetadataFixes(_ fixes: [MetadataFix]) -> Bool {
        reportMutationResult(metadata.applyMetadataFixes(fixes))
    }
    func backfillPageCount(for book: Book) async { await metadata.backfillPageCount(for: book) }
    @discardableResult
    func markNotSample(_ book: Book) -> Bool {
        reportMutationResult(metadata.markNotSample(book))
    }
    func fetchOnlineMetadata(for book: Book) { metadata.fetchOnlineMetadata(for: book) }
    func fetchOnlineMetadata(for books: [Book]) { metadata.fetchOnlineMetadata(for: books) }
    func backfillOnlineMetadata() async { await metadata.backfillMissingOnlineMetadata() }
    func cancelOnlineMetadataJobs() { metadata.cancelOnlineMetadataJobs() }
    func cancelLongRunningSessions() {
        importer.cancelAllSessions()
        metadata.cancelOnlineMetadataJobs()
        cancelBulkOperation()
    }

    // MARK: - Convert (forwarded)

    func convert(_ book: Book) { conversion.convert(book) }
    func convert(_ book: Book, to format: EbookConverter.OutputFormat) { conversion.convert(book, to: format) }
    func convertBooks(_ books: [Book]) { conversion.convertBooks(books) }
    func convertBooks(_ books: [Book], to format: EbookConverter.OutputFormat) { conversion.convertBooks(books, to: format) }

    // MARK: - Highlights / Export / Covers (forwarded)

    func importHighlights(via monitor: DeviceMonitor) { highlights.importHighlights(via: monitor) }
    func exportLibrary(to folder: URL) { exporter.exportLibrary(to: folder) }
    func setCustomCover(for book: Book, from url: URL) { covers.setCustomCover(for: book, from: url) }
    func setCustomCover(for book: Book, from data: Data) { covers.setCustomCover(for: book, from: data) }
    func resetCover(for book: Book) { covers.resetCover(for: book) }
    func metadataFixes() async -> [MetadataFix] { await health.metadataFixes() }
    func seriesSuggestions() async -> [String] { await health.seriesSuggestions() }

    // MARK: - Maintenance (forwarded)

    func backfillMissingSizes() async { await importer.backfillMissingSizes() }
    func rescanMissingMetadata() async { await importer.rescanMissingMetadata() }
    func detectMissingDRM() async { await importer.detectMissingDRM() }
    func backfillMissingAssetHashes() async {
        await BookAssetMaintenance.backfillMissingHashes(
            context: modelContext,
            mutations: mutations
        )
    }

    @discardableResult
    func adoptConversionArtifact(
        for bookUUID: UUID,
        from url: URL
    ) async -> ConversionArtifactAdoptionResult {
        let operationID = UUID()
        let progress = beginManagedFileOperation(id: operationID, intent: .conversionOutput)
        defer { endManagedFileOperation(id: operationID) }
        return await conversion.adoptArtifact(
            for: bookUUID,
            from: url,
            operationID: operationID,
            progress: progress
        )
    }

    @discardableResult
    func addFile(to book: Book, from url: URL, origin: AssetOrigin = .imported) async -> BookAsset? {
        let shouldBecomePrimary = !book.hasCatalogDigitalFile
        let bookID = book.uuid
        let originalPrimaryName = book.fileName
        let originalPrimaryAssetUUID = book.primaryAssetUUID
        let originalFileSize = book.fileSizeBytes
        let originalDRMProtected = book.drmProtected
        let originalCoverVersion = book.coverVersion
        let assetID = UUID()
        guard let source = try? ManagedFileSource.book(
            sourceURL: url,
            destination: .newAsset(assetID: assetID)
        ) else { return nil }
        let fileName = source.finalRelativeName
        let expectedCoverVersion = shouldBecomePrimary ? originalCoverVersion + 1 : originalCoverVersion
        let operationID = UUID()
        let progress = beginManagedFileOperation(id: operationID, intent: .importBook)
        defer { endManagedFileOperation(id: operationID) }
        let transaction: ManagedFileTransaction
        do {
            transaction = try await managedFiles.stage(
                intent: .importBook,
                sources: [source],
                requirement: ManagedFileRequirement(
                    presentBookIDs: [bookID],
                    referencedBookFileNames: [fileName],
                    coverVersions: shouldBecomePrimary ? [bookID: expectedCoverVersion] : [:]
                ),
                operationID: operationID,
                progress: progress
            )
        } catch {
            return nil
        }

        guard let liveBook = try? mutations.book(id: bookID),
              liveBook.fileName == originalPrimaryName,
              liveBook.primaryAssetUUID == originalPrimaryAssetUUID,
              liveBook.coverVersion == originalCoverVersion else {
            await managedFiles.abort(transaction)
            return nil
        }
        let staged = transaction.files[0]
        let drmProtected = await Task.detached(priority: .utility) {
            DRMDetector.isProtected(url: staged.stagedURL)
        }.value
        if let existing = liveBook.assets.first(where: { $0.contentHash == staged.sha256 }) {
            await managedFiles.abort(transaction)
            return existing
        }

        var insertedAsset: BookAsset?
        do {
            let result = try await mutations.commitFileMutation(
                .addFile(bookID: bookID, assetID: assetID),
                transaction: transaction,
                affectedBookIDs: [bookID],
                progress: progress,
                revertingOnFailure: {
                    liveBook.fileName = originalPrimaryName
                    liveBook.primaryAssetUUID = originalPrimaryAssetUUID
                    liveBook.fileSizeBytes = originalFileSize
                    liveBook.drmProtected = originalDRMProtected
                    liveBook.coverVersion = originalCoverVersion
                    if let insertedAsset {
                        liveBook.assets.removeAll { $0 === insertedAsset }
                        if insertedAsset.modelContext != nil {
                            modelContext.delete(insertedAsset)
                        }
                    }
                }
            ) {
                let liveBook = try mutations.book(id: bookID)
                guard liveBook.fileName == originalPrimaryName,
                      liveBook.primaryAssetUUID == originalPrimaryAssetUUID,
                      liveBook.coverVersion == originalCoverVersion,
                      !liveBook.assets.contains(where: { $0.contentHash == staged.sha256 }) else {
                    throw CatalogMutationError.modelNotFound
                }
                let asset = BookAsset(
                    uuid: assetID,
                    fileName: fileName,
                    origin: origin,
                    sourceProvenance: .manualFile,
                    contentHash: staged.sha256,
                    sizeBytes: staged.byteCount,
                    drmProtected: drmProtected,
                    validationStatus: .ok,
                    book: liveBook
                )
                modelContext.insert(asset)
                if shouldBecomePrimary {
                    liveBook.primaryAssetUUID = assetID
                    liveBook.fileName = fileName
                    liveBook.fileSizeBytes = asset.sizeBytes
                    liveBook.drmProtected = asset.drmProtected
                    liveBook.coverVersion = expectedCoverVersion
                }
                insertedAsset = asset
            }
            guard result.isFullyPublished else {
                toasts.error(String(localized: "Added file is waiting for recovery."))
                return nil
            }
            return insertedAsset
        } catch {
            return nil
        }
    }

    func replace(_ asset: BookAsset, in book: Book, from url: URL) async {
        guard asset.modelContext != nil, book.modelContext != nil,
              asset.book?.uuid == book.uuid else { return }
        let bookID = book.uuid
        let assetID = asset.uuid
        let oldName = asset.fileName
        let oldDateAdded = asset.dateAdded
        let originalCoverVersion = book.coverVersion
        let originalBookFileName = book.fileName
        let originalPrimaryAssetUUID = book.primaryAssetUUID
        let originalBookFileSize = book.fileSizeBytes
        let originalDRMProtected = book.drmProtected
        let wasPrimary = book.primaryAsset?.uuid == assetID
        let previousIdentity: ManagedFileIdentitySnapshot
        do {
            previousIdentity = try await managedFiles.captureIdentity(
                of: .book(oldName)
            )
        } catch {
            return
        }
        guard let source = try? ManagedFileSource.book(
            sourceURL: url,
            destination: .replacement(assetID: assetID, previous: previousIdentity)
        ) else { return }
        let fileName = source.finalRelativeName
        let expectedCoverVersion = wasPrimary ? originalCoverVersion + 1 : originalCoverVersion
        let operationID = UUID()
        let progress = beginManagedFileOperation(id: operationID, intent: .replaceBookFile)
        defer { endManagedFileOperation(id: operationID) }
        let transaction: ManagedFileTransaction
        do {
            transaction = try await managedFiles.stage(
                intent: .replaceBookFile,
                sources: [source],
                requirement: ManagedFileRequirement(
                    presentBookIDs: [bookID],
                    referencedBookFileNames: [fileName],
                    unreferencedBookFileNames: [oldName],
                    coverVersions: wasPrimary ? [bookID: expectedCoverVersion] : [:]
                ),
                cleanups: [.file(previousIdentity)],
                operationID: operationID,
                progress: progress
            )
        } catch {
            return
        }
        let staged = transaction.files[0]
        let drmProtected = await Task.detached(priority: .utility) {
            DRMDetector.isProtected(url: staged.stagedURL)
        }.value
        guard let liveBook = try? mutations.book(id: bookID),
              liveBook.coverVersion == originalCoverVersion,
              let liveAsset = liveBook.assets.first(where: { $0.uuid == assetID }),
              liveAsset.fileName == oldName,
              liveAsset.dateAdded == oldDateAdded else {
            await managedFiles.abort(transaction)
            return
        }
        let oldSize = liveAsset.sizeBytes
        let oldFormatRaw = liveAsset.formatRaw
        let oldHash = liveAsset.contentHash
        let oldGeneratedFromHash = liveAsset.generatedFromContentHash
        let oldOrigin = liveAsset.origin
        let oldSourceProvenanceRaw = liveAsset.sourceProvenanceRaw
        let oldSourceIdentifier = liveAsset.sourceIdentifier
        let oldDRMProtected = liveAsset.drmProtected
        let oldValidation = liveAsset.validationStatus
        let oldAvailabilityRaw = liveAsset.availabilityRaw
        let replacementDate = Date()
        do {
            let result = try await mutations.commitFileMutation(
                .replaceFile(bookID: bookID, assetID: assetID),
                transaction: transaction,
                affectedBookIDs: [bookID],
                progress: progress,
                revertingOnFailure: {
                    liveAsset.fileName = oldName
                    liveAsset.sizeBytes = oldSize
                    liveAsset.formatRaw = oldFormatRaw
                    liveAsset.contentHash = oldHash
                    liveAsset.generatedFromContentHash = oldGeneratedFromHash
                    liveAsset.origin = oldOrigin
                    liveAsset.sourceProvenanceRaw = oldSourceProvenanceRaw
                    liveAsset.sourceIdentifier = oldSourceIdentifier
                    liveAsset.drmProtected = oldDRMProtected
                    liveAsset.validationStatus = oldValidation
                    liveAsset.availabilityRaw = oldAvailabilityRaw
                    liveAsset.dateAdded = oldDateAdded
                    liveBook.fileName = originalBookFileName
                    liveBook.primaryAssetUUID = originalPrimaryAssetUUID
                    liveBook.fileSizeBytes = originalBookFileSize
                    liveBook.drmProtected = originalDRMProtected
                    liveBook.coverVersion = originalCoverVersion
                }
            ) {
                let liveBook = try mutations.book(id: bookID)
                guard liveBook.coverVersion == originalCoverVersion,
                      let liveAsset = liveBook.assets.first(where: { $0.uuid == assetID }),
                      liveAsset.fileName == oldName,
                      liveAsset.dateAdded == oldDateAdded else {
                    throw CatalogMutationError.modelNotFound
                }
                let liveAssetWasPrimary = liveBook.primaryAsset?.uuid == assetID
                guard liveAssetWasPrimary == wasPrimary else {
                    throw CatalogMutationError.modelNotFound
                }
                liveAsset.fileName = fileName
                liveAsset.sizeBytes = staged.byteCount
                liveAsset.contentHash = staged.sha256
                liveAsset.generatedFromContentHash = nil
                liveAsset.origin = .imported
                liveAsset.sourceProvenance = .manualFile
                liveAsset.sourceIdentifier = nil
                liveAsset.drmProtected = drmProtected
                liveAsset.validationStatus = .ok
                liveAsset.availability = .available
                liveAsset.dateAdded = replacementDate
                if wasPrimary {
                    liveBook.primaryAssetUUID = assetID
                    liveBook.fileName = fileName
                    liveBook.fileSizeBytes = staged.byteCount
                    liveBook.drmProtected = drmProtected
                    liveBook.coverVersion = expectedCoverVersion
                }
            }
            if !result.isFullyPublished {
                toasts.error(String(localized: "Replacement file is waiting for recovery."))
            }
        } catch {
            return
        }
    }

    func makePrimary(_ asset: BookAsset, for book: Book) async {
        guard asset.book?.uuid == book.uuid,
              asset.isUsable else { return }
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
              asset.isUsable else { return }
        let bookPreimage = CatalogBookMetadataPreimage(book)
        let assetPreimage = CatalogBookAssetPreimage(asset)
        do {
            try mutations.commit(
                .selectPrimaryAsset(bookID: book.uuid, assetID: asset.uuid),
                affectedBookIDs: [book.uuid],
                revertingOnFailure: {
                    bookPreimage.restore()
                    assetPreimage.restore()
                }
            ) {
                let storedBook = try mutations.book(id: book.uuid)
                guard let storedAsset = storedBook.assets.first(where: { $0.uuid == asset.uuid }),
                      storedAsset.fileName == assetFileName,
                      storedAsset.dateAdded == assetDateAdded,
                      storedAsset.isUsable else {
                    throw CatalogMutationError.modelNotFound
                }
                if storedAsset.sizeBytes == 0, analysis.1 > 0 {
                    storedAsset.sizeBytes = analysis.1
                }
                storedAsset.drmProtected = analysis.0
                storedBook.primaryAssetUUID = storedAsset.uuid
                storedBook.fileName = storedAsset.fileName
                storedBook.fileSizeBytes = storedAsset.sizeBytes
                storedBook.drmProtected = storedAsset.drmProtected
                storedBook.coverVersion += 1
            }
        } catch {
            return
        }
    }

    @discardableResult
    func removeFile(_ asset: BookAsset, from book: Book) async -> Bool {
        guard asset.book?.uuid == book.uuid,
              book.assets.count > 1,
              asset.uuid != book.primaryAsset?.uuid else { return false }
        let bookID = book.uuid
        let assetID = asset.uuid
        let fileName = asset.fileName
        let dateAdded = asset.dateAdded
        let operationID = UUID()
        let progress = beginManagedFileOperation(id: operationID, intent: .deleteBookFile)
        defer { endManagedFileOperation(id: operationID) }
        let identity: ManagedFileIdentitySnapshot
        do {
            identity = try await managedFiles.captureIdentity(of: .book(fileName))
        } catch {
            return false
        }
        let transaction: ManagedFileTransaction
        do {
            transaction = try await managedFiles.prepareCleanup(
                intent: .deleteBookFile,
                requirement: ManagedFileRequirement(
                    presentBookIDs: [bookID],
                    unreferencedBookFileNames: [fileName]
                ),
                cleanups: [.file(identity)],
                operationID: operationID,
                progress: progress
            )
        } catch {
            return false
        }
        guard let liveBook = try? mutations.book(id: bookID),
              liveBook.assets.count > 1,
              let liveAsset = liveBook.assets.first(where: { $0.uuid == assetID }),
              liveAsset.fileName == fileName,
              liveAsset.dateAdded == dateAdded,
              liveBook.primaryAsset?.uuid != assetID else {
            await managedFiles.abort(transaction)
            return false
        }
        do {
            let result = try await mutations.commitFileMutation(
                .removeFile(bookID: bookID, assetID: assetID),
                transaction: transaction,
                affectedBookIDs: [bookID],
                progress: progress,
                revertingOnFailure: {
                    if liveAsset.modelContext == nil { modelContext.insert(liveAsset) }
                    liveAsset.book = liveBook
                    if !liveBook.assets.contains(where: { $0 === liveAsset }) {
                        liveBook.assets.append(liveAsset)
                    }
                }
            ) {
                let liveBook = try mutations.book(id: bookID)
                guard liveBook.assets.count > 1,
                      let liveAsset = liveBook.assets.first(where: { $0.uuid == assetID }),
                      liveAsset.fileName == fileName,
                      liveAsset.dateAdded == dateAdded,
                      liveBook.primaryAsset?.uuid != assetID else {
                    throw CatalogMutationError.modelNotFound
                }
                modelContext.delete(liveAsset)
            }
            if !result.isFullyPublished {
                toasts.error(String(localized: "File removal is waiting for cleanup."))
            }
            return result.isFullyPublished
        } catch {
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
        _ = mutations.execute(.updateAssetValidations([
            CatalogAssetValidationUpdate(
                assetID: asset.uuid,
                expectedFileName: fileName,
                expectedDateAdded: dateAdded,
                validation: status
            ),
        ]))
    }

    // MARK: - Reading status

    func planReadingStatus(
        _ status: ReadingStatus,
        bookIDs: Set<UUID>
    ) async -> BulkOperationPlan {
        let orderedIDs = bookIDs.sorted { $0.uuidString < $1.uuidString }
        let candidates = orderedIDs.map { bookID -> BulkOperationCandidate in
            let targetID = BulkOperationTargetID.catalogBook(bookID)
            guard let book = try? mutations.book(id: bookID) else {
                return .conflict(targetID, reason: .missingTarget)
            }
            return book.readingStatus == status
                ? .unchanged(targetID)
                : .change(targetID)
        }
        return await BulkOperationPlanner.shared.makePlan(
            operation: .metadataEdit,
            requestedTargetIDs: orderedIDs.map(BulkOperationTargetID.catalogBook),
            candidates: candidates,
            chunkSize: 200
        )
    }

    @discardableResult
    func setReadingStatus(
        _ status: ReadingStatus,
        bookIDs: Set<UUID>
    ) async -> BulkOperationResult {
        let plan = await planReadingStatus(status, bookIDs: bookIDs)
        let result = await runBulkOperation(plan: plan) { [weak self] chunk in
            guard let self else {
                throw BulkOperationDurableError(.executionFailed)
            }
            var applicable: Set<UUID> = []
            var unchanged: Set<BulkOperationTargetID> = []
            var conflicts: [BulkOperationConflict] = []
            for targetID in chunk.targetIDs {
                guard let bookID = targetID.catalogBookID else {
                    conflicts.append(BulkOperationConflict(
                        targetID: targetID,
                        reason: .invalidTarget
                    ))
                    continue
                }
                guard let book = try? self.mutations.book(id: bookID) else {
                    conflicts.append(BulkOperationConflict(
                        targetID: targetID,
                        reason: .missingTarget
                    ))
                    continue
                }
                if book.readingStatus == status {
                    unchanged.insert(targetID)
                } else {
                    applicable.insert(bookID)
                }
            }
            guard !applicable.isEmpty else {
                return BulkOperationChunkOutcome(
                    unchangedTargetIDs: unchanged,
                    conflicts: conflicts
                )
            }
            switch self.mutations.execute(
                .setReadingStatus(bookIDs: applicable, status: status)
            ) {
            case .success:
                return BulkOperationChunkOutcome(
                    appliedTargetIDs: Set(applicable.map {
                        BulkOperationTargetID.catalogBook($0)
                    }),
                    unchangedTargetIDs: unchanged,
                    conflicts: conflicts
                )
            case .failure(let error):
                throw BulkOperationDurableError(
                    .catalogSave,
                    detail: String(describing: error)
                )
            }
        }
        if status == .finished {
            let newlyFinished = result.appliedTargetIDs.compactMap {
                $0.catalogBookID.flatMap { try? mutations.book(id: $0) }
            }
            notices.booksDidFinish(newlyFinished)
        }
        reportBulkOperationResult(result)
        return result
    }

    @discardableResult
    func setReadingStatus(_ status: ReadingStatus, for books: [Book]) -> Bool {
        let ids = Set(books.map(\.uuid))
        guard !ids.isEmpty else { return true }
        let newlyFinishedIDs = status == .finished
            ? Set(books.filter { $0.readingStatus != .finished }.map(\.uuid))
            : []
        switch mutations.execute(.setReadingStatus(bookIDs: ids, status: status)) {
        case .success:
            let newlyFinished = books.filter { newlyFinishedIDs.contains($0.uuid) }
            notices.booksDidFinish(newlyFinished)
            return true
        case .failure:
            return reportMutationResult(false)
        }
    }

    @discardableResult
    func updateReadingProgress(_ progress: Double, for book: Book) -> Bool {
        guard book.activeReadingSession != nil else { return false }
        let bookID = book.uuid
        switch mutations.execute(.setReadingProgress(bookID: bookID, progress: progress)) {
        case .success:
            return true
        case .failure:
            return reportMutationResult(false)
        }
    }

    // MARK: - Collections

    @discardableResult
    func createCollection(
        named name: String,
        adding books: [Book] = [],
        savedSearch: String? = nil
    ) -> BookCollection? {
        let collectionID = UUID()
        let bookIDs = Set(books.map(\.uuid))
        let request = CatalogCollectionCreation(
            collectionID: collectionID,
            name: name,
            savedSearch: savedSearch,
            smartShelf: nil,
            bookIDs: bookIDs
        )
        switch mutations.execute(.createCollection(request)) {
        case .success:
            return try? mutations.collection(id: collectionID)
        case .failure:
            _ = reportMutationResult(false)
            return nil
        }
    }

    @discardableResult
    func createSmartShelf(named name: String, definition: SmartShelfDefinition) -> BookCollection? {
        let collectionID = UUID()
        let request = CatalogCollectionCreation(
            collectionID: collectionID,
            name: name,
            savedSearch: nil,
            smartShelf: definition,
            bookIDs: []
        )
        switch mutations.execute(.createCollection(request)) {
        case .success:
            return try? mutations.collection(id: collectionID)
        case .failure:
            _ = reportMutationResult(false)
            return nil
        }
    }

    @discardableResult
    func updateSmartShelf(
        _ collection: BookCollection,
        name: String,
        definition: SmartShelfDefinition
    ) -> Bool {
        guard !collection.isSystem else { return false }
        return reportMutationResult(mutations.execute(.updateSmartShelf(
            collectionID: collection.id,
            name: name,
            definition: definition
        )))
    }

    @discardableResult
    func renameCollection(_ collection: BookCollection, to name: String) -> Bool {
        guard !collection.isSystem else { return false }
        return reportMutationResult(mutations.execute(.renameCollection(
            collectionID: collection.id,
            name: name
        )))
    }

    @discardableResult
    func deleteCollection(_ collection: BookCollection) -> Bool {
        guard !collection.isSystem else { return false }
        let collectionID = collection.id
        return reportMutationResult(mutations.execute(.deleteCollection(
            collectionID: collectionID
        )))
    }

    func planCollectionChange(
        bookIDs: Set<UUID>,
        collectionID: UUID,
        adding: Bool
    ) async -> BulkOperationPlan {
        let orderedIDs = bookIDs.sorted { $0.uuidString < $1.uuidString }
        let collection = try? mutations.collection(id: collectionID)
        let collectionIsValid = collection?.isSystem == false && collection?.isSmart == false
        let memberIDs = Set(collection?.books.map(\.uuid) ?? [])
        let candidates = orderedIDs.map { bookID -> BulkOperationCandidate in
            let targetID = BulkOperationTargetID.catalogBook(bookID)
            guard collectionIsValid else {
                return .conflict(targetID, reason: .invalidTarget)
            }
            guard (try? mutations.book(id: bookID)) != nil else {
                return .conflict(targetID, reason: .missingTarget)
            }
            let isMember = memberIDs.contains(bookID)
            return adding == isMember ? .unchanged(targetID) : .change(targetID)
        }
        return await BulkOperationPlanner.shared.makePlan(
            operation: adding ? .collectionAdd : .collectionRemove,
            requestedTargetIDs: orderedIDs.map(BulkOperationTargetID.catalogBook),
            candidates: candidates,
            chunkSize: 200
        )
    }

    @discardableResult
    func add(
        _ books: [Book],
        to collection: BookCollection
    ) async -> BulkOperationResult {
        await add(bookIDs: Set(books.map(\.uuid)), to: collection)
    }

    @discardableResult
    func add(
        bookIDs: Set<UUID>,
        to collection: BookCollection
    ) async -> BulkOperationResult {
        await changeCollection(
            bookIDs: bookIDs,
            collectionID: collection.id,
            adding: true
        )
    }

    @discardableResult
    func remove(
        _ books: [Book],
        from collection: BookCollection
    ) async -> BulkOperationResult {
        await remove(bookIDs: Set(books.map(\.uuid)), from: collection)
    }

    @discardableResult
    func remove(
        bookIDs: Set<UUID>,
        from collection: BookCollection
    ) async -> BulkOperationResult {
        await changeCollection(
            bookIDs: bookIDs,
            collectionID: collection.id,
            adding: false
        )
    }

    private func changeCollection(
        bookIDs: Set<UUID>,
        collectionID: UUID,
        adding: Bool
    ) async -> BulkOperationResult {
        let plan = await planCollectionChange(
            bookIDs: bookIDs,
            collectionID: collectionID,
            adding: adding
        )
        let result = await runBulkOperation(plan: plan) { [weak self] chunk in
            guard let self else {
                throw BulkOperationDurableError(.executionFailed)
            }
            return try self.applyCollectionChunk(
                chunk,
                collectionID: collectionID,
                adding: adding
            )
        }
        reportBulkOperationResult(result)
        return result
    }

    private func applyCollectionChunk(
        _ chunk: BulkOperationChunk,
        collectionID: UUID,
        adding: Bool
    ) throws -> BulkOperationChunkOutcome {
        guard let collection = try? mutations.collection(id: collectionID),
              !collection.isSystem,
              !collection.isSmart else {
            throw BulkOperationDurableError(
                .executionFailed,
                detail: "Collection is unavailable"
            )
        }

        let memberIDs = Set(collection.books.map(\.uuid))
        var applicableBookIDs: Set<UUID> = []
        var unchanged: Set<BulkOperationTargetID> = []
        var conflicts: [BulkOperationConflict] = []
        for targetID in chunk.targetIDs {
            guard let bookID = targetID.catalogBookID else {
                conflicts.append(BulkOperationConflict(
                    targetID: targetID,
                    reason: .invalidTarget
                ))
                continue
            }
            guard (try? mutations.book(id: bookID)) != nil else {
                conflicts.append(BulkOperationConflict(
                    targetID: targetID,
                    reason: .missingTarget
                ))
                continue
            }
            if adding == memberIDs.contains(bookID) {
                unchanged.insert(targetID)
            } else {
                applicableBookIDs.insert(bookID)
            }
        }

        guard !applicableBookIDs.isEmpty else {
            return BulkOperationChunkOutcome(
                unchangedTargetIDs: unchanged,
                conflicts: conflicts
            )
        }
        let request: CatalogMutationRequest = adding
            ? .addToCollection(collectionID: collectionID, bookIDs: applicableBookIDs)
            : .removeFromCollection(collectionID: collectionID, bookIDs: applicableBookIDs)
        switch mutations.execute(request) {
        case .success:
            return BulkOperationChunkOutcome(
                appliedTargetIDs: Set(applicableBookIDs.map {
                    BulkOperationTargetID.catalogBook($0)
                }),
                unchangedTargetIDs: unchanged,
                conflicts: conflicts
            )
        case .failure(let error):
            throw BulkOperationDurableError(
                .catalogSave,
                detail: String(describing: error)
            )
        }
    }

    private func runBulkOperation(
        plan: BulkOperationPlan,
        applying applyChunk: @escaping @MainActor @Sendable (
            BulkOperationChunk
        ) async throws -> BulkOperationChunkOutcome
    ) async -> BulkOperationResult {
        guard activeBulkOperationSession == nil else {
            let rejected = BulkOperationSession(plan: plan)
            let result = await rejected.execute { _ in
                throw BulkOperationDurableError(.operationInProgress)
            }
            lastBulkOperationResult = result
            return result
        }

        let session = BulkOperationSession(plan: plan)
        activeBulkOperationSession = session
        activeBulkOperationPlan = plan
        let result = await session.execute(applying: applyChunk)
        if activeBulkOperationPlan?.id == plan.id {
            activeBulkOperationSession = nil
            activeBulkOperationPlan = nil
        }
        lastBulkOperationResult = result
        return result
    }

    func cancelBulkOperation() {
        guard let session = activeBulkOperationSession else { return }
        Task { await session.cancel() }
    }

    private func reportBulkOperationResult(_ result: BulkOperationResult) {
        switch result.completion {
        case .failed:
            toasts.error(String(localized: "Couldn’t save all library changes."))
        case .cancelled:
            toasts.info(String(localized: "Bulk operation cancelled."))
        case .completed:
            if result.conflictCount > 0 {
                toasts.info(String(
                    localized: "Bulk operation finished with \(result.conflictCount) conflicts."
                ))
            }
        }
    }

    @discardableResult
    private func reportMutationResult(_ succeeded: Bool) -> Bool {
        if !succeeded {
            toasts.error(String(localized: "Couldn’t save library changes."))
        }
        return succeeded
    }

    @discardableResult
    private func reportMutationResult(
        _ result: Result<CatalogChangeSet, CatalogMutationError>
    ) -> Bool {
        switch result {
        case .success:
            true
        case .failure:
            reportMutationResult(false)
        }
    }

    private func beginManagedFileOperation(
        id: UUID,
        intent: ManagedFileIntent
    ) -> ManagedFileProgressHandler {
        managedFileProgressByID[id] = .initial(transactionID: id, intent: intent)
        managedFileOperationOrder.append(id)
        return { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.managedFileProgressByID[id] != nil else { return }
                self.managedFileProgressByID[id] = update
            }
        }
    }

    private func endManagedFileOperation(id: UUID) {
        managedFileProgressByID.removeValue(forKey: id)
        managedFileOperationOrder.removeAll { $0 == id }
    }
}
