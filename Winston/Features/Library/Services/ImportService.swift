import Foundation
import SwiftData

nonisolated struct ImportBookAnalysis: Sendable {
    let metadata: BookMetadata
    let drmProtected: Bool
    let validation: AssetValidation

    init(
        metadata: BookMetadata,
        drmProtected: Bool,
        validation: AssetValidation = .ok
    ) {
        self.metadata = metadata
        self.drmProtected = drmProtected
        self.validation = validation
    }
}

@MainActor
@Observable
final class ImportService {
    typealias ImportCompletion = @MainActor ([Book]) -> Void

    private struct MatchBatch {
        let books: [Book]
        var remaining: Set<UUID>
    }

    private struct MetadataJob {
        let book: Book
        let evaluateMatch: Bool
        let matchBatchID: UUID?
    }

    nonisolated private struct CopyRequest: Sendable {
        let source: URL
        let uuid: UUID
        let originalName: String
    }

    private enum ManagedImportResult {
        case imported(Book, contentHash: String)
        case duplicate
        case pending(contentHash: String)
        case targetUnavailable
    }

    nonisolated private struct MaintenanceCandidate: Sendable {
        let uuid: UUID
        let fileName: String
    }

    private let modelContext: ModelContext
    private let settings: AppSettings
    private let metadata: MetadataService
    private let wishlist: WishlistService
    private let toasts: ToastCenter
    private let editions: EditionService?
    private let mutations: CatalogMutationService
    private let managedFiles: ManagedFileCoordinator
    private let analyzeBook: @Sendable (URL) async -> ImportBookAnalysis
    private let maximumConcurrentMetadataJobs: Int

    private(set) var pendingMetadataUUIDs: Set<UUID> = []
    private var pendingSourcePaths: Set<String> = []
    private var matchBatches: [UUID: MatchBatch] = [:]
    private var queuedMetadataJobs: ArraySlice<MetadataJob> = []
    private var activeMetadataTasks: [UUID: Task<Void, Never>] = [:]

    init(
        modelContext: ModelContext,
        settings: AppSettings,
        metadata: MetadataService,
        wishlist: WishlistService,
        toasts: ToastCenter,
        editions: EditionService? = nil,
        mutations: CatalogMutationService? = nil,
        managedFiles: ManagedFileCoordinator = .shared,
        maximumConcurrentMetadataJobs: Int = BookDoctorService.defaultMaximumConcurrentInspections,
        analyzeBook: @escaping @Sendable (URL) async -> ImportBookAnalysis = ImportService.defaultAnalysis
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
        self.maximumConcurrentMetadataJobs = max(1, maximumConcurrentMetadataJobs)
        self.analyzeBook = analyzeBook
    }

    var isExtracting: Bool { !pendingMetadataUUIDs.isEmpty }
    var pendingMetadataCount: Int { pendingMetadataUUIDs.count }
    var activeMetadataJobCount: Int { activeMetadataTasks.count }

    func addBooks(from urls: [URL], completion: ImportCompletion? = nil) {
        addBooks(from: urls, assigningTo: nil, completion: completion)
    }

    func addBooks(
        from urls: [URL],
        assigningTo targetWork: Work?,
        completion: ImportCompletion? = nil
    ) {
        var requests: [CopyRequest] = []
        var failed = 0
        for url in urls {
            guard libraryEbookExtensions.contains(url.pathExtension.lowercased()) else { failed += 1; continue }

            let originalName = url.lastPathComponent
            let sourcePath = url.standardizedFileURL.path(percentEncoded: false)
            guard pendingSourcePaths.insert(sourcePath).inserted else { continue }
            requests.append(CopyRequest(source: url, uuid: UUID(), originalName: originalName))
        }

        guard !requests.isEmpty else {
            reportImportFailures(failed)
            completion?([])
            return
        }

        let validationFailures = failed
        Task { [weak self, requests] in
            guard let self else {
                completion?([])
                return
            }

            var imported: [Book] = []
            var failureCount = validationFailures
            var pendingRecoveryCount = 0
            var knownHashes: Set<String> = targetWork == nil ? [] : Set(
                ((try? modelContext.fetch(FetchDescriptor<BookAsset>())) ?? [])
                    .compactMap(\.contentHash)
            )

            for (index, request) in requests.enumerated() {
                let sourcePath = request.source.standardizedFileURL.path(percentEncoded: false)
                defer { pendingSourcePaths.remove(sourcePath) }
                do {
                    switch try await importOne(
                        request,
                        assigningTo: targetWork,
                        knownHashes: knownHashes
                    ) {
                    case .imported(let book, let contentHash):
                        imported.append(book)
                        knownHashes.insert(contentHash)
                    case .pending(let contentHash):
                        knownHashes.insert(contentHash)
                        pendingRecoveryCount += 1
                    case .duplicate:
                        break
                    case .targetUnavailable:
                        failureCount += requests.count - index
                        break
                    }
                } catch {
                    failureCount += 1
                }
                if let targetWork, targetWork.modelContext == nil { break }
                if (index + 1).isMultiple(of: 32) { await Task.yield() }
            }

            if targetWork != nil, !imported.isEmpty { editions?.refreshEditionCounts() }
            let batchID: UUID?
            if targetWork == nil, editions != nil, !imported.isEmpty {
                let id = UUID()
                matchBatches[id] = MatchBatch(
                    books: imported,
                    remaining: Set(imported.map(\.uuid))
                )
                batchID = id
            } else {
                batchID = nil
            }
            for book in imported {
                extractMetadata(
                    for: book,
                    evaluateMatch: targetWork == nil && batchID == nil,
                    matchBatchID: batchID
                )
            }

            reportImportFailures(failureCount)
            if pendingRecoveryCount > 0 {
                toasts.error(String(
                    localized: "Some imported files are waiting for recovery (\(pendingRecoveryCount))."
                ))
            }
            completion?(imported)
        }
    }

    func cancelPending(_ uuid: UUID) {
        if let task = activeMetadataTasks[uuid] {
            task.cancel()
            return
        }
        guard let index = queuedMetadataJobs.firstIndex(where: { $0.book.uuid == uuid }) else {
            pendingMetadataUUIDs.remove(uuid)
            return
        }
        let job = queuedMetadataJobs.remove(at: index)
        if queuedMetadataJobs.isEmpty { queuedMetadataJobs = [] }
        pendingMetadataUUIDs.remove(uuid)
        if let batchID = job.matchBatchID { finishMatchBatch(batchID, completed: uuid) }
    }

    // MARK: - Maintenance

    func backfillMissingSizes() async {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.fileSizeBytes == 0 })
        guard let fetched = try? modelContext.fetch(descriptor) else { return }
        let books = fetched.filter(\.hasDigitalFile)
        guard !books.isEmpty else { return }
        let candidates = books.map { MaintenanceCandidate(uuid: $0.uuid, fileName: $0.fileName) }
        let sizes = await Task.detached(priority: .background) {
            Dictionary(uniqueKeysWithValues: candidates.map { candidate in
                (candidate.uuid, BookFileStore.size(of: candidate.fileName))
            })
        }.value
        guard !Task.isCancelled else { return }

        var changed = false
        for book in books where book.modelContext != nil {
            guard let size = sizes[book.uuid], size > 0 else { continue }
            if book.fileSizeBytes != size {
                book.fileSizeBytes = size
                changed = true
            }
            if let primary = book.assets.first(where: { $0.fileName == book.fileName }),
               primary.sizeBytes != size {
                primary.sizeBytes = size
                changed = true
            }
        }
        if changed { modelContext.saveQuietly() }
    }

    func detectMissingDRM() async {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.drmProtected == nil })
        guard let fetched = try? modelContext.fetch(descriptor) else { return }
        let books = fetched.filter(\.hasDigitalFile)
        guard !books.isEmpty else { return }
        let candidates = books.map { MaintenanceCandidate(uuid: $0.uuid, fileName: $0.fileName) }
        let results = await Task.detached(priority: .background) {
            Dictionary(uniqueKeysWithValues: candidates.map { candidate in
                let url = BookFileStore.url(for: candidate.fileName)
                return (candidate.uuid, DRMDetector.isProtected(url: url))
            })
        }.value
        guard !Task.isCancelled else { return }

        var changed = false
        for book in books where book.modelContext != nil && book.drmProtected == nil {
            guard let protected = results[book.uuid] else { continue }
            book.drmProtected = protected
            changed = true
        }
        if changed { modelContext.saveQuietly() }
    }

    func rescanMissingMetadata() async {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.title == nil })
        guard let fetched = try? modelContext.fetch(descriptor) else { return }
        let books = fetched.filter { $0.hasDigitalFile && !pendingMetadataUUIDs.contains($0.uuid) }
        guard !books.isEmpty else { return }

        let batchID: UUID?
        if editions != nil {
            let id = UUID()
            matchBatches[id] = MatchBatch(books: books, remaining: Set(books.map(\.uuid)))
            batchID = id
        } else {
            batchID = nil
        }

        for book in books {
            guard !Task.isCancelled else {
                if let batchID { matchBatches.removeValue(forKey: batchID) }
                return
            }
            pendingMetadataUUIDs.insert(book.uuid)
            await performMetadataExtraction(
                for: book,
                evaluateMatch: false
            )
            pendingMetadataUUIDs.remove(book.uuid)
            if let batchID { finishMatchBatch(batchID, completed: book.uuid) }
            await Task.yield()
        }
    }

    // MARK: - Managed import commit

    private func importOne(
        _ request: CopyRequest,
        assigningTo targetWork: Work?,
        knownHashes: Set<String>
    ) async throws -> ManagedImportResult {
        guard !modelContext.hasChanges else {
            modelContext.rollback()
            throw CatalogMutationError.dirtyContext
        }
        if let targetWork, targetWork.modelContext == nil { return .targetUnavailable }

        let accessing = request.source.startAccessingSecurityScopedResource()
        defer {
            if accessing { request.source.stopAccessingSecurityScopedResource() }
        }

        let source = try ManagedFileSource.book(sourceURL: request.source, fileID: request.uuid)
        let transaction = try await managedFiles.stage(
            intent: .importBook,
            sources: [source],
            requirement: ManagedFileRequirement(
                presentBookIDs: [request.uuid],
                referencedBookFileNames: [source.finalRelativeName]
            )
        )
        guard let staged = transaction.files.first else {
            await managedFiles.abort(transaction)
            throw CocoaError(.fileReadUnknown)
        }
        if targetWork != nil, knownHashes.contains(staged.sha256) {
            await managedFiles.abort(transaction)
            return .duplicate
        }
        if let targetWork, targetWork.modelContext == nil {
            await managedFiles.abort(transaction)
            return .targetUnavailable
        }

        let book = Book(
            uuid: request.uuid,
            fileName: staged.finalRelativeName,
            originalFileName: request.originalName
        )
        book.fileSizeBytes = staged.byteCount
        let work = targetWork ?? Work(dateCreated: book.dateAdded)
        let insertedWork = targetWork == nil
        let previousPreferredEdition = work.preferredEditionUUID
        let asset = BookAsset(
            uuid: request.uuid,
            fileName: staged.finalRelativeName,
            origin: .original,
            contentHash: staged.sha256,
            sizeBytes: staged.byteCount,
            dateAdded: book.dateAdded,
            validationStatus: nil,
            book: book
        )
        if insertedWork { modelContext.insert(work) }
        modelContext.insert(book)
        modelContext.insert(asset)
        book.work = work
        if work.preferredEditionUUID == nil { work.preferredEditionUUID = book.uuid }

        let result = try await mutations.commitStagedFiles(
            .importBooks(bookIDs: [book.uuid]),
            transactions: [transaction],
            affectedBookIDs: [book.uuid],
            affectedWorkIDs: [work.uuid],
            revertingOnFailure: {
                guard !insertedWork else { return }
                book.assets.removeAll()
                work.editions.removeAll { $0 === book }
                book.work = nil
                work.preferredEditionUUID = previousPreferredEdition
                if asset.modelContext != nil { modelContext.delete(asset) }
                if book.modelContext != nil { modelContext.delete(book) }
            }
        )
        guard result.isFullyPublished else {
            return .pending(contentHash: staged.sha256)
        }
        return .imported(book, contentHash: staged.sha256)
    }

    // MARK: - Background extraction

    private func extractMetadata(
        for book: Book,
        evaluateMatch: Bool = true,
        matchBatchID: UUID? = nil
    ) {
        guard pendingMetadataUUIDs.insert(book.uuid).inserted else { return }
        queuedMetadataJobs.append(MetadataJob(
            book: book,
            evaluateMatch: evaluateMatch,
            matchBatchID: matchBatchID
        ))
        startMetadataJobs()
    }

    private func startMetadataJobs() {
        while activeMetadataTasks.count < maximumConcurrentMetadataJobs,
              let job = queuedMetadataJobs.popFirst() {
            if queuedMetadataJobs.isEmpty { queuedMetadataJobs = [] }
            let uuid = job.book.uuid
            activeMetadataTasks[uuid] = Task { [weak self] in
                guard let self else { return }
                await self.performMetadataExtraction(
                    for: job.book,
                    evaluateMatch: job.evaluateMatch
                )
                self.finishMetadataJob(job)
            }
        }
    }

    private func finishMetadataJob(_ job: MetadataJob) {
        let uuid = job.book.uuid
        activeMetadataTasks.removeValue(forKey: uuid)
        pendingMetadataUUIDs.remove(uuid)
        if let batchID = job.matchBatchID { finishMatchBatch(batchID, completed: uuid) }
        startMetadataJobs()
    }

    private func performMetadataExtraction(
        for book: Book,
        evaluateMatch: Bool
    ) async {
        guard !Task.isCancelled, book.modelContext != nil,
              let url = book.primaryFileURL else { return }
        let analyzer = analyzeBook
        let result = await analyzer(url)
        guard !Task.isCancelled, book.modelContext != nil else { return }
        book.apply(result.metadata)
        book.drmProtected = result.drmProtected
        book.assets.first(where: { $0.fileName == book.fileName })?.validationStatus = result.validation
        refreshWorkIdentity(for: book, allowDisplayTitleFallback: !settings.onlineMetadataEnabled)
        modelContext.saveQuietly()
        wishlist.fulfil(with: [book])
        if settings.onlineMetadataEnabled {
            await metadata.performEnrich(book, replaceCover: false)
            guard !Task.isCancelled, book.modelContext != nil else { return }
            refreshWorkIdentity(for: book, allowDisplayTitleFallback: true)
            modelContext.saveQuietly()
            wishlist.fulfil(with: [book])
        }
        if evaluateMatch, let editions {
            if let undo = editions.evaluate(book) {
                let title = book.work?.displayTitle ?? book.displayTitle
                toasts.post(
                    String(localized: "Grouped with “\(title)”"),
                    style: .success,
                    action: .undoEditionAssignment(undo)
                )
            } else if editions.pendingProposals.contains(where: { $0.memberUUIDs.contains(book.uuid) }) {
                toasts.post(
                    String(localized: "Edition suggestions are ready to review."),
                    style: .info,
                    action: .reviewEditionProposals
                )
            }
        }
    }

    private func finishMatchBatch(_ id: UUID, completed uuid: UUID) {
        guard var batch = matchBatches[id] else { return }
        batch.remaining.remove(uuid)
        guard batch.remaining.isEmpty else {
            matchBatches[id] = batch
            return
        }
        matchBatches.removeValue(forKey: id)
        guard let editions else { return }

        let books = batch.books.filter { $0.modelContext != nil }
        let assignments = editions.evaluate(books)
        var hasSuggestions = false
        for book in books {
            if let undo = assignments[book.uuid] {
                let title = book.work?.displayTitle ?? book.displayTitle
                toasts.post(
                    String(localized: "Grouped with “\(title)”"),
                    style: .success,
                    action: .undoEditionAssignment(undo)
                )
            } else if editions.pendingProposals.contains(where: { $0.memberUUIDs.contains(book.uuid) }) {
                hasSuggestions = true
            }
        }
        if hasSuggestions {
            toasts.post(
                String(localized: "Edition suggestions are ready to review."),
                style: .info,
                action: .reviewEditionProposals
            )
        }
    }

    nonisolated static func defaultAnalysis(for url: URL) async -> ImportBookAnalysis {
        await Task.detached(priority: .utility) {
            let report = BookDoctorService.inspect(
                BookDoctorSource(title: url.lastPathComponent, url: url)
            )
            return ImportBookAnalysis(
                metadata: MetadataExtractor.extractMetadata(from: url),
                drmProtected: report.issues.contains { $0.kind == .drm },
                validation: report.assetValidation
            )
        }.value
    }

    private func refreshWorkIdentity(for book: Book, allowDisplayTitleFallback: Bool) {
        guard let work = book.work else { return }
        if work.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            if let title = book.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                work.title = title
            } else if allowDisplayTitleFallback {
                work.title = book.displayTitle
            }
        }
        if work.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            work.author = book.displayAuthor
        }
        work.refreshMatchKey()
    }

    private func reportImportFailures(_ count: Int) {
        if count > 0 {
            toasts.error(String(localized: "Some files couldn\u{2019}t be imported (\(count))."))
        }
    }
}
