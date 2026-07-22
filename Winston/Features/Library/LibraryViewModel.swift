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
    let editions: EditionService
    let wishlist: WishlistService
    let notices: NoticeService

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
        let editions = EditionService(modelContext: modelContext, mutations: mutations, toasts: toasts)
        self.editions = editions
        self.importer = ImportService(
            modelContext: modelContext,
            settings: settings,
            metadata: metadata,
            wishlist: wishlist,
            toasts: toasts,
            editions: editions,
            mutations: mutations,
            managedFiles: managedFiles
        )
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
        self.highlights = HighlightsService(modelContext: modelContext)
        self.exporter = ExportService(modelContext: modelContext)
        self.covers = CoverService(
            modelContext: modelContext,
            mutations: mutations,
            managedFiles: managedFiles
        )
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

    func addBooks(
        from urls: [URL],
        completion: ImportService.ImportCompletion? = nil
    ) {
        importer.addBooks(from: urls, completion: completion)
    }
    func addEditions(from urls: [URL], to work: Work) { importer.addBooks(from: urls, assigningTo: work) }
    func importCalibreLibrary(at root: URL) { calibreImporter.importLibrary(at: root) }

    @discardableResult
    func addPhysicalBook(_ draft: PhysicalBookDraft) -> Book? {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        func optional(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let author = optional(draft.author)
        let book = Book(fileName: "", originalFileName: title)
        book.title = title
        book.author = author
        book.publisher = optional(draft.publisher)
        book.year = optional(draft.year)
        book.isbn = optional(draft.isbn)
        book.shelfLocation = optional(draft.shelfLocation)
        book.notes = optional(draft.notes)
        book.hasPhysicalCopy = true
        if draft.readingStatus != .unread { book.setStatus(draft.readingStatus) }

        let work = Work(title: title, author: author, dateCreated: book.dateAdded)
        work.preferredEditionUUID = book.uuid
        modelContext.insert(work)
        modelContext.insert(book)
        book.work = work

        do {
            try modelContext.saveAndPublish()
            editions.refreshEditionCounts()
            toasts.success(String(localized: "Added physical book “\(title)”"))
            return book
        } catch {
            modelContext.rollback()
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

    func remove(_ book: Book) async {
        await removeBooks([book])
    }

    func removeBooks(_ books: [Book]) async {
        var seen: Set<UUID> = []
        let removals = books.compactMap { book -> RemovedBook? in
            guard seen.insert(book.uuid).inserted else { return nil }
            return removalSnapshot(for: book)
        }
        guard !removals.isEmpty else { return }

        let fileNames = Set(removals.flatMap(\.fileNames))
        let bookIDs = Set(removals.map(\.uuid))
        let cleanup = fileNames.map {
            ManagedFileCleanup.book($0, disposition: .trash)
        } + removals.map { ManagedFileCleanup.cover(bookID: $0.uuid) }
        let transaction: ManagedFileTransaction
        do {
            transaction = try await managedFiles.prepareCleanup(
                intent: .deleteBook,
                requirement: ManagedFileRequirement(
                    absentBookIDs: bookIDs,
                    unreferencedBookFileNames: fileNames
                ),
                cleanups: cleanup
            )
        } catch {
            toasts.error(String(localized: "Couldn’t remove the selected books."))
            return
        }

        guard removals.allSatisfy(removalSnapshotIsCurrent) else {
            await managedFiles.abort(transaction)
            return
        }
        let removalPreimages = removals.compactMap { removal -> (Book, Work?, UUID?)? in
            guard let book = try? mutations.book(id: removal.uuid) else { return nil }
            return (book, book.work, book.work?.preferredEditionUUID)
        }
        do {
            let result = try await mutations.commitFileMutation(
                .removeBooks(bookIDs: Array(bookIDs)),
                transaction: transaction,
                affectedBookIDs: bookIDs,
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
            if !result.isFullyPublished {
                toasts.error(String(localized: "Book removal is waiting for file cleanup."))
            }
        } catch {
            toasts.error(String(localized: "Couldn’t remove the selected books."))
            return
        }
        editions.refreshEditionCounts()
    }

    private struct RemovedBook: Equatable {
        let uuid: UUID
        let fileNames: Set<String>
    }

    private func removalSnapshot(for book: Book) -> RemovedBook? {
        guard book.modelContext != nil else { return nil }
        let assetNames = (book.assets.isEmpty ? [book.fileName] : book.assets.map(\.fileName))
            .filter { BookFileStore.validatedURL(for: $0) != nil }
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
        WorkService.pruneIfOrphaned(work, context: modelContext, save: false)
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
        description: String?, tags: [String], shelfLocation: String?
    ) -> Bool {
        reportMutationResult(metadata.updateMetadata(
            for: book, title: title, author: author, publisher: publisher, year: year,
            series: series, seriesIndex: seriesIndex, language: language, translator: translator, isbn: isbn,
            description: description, tags: tags, shelfLocation: shelfLocation
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
    @discardableResult
    func bulkUpdate(_ books: [Book], _ edit: BulkEdit) -> Bool {
        reportMutationResult(metadata.bulkUpdate(books, edit))
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
    func setCustomCover(for book: Book, from data: Data) { covers.setCustomCover(for: book, from: data) }
    func resetCover(for book: Book) { covers.resetCover(for: book) }
    func duplicateGroups() async -> [DuplicateGroup] { await health.duplicateGroups() }
    func metadataFixes() async -> [MetadataFix] { await health.metadataFixes() }
    func seriesSuggestions() async -> [String] { await health.seriesSuggestions() }

    // MARK: - Maintenance (forwarded)

    func backfillMissingSizes() async { await importer.backfillMissingSizes() }
    func rescanMissingMetadata() async { await importer.rescanMissingMetadata() }
    func detectMissingDRM() async { await importer.detectMissingDRM() }
    func backfillMissingAssetHashes() async {
        await BookAssetMaintenance.backfillMissingHashes(context: modelContext)
    }

    func adoptConversionArtifact(for bookUUID: UUID, from url: URL) async {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.uuid == bookUUID })
        guard let book = try? modelContext.fetch(descriptor).first,
              book.hasDigitalFile else { return }
        let format = url.pathExtension.lowercased()
        let primary = book.assets.first { $0.fileName == book.fileName }
        let primaryFileName = book.fileName
        let primaryAssetUUID = primary?.uuid
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
        let existing = book.assets.first {
            $0.origin == .generated && $0.format.lowercased() == format
        }
        let assetUUID = existing?.uuid ?? UUID()
        let oldFileName = existing?.fileName
        let oldDateAdded = existing?.dateAdded
        let source: ManagedFileSource
        do {
            source = try .book(sourceURL: url)
        } catch {
            return
        }
        let newFileName = source.finalRelativeName
        let wasPrimary = oldFileName == primaryFileName
        let transaction: ManagedFileTransaction
        do {
            transaction = try await managedFiles.stage(
                intent: .conversionOutput,
                sources: [source],
                requirement: ManagedFileRequirement(
                    presentBookIDs: [bookUUID],
                    referencedBookFileNames: [newFileName],
                    unreferencedBookFileNames: Set(oldFileName.map { [$0] } ?? [])
                ),
                cleanups: oldFileName.map { [.book($0)] } ?? []
            )
        } catch {
            return
        }

        guard let liveBook = try? mutations.book(id: bookUUID),
              liveBook.fileName == primaryFileName,
              liveBook.assets.first(where: { $0.uuid == primaryAssetUUID })?.dateAdded == primaryDateAdded,
              liveBook.assets.first(where: { $0.uuid == assetUUID })?.fileName == oldFileName,
              liveBook.assets.first(where: { $0.uuid == assetUUID })?.dateAdded == oldDateAdded else {
            await managedFiles.abort(transaction)
            return
        }

        let livePrimary = liveBook.assets.first { $0.uuid == primaryAssetUUID }
        let originalPrimaryHash = livePrimary?.contentHash
        let liveExisting = liveBook.assets.first { $0.uuid == assetUUID }
        let oldSize = liveExisting?.sizeBytes
        let oldHash = liveExisting?.contentHash
        let oldGeneratedFromHash = liveExisting?.generatedFromContentHash
        let oldValidation = liveExisting?.validationStatus
        let originalBookSize = liveBook.fileSizeBytes
        let staged = transaction.files[0]
        var insertedAsset: BookAsset?
        do {
            let result = try await mutations.commitFileMutation(
                .conversionOutput(bookID: bookUUID, assetID: assetUUID),
                transaction: transaction,
                affectedBookIDs: [bookUUID],
                revertingOnFailure: {
                    liveBook.fileName = primaryFileName
                    liveBook.fileSizeBytes = originalBookSize
                    livePrimary?.contentHash = originalPrimaryHash
                    if let liveExisting {
                        liveExisting.fileName = oldFileName ?? liveExisting.fileName
                        liveExisting.sizeBytes = oldSize ?? liveExisting.sizeBytes
                        liveExisting.contentHash = oldHash
                        liveExisting.generatedFromContentHash = oldGeneratedFromHash
                        liveExisting.validationStatus = oldValidation
                        liveExisting.dateAdded = oldDateAdded ?? liveExisting.dateAdded
                    }
                    if let insertedAsset {
                        liveBook.assets.removeAll { $0 === insertedAsset }
                        if insertedAsset.modelContext != nil {
                            modelContext.delete(insertedAsset)
                        }
                    }
                }
            ) {
                let liveBook = try mutations.book(id: bookUUID)
                guard liveBook.fileName == primaryFileName,
                      liveBook.assets.first(where: { $0.uuid == primaryAssetUUID })?.dateAdded == primaryDateAdded else {
                    throw CatalogMutationError.modelNotFound
                }
                if let livePrimary = liveBook.assets.first(where: { $0.uuid == primaryAssetUUID }),
                   livePrimary.contentHash == nil {
                    livePrimary.contentHash = sourceHash
                }
                if let liveAsset = liveBook.assets.first(where: { $0.uuid == assetUUID }) {
                    guard liveAsset.fileName == oldFileName,
                          liveAsset.dateAdded == oldDateAdded else {
                        throw CatalogMutationError.modelNotFound
                    }
                    liveAsset.fileName = newFileName
                    liveAsset.sizeBytes = staged.byteCount
                    liveAsset.contentHash = staged.sha256
                    liveAsset.generatedFromContentHash = sourceHash
                    liveAsset.validationStatus = .ok
                    liveAsset.dateAdded = Date()
                } else {
                    guard oldFileName == nil else { throw CatalogMutationError.modelNotFound }
                    let asset = BookAsset(
                        uuid: assetUUID,
                        fileName: newFileName,
                        origin: .generated,
                        contentHash: staged.sha256,
                        generatedFromContentHash: sourceHash,
                        sizeBytes: staged.byteCount,
                        validationStatus: .ok,
                        book: liveBook
                    )
                    modelContext.insert(asset)
                    insertedAsset = asset
                }
                if wasPrimary {
                    liveBook.fileName = newFileName
                    liveBook.fileSizeBytes = staged.byteCount
                }
            }
            if !result.isFullyPublished {
                toasts.error(String(localized: "Converted file is waiting for recovery."))
            }
        } catch {
            return
        }
    }

    @discardableResult
    func addFile(to book: Book, from url: URL, origin: AssetOrigin = .imported) async -> BookAsset? {
        let shouldBecomePrimary = !book.hasDigitalFile
        let bookID = book.uuid
        let originalPrimaryName = book.fileName
        let originalFileSize = book.fileSizeBytes
        let originalDRMProtected = book.drmProtected
        let originalCoverVersion = book.coverVersion
        let assetID = UUID()
        guard let source = try? ManagedFileSource.book(sourceURL: url, fileID: assetID) else { return nil }
        let fileName = source.finalRelativeName
        let expectedCoverVersion = shouldBecomePrimary ? originalCoverVersion + 1 : originalCoverVersion
        let transaction: ManagedFileTransaction
        do {
            transaction = try await managedFiles.stage(
                intent: .importBook,
                sources: [source],
                requirement: ManagedFileRequirement(
                    presentBookIDs: [bookID],
                    referencedBookFileNames: [fileName],
                    coverVersions: shouldBecomePrimary ? [bookID: expectedCoverVersion] : [:]
                )
            )
        } catch {
            return nil
        }

        guard let liveBook = try? mutations.book(id: bookID),
              liveBook.fileName == originalPrimaryName,
              liveBook.coverVersion == originalCoverVersion else {
            await managedFiles.abort(transaction)
            return nil
        }
        let staged = transaction.files[0]
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
                revertingOnFailure: {
                    liveBook.fileName = originalPrimaryName
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
                      liveBook.coverVersion == originalCoverVersion,
                      !liveBook.assets.contains(where: { $0.contentHash == staged.sha256 }) else {
                    throw CatalogMutationError.modelNotFound
                }
                let asset = BookAsset(
                    uuid: assetID,
                    fileName: fileName,
                    origin: origin,
                    contentHash: staged.sha256,
                    sizeBytes: staged.byteCount,
                    validationStatus: .ok,
                    book: liveBook
                )
                modelContext.insert(asset)
                if shouldBecomePrimary {
                    liveBook.fileName = fileName
                    liveBook.fileSizeBytes = asset.sizeBytes
                    liveBook.drmProtected = nil
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
        let originalBookFileSize = book.fileSizeBytes
        let originalDRMProtected = book.drmProtected
        let wasPrimary = book.fileName == oldName
        guard let source = try? ManagedFileSource.book(sourceURL: url) else { return }
        let fileName = source.finalRelativeName
        let expectedCoverVersion = wasPrimary ? originalCoverVersion + 1 : originalCoverVersion
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
                cleanups: [.book(oldName)]
            )
        } catch {
            return
        }
        let staged = transaction.files[0]
        let drmProtected = wasPrimary
            ? await Task.detached(priority: .utility) { DRMDetector.isProtected(url: staged.stagedURL) }.value
            : nil
        guard let liveBook = try? mutations.book(id: bookID),
              liveBook.coverVersion == originalCoverVersion,
              let liveAsset = liveBook.assets.first(where: { $0.uuid == assetID }),
              liveAsset.fileName == oldName,
              liveAsset.dateAdded == oldDateAdded else {
            await managedFiles.abort(transaction)
            return
        }
        let oldSize = liveAsset.sizeBytes
        let oldHash = liveAsset.contentHash
        let oldGeneratedFromHash = liveAsset.generatedFromContentHash
        let oldOrigin = liveAsset.origin
        let oldValidation = liveAsset.validationStatus
        let replacementDate = Date()
        do {
            let result = try await mutations.commitFileMutation(
                .replaceFile(bookID: bookID, assetID: assetID),
                transaction: transaction,
                affectedBookIDs: [bookID],
                revertingOnFailure: {
                    liveAsset.fileName = oldName
                    liveAsset.sizeBytes = oldSize
                    liveAsset.contentHash = oldHash
                    liveAsset.generatedFromContentHash = oldGeneratedFromHash
                    liveAsset.origin = oldOrigin
                    liveAsset.validationStatus = oldValidation
                    liveAsset.dateAdded = oldDateAdded
                    liveBook.fileName = originalBookFileName
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
                liveAsset.fileName = fileName
                liveAsset.sizeBytes = staged.byteCount
                liveAsset.contentHash = staged.sha256
                liveAsset.generatedFromContentHash = nil
                liveAsset.origin = .imported
                liveAsset.validationStatus = .ok
                liveAsset.dateAdded = replacementDate
                if wasPrimary {
                    guard liveBook.fileName == oldName else { throw CatalogMutationError.modelNotFound }
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
    func removeFile(_ asset: BookAsset, from book: Book) async -> Bool {
        guard asset.book?.uuid == book.uuid, book.assets.count > 1, asset.fileName != book.fileName else { return false }
        let bookID = book.uuid
        let assetID = asset.uuid
        let fileName = asset.fileName
        let dateAdded = asset.dateAdded
        let transaction: ManagedFileTransaction
        do {
            transaction = try await managedFiles.prepareCleanup(
                intent: .deleteBookFile,
                requirement: ManagedFileRequirement(
                    presentBookIDs: [bookID],
                    unreferencedBookFileNames: [fileName]
                ),
                cleanups: [.book(fileName)]
            )
        } catch {
            return false
        }
        guard let liveBook = try? mutations.book(id: bookID),
              liveBook.assets.count > 1,
              let liveAsset = liveBook.assets.first(where: { $0.uuid == assetID }),
              liveAsset.fileName == fileName,
              liveAsset.dateAdded == dateAdded,
              liveBook.fileName != fileName else {
            await managedFiles.abort(transaction)
            return false
        }
        do {
            let result = try await mutations.commitFileMutation(
                .removeFile(bookID: bookID, assetID: assetID),
                transaction: transaction,
                affectedBookIDs: [bookID],
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
                      liveBook.fileName != fileName else {
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
        asset.validationStatus = status
        modelContext.saveQuietly()
    }

    // MARK: - Reading status

    @discardableResult
    func setReadingStatus(_ status: ReadingStatus, for books: [Book]) -> Bool {
        let ids = Set(books.map(\.uuid))
        guard !ids.isEmpty else { return true }
        let newlyFinishedIDs = status == .finished
            ? Set(books.filter { $0.readingStatus != .finished }.map(\.uuid))
            : []
        do {
            try mutations.commit(
                .setReadingStatus(bookIDs: Array(ids), status: status),
                affectedBookIDs: ids
            ) {
                for book in try mutations.books(ids: ids) { book.setStatus(status) }
            }
            let newlyFinished = books.filter { newlyFinishedIDs.contains($0.uuid) }
            notices.booksDidFinish(newlyFinished)
            return true
        } catch {
            return reportMutationResult(false)
        }
    }

    @discardableResult
    func updateReadingProgress(_ progress: Double, for book: Book) -> Bool {
        guard book.activeReadingSession != nil else { return false }
        let bookID = book.uuid
        do {
            try mutations.commit(
                .setReadingProgress(bookID: bookID, progress: progress),
                affectedBookIDs: [bookID]
            ) {
                let storedBook = try mutations.book(id: bookID)
                guard storedBook.updateReadingProgress(progress) else {
                    throw CatalogMutationError.modelNotFound
                }
            }
            return true
        } catch {
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
        let collection = BookCollection(name: name, savedSearch: savedSearch)
        let bookIDs = Set(books.map(\.uuid))
        do {
            try mutations.commit(
                .createCollection(collectionID: collection.id, bookIDs: Array(bookIDs)),
                affectedBookIDs: bookIDs,
                affectedCollectionIDs: [collection.id]
            ) {
                collection.books = try mutations.books(ids: bookIDs)
                modelContext.insert(collection)
            }
            return collection
        } catch {
            _ = reportMutationResult(false)
            return nil
        }
    }

    @discardableResult
    func createSmartShelf(named name: String, definition: SmartShelfDefinition) -> BookCollection? {
        let collection = BookCollection(name: name)
        do {
            try mutations.commit(
                .createCollection(collectionID: collection.id, bookIDs: []),
                affectedCollectionIDs: [collection.id]
            ) {
                collection.smartShelfDefinition = definition
                modelContext.insert(collection)
            }
            return collection
        } catch {
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
        let collectionID = collection.id
        return commitCollectionMutation(collectionID: collectionID) { storedCollection in
            storedCollection.name = name
            storedCollection.savedSearch = nil
            storedCollection.smartShelfDefinition = definition
        }
    }

    @discardableResult
    func renameCollection(_ collection: BookCollection, to name: String) -> Bool {
        guard !collection.isSystem else { return false }
        return commitCollectionMutation(collectionID: collection.id) { $0.name = name }
    }

    @discardableResult
    func deleteCollection(_ collection: BookCollection) -> Bool {
        guard !collection.isSystem else { return false }
        let collectionID = collection.id
        do {
            try mutations.commit(
                .deleteCollection(collectionID: collectionID),
                affectedCollectionIDs: [collectionID]
            ) {
                modelContext.delete(try mutations.collection(id: collectionID))
            }
            return true
        } catch {
            return reportMutationResult(false)
        }
    }

    @discardableResult
    func add(_ books: [Book], to collection: BookCollection) -> Bool {
        let bookIDs = Set(books.map(\.uuid))
        return commitCollectionMutation(collectionID: collection.id, bookIDs: bookIDs) { storedCollection in
            for book in try mutations.books(ids: bookIDs)
            where !storedCollection.books.contains(where: { $0.uuid == book.uuid }) {
                storedCollection.books.append(book)
            }
        }
    }

    @discardableResult
    func remove(_ books: [Book], from collection: BookCollection) -> Bool {
        let bookIDs = Set(books.map(\.uuid))
        return commitCollectionMutation(collectionID: collection.id, bookIDs: bookIDs) { storedCollection in
            storedCollection.books.removeAll { bookIDs.contains($0.uuid) }
        }
    }

    private func commitCollectionMutation(
        collectionID: UUID,
        bookIDs: Set<UUID> = [],
        applying mutation: (BookCollection) throws -> Void
    ) -> Bool {
        do {
            try mutations.commit(
                .updateCollection(collectionID: collectionID),
                affectedBookIDs: bookIDs,
                affectedCollectionIDs: [collectionID]
            ) {
                try mutation(mutations.collection(id: collectionID))
            }
            return true
        } catch {
            return reportMutationResult(false)
        }
    }

    @discardableResult
    private func reportMutationResult(_ succeeded: Bool) -> Bool {
        if !succeeded {
            toasts.error(String(localized: "Couldn’t save library changes."))
        }
        return succeeded
    }
}
