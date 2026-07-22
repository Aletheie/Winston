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
        let bookID: UUID
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

    private struct CompletedMaintenance<Value: Sendable> {
        let job: CatalogAnalysisJob<CatalogAssetInspectionProposal<Value>>
        let proposal: CatalogAssetInspectionProposal<Value>
    }

    private let modelContext: ModelContext
    private let settings: AppSettings
    private let metadata: MetadataService
    private let wishlist: WishlistService
    private let toasts: ToastCenter
    private let editions: CatalogReconciliationService?
    private let mutations: CatalogMutationService
    private let analysisCoordinator: CatalogAnalysisCoordinator
    private let managedFiles: ManagedFileCoordinator
    private let analyzeBook: @Sendable (URL) async -> ImportBookAnalysis
    private let measureFile: @Sendable (URL) async -> Int64
    private let inspectDRM: @Sendable (URL) async -> Bool
    private let maximumConcurrentMetadataJobs: Int

    private(set) var pendingMetadataUUIDs: Set<UUID> = []
    private var activeImportOperationCount = 0
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
        editions: CatalogReconciliationService? = nil,
        mutations: CatalogMutationService? = nil,
        managedFiles: ManagedFileCoordinator = .shared,
        maximumConcurrentMetadataJobs: Int = BookDoctorService.defaultMaximumConcurrentInspections,
        analyzeBook: @escaping @Sendable (URL) async -> ImportBookAnalysis = ImportService.defaultAnalysis,
        measureFile: @escaping @Sendable (URL) async -> Int64 = ImportService.defaultFileSize,
        inspectDRM: @escaping @Sendable (URL) async -> Bool = ImportService.defaultDRMInspection
    ) {
        let coordinator = mutations?.analysisCoordinator ?? metadata.analysisCoordinator
        let resolvedMutations = mutations ?? CatalogMutationService(
            modelContext: modelContext,
            managedFiles: managedFiles,
            analysisCoordinator: coordinator
        )
        self.modelContext = modelContext
        self.settings = settings
        self.metadata = metadata
        self.wishlist = wishlist
        self.toasts = toasts
        self.editions = editions
        self.mutations = resolvedMutations
        self.analysisCoordinator = resolvedMutations.analysisCoordinator
        self.managedFiles = managedFiles
        self.maximumConcurrentMetadataJobs = max(1, maximumConcurrentMetadataJobs)
        self.analyzeBook = analyzeBook
        self.measureFile = measureFile
        self.inspectDRM = inspectDRM
    }

    var isExtracting: Bool {
        activeImportOperationCount > 0 || !pendingMetadataUUIDs.isEmpty
    }
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
        activeImportOperationCount += 1
        Task { [weak self, requests] in
            guard let self else {
                completion?([])
                return
            }
            defer { activeImportOperationCount -= 1 }

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
        guard let index = queuedMetadataJobs.firstIndex(where: { $0.bookID == uuid }) else {
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
        let snapshots = fetched.filter(\.hasDigitalFile).compactMap(BookAnalysisSnapshot.init(book:))
        guard !snapshots.isEmpty else { return }

        for chunkStart in stride(from: 0, to: snapshots.count, by: 50) {
            guard !Task.isCancelled else { return }
            let chunk = Array(snapshots[chunkStart ..< min(chunkStart + 50, snapshots.count)])
            let measureFile = self.measureFile
            let completed = await collectMaintenance(
                snapshots: chunk,
                kind: .fileSize
            ) { url in
                let size = await measureFile(url)
                return size > 0 ? size : nil
            }
            guard !Task.isCancelled else {
                completed.forEach { analysisCoordinator.finish($0.job.ticket) }
                return
            }

            var valid: [(BookAnalysisSnapshot, CatalogAssetInspectionProposal<Int64>, Book, BookAsset?)] = []
            for result in completed {
                let snapshot = result.job.snapshot
                guard analysisCoordinator.isCurrent(result.job.ticket),
                      result.proposal.sourceIsCurrent(for: snapshot),
                      let book = try? mutations.book(id: snapshot.bookID),
                      snapshot.matches(book),
                      book.fileSizeBytes == 0 else { continue }
                let asset = snapshot.assetID.flatMap { id in
                    book.assets.first(where: { $0.uuid == id })
                }
                valid.append((snapshot, result.proposal, book, asset))
            }

            if !valid.isEmpty {
                let bookPreimages = valid.map { CatalogBookMetadataPreimage($0.2) }
                let assetPreimages = valid.compactMap { $0.3 }.map(CatalogBookAssetPreimage.init)
                let bookIDs = Set(valid.map { $0.0.bookID })
                do {
                    try mutations.commit(
                        .applyAnalysisBatch(bookIDs: Array(bookIDs), kind: .fileSize),
                        affectedBookIDs: bookIDs,
                        revertingOnFailure: {
                            bookPreimages.forEach { $0.restore() }
                            assetPreimages.forEach { $0.restore() }
                        }
                    ) {
                        for (snapshot, proposal, _, _) in valid {
                            let book = try mutations.book(id: snapshot.bookID)
                            guard snapshot.matches(book),
                                  proposal.sourceIsCurrent(for: snapshot),
                                  book.fileSizeBytes == 0 else {
                                throw CatalogMutationError.staleAnalysis
                            }
                            book.fileSizeBytes = proposal.value
                            if let assetID = snapshot.assetID,
                               let asset = book.assets.first(where: { $0.uuid == assetID }),
                               asset.sizeBytes == 0 {
                                asset.sizeBytes = proposal.value
                            }
                        }
                    }
                } catch {
                    // Best-effort startup maintenance; every preimage was restored.
                }
            }
            completed.forEach { analysisCoordinator.finish($0.job.ticket) }
        }
    }

    func detectMissingDRM() async {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.drmProtected == nil })
        guard let fetched = try? modelContext.fetch(descriptor) else { return }
        let snapshots = fetched.filter(\.hasDigitalFile).compactMap(BookAnalysisSnapshot.init(book:))
        guard !snapshots.isEmpty else { return }

        for chunkStart in stride(from: 0, to: snapshots.count, by: 50) {
            guard !Task.isCancelled else { return }
            let chunk = Array(snapshots[chunkStart ..< min(chunkStart + 50, snapshots.count)])
            let inspectDRM = self.inspectDRM
            let completed = await collectMaintenance(
                snapshots: chunk,
                kind: .drmInspection
            ) { url in
                await inspectDRM(url)
            }
            guard !Task.isCancelled else {
                completed.forEach { analysisCoordinator.finish($0.job.ticket) }
                return
            }

            var valid: [(BookAnalysisSnapshot, CatalogAssetInspectionProposal<Bool>, Book)] = []
            for result in completed {
                let snapshot = result.job.snapshot
                guard analysisCoordinator.isCurrent(result.job.ticket),
                      result.proposal.sourceIsCurrent(for: snapshot),
                      let book = try? mutations.book(id: snapshot.bookID),
                      snapshot.matches(book),
                      book.drmProtected == nil else { continue }
                valid.append((snapshot, result.proposal, book))
            }

            if !valid.isEmpty {
                let preimages = valid.map { CatalogBookMetadataPreimage($0.2) }
                let bookIDs = Set(valid.map { $0.0.bookID })
                do {
                    try mutations.commit(
                        .applyAnalysisBatch(bookIDs: Array(bookIDs), kind: .drmInspection),
                        affectedBookIDs: bookIDs,
                        revertingOnFailure: { preimages.forEach { $0.restore() } }
                    ) {
                        for (snapshot, proposal, _) in valid {
                            let book = try mutations.book(id: snapshot.bookID)
                            guard snapshot.matches(book),
                                  proposal.sourceIsCurrent(for: snapshot),
                                  book.drmProtected == nil else {
                                throw CatalogMutationError.staleAnalysis
                            }
                            book.drmProtected = proposal.value
                        }
                    }
                } catch {
                    // Best-effort startup maintenance; every preimage was restored.
                }
            }
            completed.forEach { analysisCoordinator.finish($0.job.ticket) }
        }
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
                for: book.uuid,
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
            bookID: book.uuid,
            evaluateMatch: evaluateMatch,
            matchBatchID: matchBatchID
        ))
        startMetadataJobs()
    }

    private func startMetadataJobs() {
        while activeMetadataTasks.count < maximumConcurrentMetadataJobs,
              let job = queuedMetadataJobs.popFirst() {
            if queuedMetadataJobs.isEmpty { queuedMetadataJobs = [] }
            let uuid = job.bookID
            activeMetadataTasks[uuid] = Task { [weak self] in
                guard let self else { return }
                await self.performMetadataExtraction(
                    for: job.bookID,
                    evaluateMatch: job.evaluateMatch
                )
                self.finishMetadataJob(job)
            }
        }
    }

    private func finishMetadataJob(_ job: MetadataJob) {
        let uuid = job.bookID
        activeMetadataTasks.removeValue(forKey: uuid)
        pendingMetadataUUIDs.remove(uuid)
        if let batchID = job.matchBatchID { finishMatchBatch(batchID, completed: uuid) }
        startMetadataJobs()
    }

    private func performMetadataExtraction(
        for bookID: UUID,
        evaluateMatch: Bool
    ) async {
        guard !Task.isCancelled,
              let book = try? mutations.book(id: bookID),
              let snapshot = BookAnalysisSnapshot(book: book),
              snapshot.fileURL != nil else { return }
        let analyzer = analyzeBook
        let job = analysisCoordinator.start(snapshot: snapshot, kind: .metadataExtraction) { snapshot in
            await CatalogAnalysisWorker.inspect(snapshot: snapshot) { url in
                await analyzer(url)
            }
        }
        defer { analysisCoordinator.finish(job.ticket) }

        guard let proposal = await analysisCoordinator.value(for: job),
              proposal.sourceIsCurrent(for: snapshot),
              analysisCoordinator.isCurrent(job.ticket),
              let liveBook = try? mutations.book(id: bookID),
              snapshot.matches(liveBook) else { return }

        let bookPreimage = CatalogBookMetadataPreimage(liveBook)
        let workPreimage = liveBook.work.map(CatalogWorkPreimage.init)
        let assetPreimage = snapshot.assetID
            .flatMap { id in liveBook.assets.first(where: { $0.uuid == id }) }
            .map(CatalogBookAssetPreimage.init)
        do {
            try mutations.commit(
                .applyAnalysis(bookID: bookID, kind: .metadataExtraction),
                affectedBookIDs: [bookID],
                affectedWorkIDs: Set([snapshot.identityRevision.workID].compactMap { $0 }),
                revertingOnFailure: {
                    bookPreimage.restore()
                    workPreimage?.restore()
                    assetPreimage?.restore()
                }
            ) {
                let storedBook = try mutations.book(id: bookID)
                guard analysisCoordinator.isCurrent(job.ticket),
                      snapshot.matches(storedBook),
                      proposal.sourceIsCurrent(for: snapshot) else {
                    throw CatalogMutationError.staleAnalysis
                }
                storedBook.apply(proposal.value.metadata)
                storedBook.drmProtected = proposal.value.drmProtected
                if let assetID = snapshot.assetID,
                   let asset = storedBook.assets.first(where: { $0.uuid == assetID }) {
                    asset.validationStatus = proposal.value.validation
                }
                refreshWorkIdentity(
                    for: storedBook,
                    allowDisplayTitleFallback: !settings.onlineMetadataEnabled
                )
            }
        } catch {
            return
        }

        analysisCoordinator.finish(job.ticket)
        guard let appliedBook = try? mutations.book(id: bookID) else { return }
        wishlist.fulfil(with: [appliedBook])
        if settings.onlineMetadataEnabled {
            let enrichmentSnapshot = BookAnalysisSnapshot(book: appliedBook)
            let matched = await metadata.performEnrich(appliedBook, replaceCover: false)
            guard !Task.isCancelled,
                  let enrichedBook = try? mutations.book(id: bookID) else { return }
            if !matched,
               let enrichmentSnapshot,
               enrichmentSnapshot.matches(enrichedBook) {
                commitWorkIdentity(for: enrichedBook, allowDisplayTitleFallback: true)
            }
            wishlist.fulfil(with: [enrichedBook])
        }
        if evaluateMatch, let editions {
            guard let currentBook = try? mutations.book(id: bookID) else { return }
            editions.evaluate(currentBook)
            if editions.pendingProposals.contains(where: { $0.memberUUIDs.contains(bookID) }) {
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
        editions.evaluate(books)
        var hasSuggestions = false
        for book in books {
            if editions.pendingProposals.contains(where: { $0.memberUUIDs.contains(book.uuid) }) {
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

    private func collectMaintenance<Value: Sendable>(
        snapshots: [BookAnalysisSnapshot],
        kind: CatalogAnalysisJobKind,
        operation: @escaping @Sendable (URL) async -> Value?
    ) async -> [CompletedMaintenance<Value>] {
        var completed: [CompletedMaintenance<Value>] = []
        let concurrency = min(4, maximumConcurrentMetadataJobs)
        for start in stride(from: 0, to: snapshots.count, by: concurrency) {
            let batch = snapshots[start ..< min(start + concurrency, snapshots.count)]
            let jobs: [CatalogAnalysisJob<CatalogAssetInspectionProposal<Value>>] = batch.map { snapshot in
                analysisCoordinator.start(snapshot: snapshot, kind: kind) { snapshot in
                    await CatalogAnalysisWorker.inspect(snapshot: snapshot, operation: operation)
                }
            }
            for job in jobs {
                if let proposal = await analysisCoordinator.value(for: job) {
                    completed.append(CompletedMaintenance(job: job, proposal: proposal))
                } else {
                    analysisCoordinator.finish(job.ticket)
                }
            }
        }
        return completed
    }

    private func commitWorkIdentity(for book: Book, allowDisplayTitleFallback: Bool) {
        guard let snapshot = BookAnalysisSnapshot(book: book),
              let work = book.work else { return }
        let preimage = CatalogWorkPreimage(work)
        do {
            try mutations.commit(
                .applyAnalysis(bookID: book.uuid, kind: .onlineEnrichment),
                affectedBookIDs: [book.uuid],
                affectedWorkIDs: [work.uuid],
                revertingOnFailure: preimage.restore
            ) {
                let storedBook = try mutations.book(id: snapshot.bookID)
                guard snapshot.matches(storedBook) else {
                    throw CatalogMutationError.staleAnalysis
                }
                refreshWorkIdentity(
                    for: storedBook,
                    allowDisplayTitleFallback: allowDisplayTitleFallback
                )
            }
        } catch {
            return
        }
    }

    @concurrent
    static func defaultAnalysis(for url: URL) async -> ImportBookAnalysis {
        let report = BookDoctorService.inspect(
            BookDoctorSource(title: url.lastPathComponent, url: url)
        )
        return ImportBookAnalysis(
            metadata: MetadataExtractor.extractMetadata(from: url),
            drmProtected: report.issues.contains { $0.kind == .drm },
            validation: report.assetValidation
        )
    }

    @concurrent
    static func defaultFileSize(at url: URL) async -> Int64 {
        guard !Task.isCancelled,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return Int64(size)
    }

    @concurrent
    static func defaultDRMInspection(at url: URL) async -> Bool {
        guard !Task.isCancelled else { return false }
        return DRMDetector.isProtected(url: url)
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
