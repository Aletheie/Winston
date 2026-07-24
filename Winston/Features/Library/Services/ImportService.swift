import AppKit
import Foundation
import PDFKit
import SwiftData

nonisolated struct ImportBookAnalysis: Sendable {
    let metadata: BookMetadata
    let drmProtected: Bool
    let validation: AssetValidation
    let coverJPEGData: Data?
    let fileOpenCount: Int

    init(
        metadata: BookMetadata,
        drmProtected: Bool,
        validation: AssetValidation = .ok,
        coverJPEGData: Data? = nil,
        fileOpenCount: Int = 1
    ) {
        self.metadata = metadata
        self.drmProtected = drmProtected
        self.validation = validation
        self.coverJPEGData = coverJPEGData
        self.fileOpenCount = fileOpenCount
    }
}

/// Immutable authority passed from background inspection into a short catalog
/// commit. It deliberately contains no SwiftData models or context-bound IDs.
nonisolated struct FileInspectionResult: Sendable, Equatable {
    let assetID: UUID
    let managedFileName: String
    let originalSourceURL: URL?
    let format: String
    let sizeBytes: Int64
    let sha256: String
    let metadata: BookMetadata
    let drmProtected: Bool
    let validation: AssetValidation
    let coverJPEGData: Data?
    let sourceReadPassCount: Int
    let analysisOpenCount: Int

    var totalReadPassCount: Int {
        sourceReadPassCount + analysisOpenCount
    }

    init(
        assetID: UUID,
        stagedFile: StagedManagedFile,
        analysis: ImportBookAnalysis
    ) {
        self.assetID = assetID
        managedFileName = stagedFile.finalRelativeName
        originalSourceURL = stagedFile.originalSourceURL
        format = URL(filePath: stagedFile.finalRelativeName).pathExtension.lowercased()
        sizeBytes = stagedFile.byteCount
        sha256 = stagedFile.sha256
        metadata = analysis.metadata
        drmProtected = analysis.drmProtected
        validation = analysis.validation
        coverJPEGData = analysis.coverJPEGData
        sourceReadPassCount = stagedFile.sourceReadPassCount ?? 2
        analysisOpenCount = analysis.fileOpenCount
    }
}

nonisolated enum ImportFileInspectionPipeline {
    /// Opens each supported container once and shares that parser instance for
    /// metadata, validation, DRM and cover discovery.
    @concurrent
    static func inspect(_ url: URL) async -> ImportBookAnalysis {
        guard !Task.isCancelled else {
            return ImportBookAnalysis(
                metadata: BookMetadata(),
                drmProtected: false,
                validation: .missing,
                fileOpenCount: 0
            )
        }

        let result: ImportBookAnalysis
        switch url.pathExtension.lowercased() {
        case "epub":
            result = inspectEPUB(url)
        case "pdf":
            result = inspectPDF(url)
        case "mobi", "azw", "azw3":
            result = inspectMOBI(url)
        case "html", "htm":
            result = inspectText(url, isHTML: true)
        case "txt":
            result = inspectText(url, isHTML: false)
        default:
            let report = BookDoctorService.inspect(
                BookDoctorSource(title: url.lastPathComponent, url: url)
            )
            result = ImportBookAnalysis(
                metadata: MetadataExtractor.extractMetadata(from: url),
                drmProtected: report.issues.contains { $0.kind == .drm },
                validation: report.assetValidation,
                fileOpenCount: 1
            )
        }
        guard !Task.isCancelled else {
            return ImportBookAnalysis(
                metadata: BookMetadata(),
                drmProtected: false,
                validation: .missing,
                fileOpenCount: result.fileOpenCount
            )
        }
        return result
    }

    private static func inspectEPUB(_ url: URL) -> ImportBookAnalysis {
        do {
            let archive = try EPUBArchive(url: url)
            let source = BookDoctorSource(title: url.lastPathComponent, url: url)
            let report = try BookDoctorService.inspectEPUB(source, archive: archive)
            return ImportBookAnalysis(
                metadata: MetadataExtractor.extractEPUB(from: archive),
                drmProtected: report.issues.contains { $0.kind == .drm },
                validation: report.assetValidation,
                coverJPEGData: normalizedCover(
                    CoverExtractor.epubCoverData(from: archive)
                ),
                fileOpenCount: 1
            )
        } catch {
            return ImportBookAnalysis(
                metadata: BookMetadata(),
                drmProtected: false,
                validation: .corrupt,
                fileOpenCount: 1
            )
        }
    }

    private static func inspectPDF(_ url: URL) -> ImportBookAnalysis {
        guard PDFReader.isWithinSizeLimit(url),
              let document = PDFDocument(url: url) else {
            return ImportBookAnalysis(
                metadata: BookMetadata(),
                drmProtected: false,
                validation: .corrupt,
                fileOpenCount: 1
            )
        }
        let cover = document.page(at: 0)?
            .thumbnail(of: CGSize(width: 400, height: 600), for: .mediaBox)
        return ImportBookAnalysis(
            metadata: MetadataExtractor.extractPDF(from: document),
            drmProtected: document.isEncrypted && document.isLocked,
            validation: document.pageCount > 0 ? .ok : .corrupt,
            coverJPEGData: cover.flatMap { ImageTranscoder.jpegData(from: $0) },
            fileOpenCount: 1
        )
    }

    private static func inspectMOBI(_ url: URL) -> ImportBookAnalysis {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return ImportBookAnalysis(
                metadata: BookMetadata(),
                drmProtected: false,
                validation: .corrupt,
                fileOpenCount: 1
            )
        }
        let pageCount = PageCountEstimator.mobiPageCount(in: data)
        return ImportBookAnalysis(
            metadata: MetadataExtractor.extractMOBI(from: data),
            drmProtected: DRMDetector.mobiEncrypted(data),
            validation: pageCount == nil ? .corrupt : .ok,
            coverJPEGData: normalizedCover(MOBICoverExtractor.coverData(from: data)),
            fileOpenCount: 1
        )
    }

    private static func inspectText(_ url: URL, isHTML: Bool) -> ImportBookAnalysis {
        guard let data = PageCountEstimator.boundedTextData(at: url) else {
            return ImportBookAnalysis(
                metadata: BookMetadata(),
                drmProtected: false,
                validation: .corrupt,
                fileOpenCount: 1
            )
        }
        return ImportBookAnalysis(
            metadata: isHTML
                ? MetadataExtractor.extractHTML(from: data)
                : MetadataExtractor.extractTXT(from: data),
            drmProtected: false,
            validation: .ok,
            fileOpenCount: 1
        )
    }

    private static func normalizedCover(_ data: Data?) -> Data? {
        data
            .flatMap { NSImage(data: $0) }
            .flatMap { ImageTranscoder.jpegData(from: $0) }
    }
}

@MainActor
@Observable
final class ImportService {
    typealias ImportCompletion = @MainActor ([Book]) -> Void

    private struct MatchBatch {
        let bookIDs: [UUID]
        var remaining: Set<UUID>
    }

    private struct MetadataJob {
        let bookID: UUID
        let requiresLocalAnalysis: Bool
        let evaluateMatch: Bool
        let matchBatchID: UUID?
    }

    nonisolated private struct CopyRequest: Sendable {
        let source: URL
        let uuid: UUID
        let originalName: String
    }

    nonisolated private struct PreparedImport: Sendable {
        let request: CopyRequest
        let inspection: FileInspectionResult
        let fileTransaction: ManagedFileTransaction
        let coverTransaction: ManagedFileTransaction?

        var transactions: [ManagedFileTransaction] {
            [fileTransaction] + [coverTransaction].compactMap { $0 }
        }
    }

    nonisolated private enum PreparationOutcome: Sendable {
        case prepared(PreparedImport)
        case failed(UUID)
        case cancelled(UUID)
    }

    private struct ImportChunkResult {
        var importedBookIDs: [UUID] = []
        var pendingContentHashes: [String] = []
        var acceptedContentHashes: Set<String> = []
        var duplicateBookIDs: [UUID] = []
        var failedBookIDs: [UUID] = []
        var targetUnavailable = false
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
    private let importCommitChunkSize: Int

    private(set) var pendingMetadataUUIDs: Set<UUID> = []
    private var activeImportOperationCount = 0
    private var activePreparationJobCount = 0
    private var preparingImportUUIDs: Set<UUID> = []
    private var cancelledImportUUIDs: Set<UUID> = []
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
        importCommitChunkSize: Int = 25,
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
        self.importCommitChunkSize = max(1, importCommitChunkSize)
        self.analyzeBook = analyzeBook
        self.measureFile = measureFile
        self.inspectDRM = inspectDRM
    }

    var isExtracting: Bool {
        activeImportOperationCount > 0 || !pendingMetadataUUIDs.isEmpty
    }
    var pendingMetadataCount: Int { pendingMetadataUUIDs.count }
    var activeMetadataJobCount: Int {
        activePreparationJobCount + activeMetadataTasks.count
    }

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

        let targetWorkID = targetWork?.uuid
        var knownHashes = Set(
            targetWork?.editions
                .flatMap(\.assets)
                .compactMap(\.contentHash) ?? []
        )
        let validationFailures = failed
        let requestIDs = Set(requests.map(\.uuid))
        pendingMetadataUUIDs.formUnion(requestIDs)
        preparingImportUUIDs.formUnion(requestIDs)
        activeImportOperationCount += 1
        Task { [weak self, requests] in
            guard let self else {
                completion?([])
                return
            }
            defer { activeImportOperationCount -= 1 }

            var importedBookIDs: [UUID] = []
            var failureCount = validationFailures
            var pendingRecoveryCount = 0
            var nextIndex = 0
            while nextIndex < requests.count, !Task.isCancelled {
                let end = min(nextIndex + importCommitChunkSize, requests.count)
                let requestChunk = Array(requests[nextIndex..<end])
                let outcomes = await prepareImports(requestChunk)
                var prepared: [PreparedImport] = []
                for outcome in outcomes {
                    switch outcome {
                    case .prepared(let value):
                        if cancelledImportUUIDs.remove(value.request.uuid) != nil {
                            preparingImportUUIDs.remove(value.request.uuid)
                            await abort(value.transactions)
                        } else {
                            prepared.append(value)
                        }
                    case .failed(let id), .cancelled(let id):
                        preparingImportUUIDs.remove(id)
                        cancelledImportUUIDs.remove(id)
                        pendingMetadataUUIDs.remove(id)
                        failureCount += 1
                    }
                }
                if Task.isCancelled {
                    await abort(prepared.flatMap(\.transactions))
                    break
                }

                let chunkResult = await commitPreparedImports(
                    prepared,
                    assigningTo: targetWorkID,
                    knownHashes: knownHashes
                )
                importedBookIDs.append(contentsOf: chunkResult.importedBookIDs)
                preparingImportUUIDs.subtract(prepared.map(\.request.uuid))
                knownHashes.formUnion(chunkResult.acceptedContentHashes)
                pendingRecoveryCount += chunkResult.pendingContentHashes.count
                failureCount += chunkResult.failedBookIDs.count
                pendingMetadataUUIDs.subtract(
                    chunkResult.duplicateBookIDs
                        + chunkResult.failedBookIDs
                        + prepared.compactMap {
                            chunkResult.pendingContentHashes.contains($0.inspection.sha256)
                                ? $0.request.uuid
                                : nil
                        }
                )

                for request in requestChunk {
                    pendingSourcePaths.remove(
                        request.source.standardizedFileURL.path(percentEncoded: false)
                    )
                }
                if chunkResult.targetUnavailable {
                    let remaining = requests[end...]
                    failureCount += remaining.count
                    for request in remaining {
                        preparingImportUUIDs.remove(request.uuid)
                        cancelledImportUUIDs.remove(request.uuid)
                        pendingMetadataUUIDs.remove(request.uuid)
                        pendingSourcePaths.remove(
                            request.source.standardizedFileURL.path(percentEncoded: false)
                        )
                    }
                    break
                }
                nextIndex = end
                await Task.yield()
            }

            if Task.isCancelled {
                for request in requests[nextIndex...] {
                    preparingImportUUIDs.remove(request.uuid)
                    cancelledImportUUIDs.remove(request.uuid)
                    pendingMetadataUUIDs.remove(request.uuid)
                    pendingSourcePaths.remove(
                        request.source.standardizedFileURL.path(percentEncoded: false)
                    )
                }
            }

            if targetWorkID != nil, !importedBookIDs.isEmpty {
                editions?.refreshEditionCounts()
            }
            let batchID: UUID?
            if targetWorkID == nil, editions != nil, !importedBookIDs.isEmpty {
                let id = UUID()
                matchBatches[id] = MatchBatch(
                    bookIDs: importedBookIDs,
                    remaining: Set(importedBookIDs)
                )
                batchID = id
            } else {
                batchID = nil
            }
            for bookID in importedBookIDs {
                enqueueMetadataJob(
                    bookID: bookID,
                    requiresLocalAnalysis: false,
                    evaluateMatch: targetWorkID == nil && batchID == nil,
                    matchBatchID: batchID
                )
            }

            reportImportFailures(failureCount)
            if pendingRecoveryCount > 0 {
                toasts.error(String(
                    localized: "Some imported files are waiting for recovery (\(pendingRecoveryCount))."
                ))
            }
            let imported = importedBookIDs.compactMap { try? mutations.book(id: $0) }
            completion?(imported)
        }
    }

    func cancelPending(_ uuid: UUID) {
        if preparingImportUUIDs.contains(uuid) {
            cancelledImportUUIDs.insert(uuid)
            pendingMetadataUUIDs.remove(uuid)
            return
        }
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
        let bookIDs = fetched
            .filter(\.hasCatalogDigitalFile)
            .map(\.uuid)
        await rescanMissingMetadata(bookIDs: bookIDs)
    }

    func rescanMissingMetadata(bookIDs: [UUID]) async {
        let books = bookIDs.compactMap { id in
            try? mutations.book(id: id)
        }.filter {
            $0.title == nil
                && $0.hasCatalogDigitalFile
                && !pendingMetadataUUIDs.contains($0.uuid)
        }
        guard !books.isEmpty else { return }

        let batchID: UUID?
        if editions != nil {
            let id = UUID()
            let bookIDs = books.map(\.uuid)
            matchBatches[id] = MatchBatch(
                bookIDs: bookIDs,
                remaining: Set(bookIDs)
            )
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

    private func prepareImports(
        _ requests: [CopyRequest]
    ) async -> [PreparationOutcome] {
        guard !requests.isEmpty else { return [] }
        let limit = min(maximumConcurrentMetadataJobs, requests.count)
        activePreparationJobCount += limit
        defer { activePreparationJobCount -= limit }
        let analyzer = analyzeBook
        let managedFiles = managedFiles

        return await withTaskGroup(
            of: (Int, PreparationOutcome).self,
            returning: [PreparationOutcome].self
        ) { group in
            var nextIndex = 0
            for _ in 0..<limit {
                let index = nextIndex
                let request = requests[index]
                group.addTask {
                    (index, await Self.prepareImport(
                        request,
                        managedFiles: managedFiles,
                        analyzer: analyzer
                    ))
                }
                nextIndex += 1
            }

            var results = Array<PreparationOutcome?>(repeating: nil, count: requests.count)
            while let (index, outcome) = await group.next() {
                results[index] = outcome
                guard nextIndex < requests.count, !Task.isCancelled else { continue }
                let pendingIndex = nextIndex
                let request = requests[pendingIndex]
                group.addTask {
                    (pendingIndex, await Self.prepareImport(
                        request,
                        managedFiles: managedFiles,
                        analyzer: analyzer
                    ))
                }
                nextIndex += 1
            }
            return results.enumerated().map { index, outcome in
                outcome ?? .cancelled(requests[index].uuid)
            }
        }
    }

    nonisolated private static func prepareImport(
        _ request: CopyRequest,
        managedFiles: ManagedFileCoordinator,
        analyzer: @escaping @Sendable (URL) async -> ImportBookAnalysis
    ) async -> PreparationOutcome {
        let accessing = request.source.startAccessingSecurityScopedResource()
        defer {
            if accessing { request.source.stopAccessingSecurityScopedResource() }
        }

        var transactions: [ManagedFileTransaction] = []
        do {
            try Task.checkCancellation()
            let source = try ManagedFileSource.book(
                sourceURL: request.source,
                fileID: request.uuid
            )
            let fileTransaction = try await managedFiles.stage(
                intent: .importBook,
                sources: [source],
                requirement: ManagedFileRequirement(
                    presentBookIDs: [request.uuid],
                    referencedBookFileNames: [source.finalRelativeName]
                )
            )
            transactions.append(fileTransaction)
            guard let staged = fileTransaction.files.first else {
                throw CocoaError(.fileReadUnknown)
            }

            let analysis = await analyzer(staged.stagedURL)
            try Task.checkCancellation()
            let inspection = FileInspectionResult(
                assetID: request.uuid,
                stagedFile: staged,
                analysis: analysis
            )

            var coverTransaction: ManagedFileTransaction?
            if let coverData = inspection.coverJPEGData {
                let transaction = try await managedFiles.stage(
                    intent: .importBook,
                    sources: [.cover(data: coverData, bookID: request.uuid)],
                    requirement: ManagedFileRequirement(
                        presentBookIDs: [request.uuid],
                        coverVersions: [request.uuid: 1]
                    )
                )
                coverTransaction = transaction
                transactions.append(transaction)
            }
            return .prepared(PreparedImport(
                request: request,
                inspection: inspection,
                fileTransaction: fileTransaction,
                coverTransaction: coverTransaction
            ))
        } catch is CancellationError {
            for transaction in transactions { await managedFiles.abort(transaction) }
            return .cancelled(request.uuid)
        } catch {
            for transaction in transactions { await managedFiles.abort(transaction) }
            return .failed(request.uuid)
        }
    }

    private func commitPreparedImports(
        _ prepared: [PreparedImport],
        assigningTo targetWorkID: UUID?,
        knownHashes: Set<String>
    ) async -> ImportChunkResult {
        guard !prepared.isEmpty else { return ImportChunkResult() }
        guard !modelContext.hasChanges else {
            modelContext.rollback()
            await abort(prepared.flatMap(\.transactions))
            return ImportChunkResult(failedBookIDs: prepared.map(\.request.uuid))
        }

        let targetWork: Work?
        if let targetWorkID {
            guard let work = try? mutations.work(id: targetWorkID),
                  work.modelContext != nil else {
                await abort(prepared.flatMap(\.transactions))
                return ImportChunkResult(
                    failedBookIDs: prepared.map(\.request.uuid),
                    targetUnavailable: true
                )
            }
            targetWork = work
        } else {
            targetWork = nil
        }

        var seenHashes = knownHashes
        var accepted: [PreparedImport] = []
        var result = ImportChunkResult()
        for candidate in prepared {
            let hash = candidate.inspection.sha256
            if targetWork != nil, !seenHashes.insert(hash).inserted {
                await abort(candidate.transactions)
                result.duplicateBookIDs.append(candidate.request.uuid)
            } else {
                accepted.append(candidate)
            }
        }
        guard !accepted.isEmpty else { return result }

        let previousPreferredEdition = targetWork?.preferredEditionUUID
        var insertedBooks: [Book] = []
        var affectedWorkIDs: Set<UUID> = []
        for candidate in accepted {
            let inspection = candidate.inspection
            let book = Book(
                uuid: candidate.request.uuid,
                fileName: inspection.managedFileName,
                originalFileName: candidate.request.originalName
            )
            book.fileSizeBytes = inspection.sizeBytes
            book.drmProtected = inspection.drmProtected
            book.apply(inspection.metadata)
            if candidate.coverTransaction != nil { book.coverVersion = 1 }

            let work = targetWork ?? Work(dateCreated: book.dateAdded)
            if targetWork == nil { modelContext.insert(work) }
            modelContext.insert(book)
            let asset = BookAsset(
                uuid: inspection.assetID,
                fileName: inspection.managedFileName,
                origin: .original,
                contentHash: inspection.sha256,
                sizeBytes: inspection.sizeBytes,
                dateAdded: book.dateAdded,
                validationStatus: inspection.validation,
                book: book
            )
            modelContext.insert(asset)
            book.work = work
            if work.preferredEditionUUID == nil { work.preferredEditionUUID = book.uuid }
            refreshWorkIdentity(
                for: book,
                allowDisplayTitleFallback: !settings.onlineMetadataEnabled
            )
            insertedBooks.append(book)
            affectedWorkIDs.insert(work.uuid)
        }

        do {
            let commit = try await mutations.commitStagedFiles(
                .importBooks(bookIDs: accepted.map(\.request.uuid)),
                transactions: accepted.flatMap(\.transactions),
                affectedBookIDs: Set(accepted.map(\.request.uuid)),
                affectedWorkIDs: affectedWorkIDs,
                revertingOnFailure: {
                    guard let targetWork else { return }
                    for book in insertedBooks {
                        book.assets.removeAll()
                        targetWork.editions.removeAll { $0 === book }
                        book.work = nil
                    }
                    targetWork.preferredEditionUUID = previousPreferredEdition
                }
            )
            let pending = Set(commit.pendingTransactionIDs)
            for candidate in accepted {
                result.acceptedContentHashes.insert(candidate.inspection.sha256)
                if candidate.transactions.contains(where: { pending.contains($0.id) }) {
                    result.pendingContentHashes.append(candidate.inspection.sha256)
                } else {
                    result.importedBookIDs.append(candidate.request.uuid)
                }
            }
            return result
        } catch {
            result.failedBookIDs.append(contentsOf: accepted.map(\.request.uuid))
            return result
        }
    }

    private func abort(_ transactions: [ManagedFileTransaction]) async {
        for transaction in transactions { await managedFiles.abort(transaction) }
    }

    // MARK: - Background extraction

    private func enqueueMetadataJob(
        bookID: UUID,
        requiresLocalAnalysis: Bool,
        evaluateMatch: Bool = true,
        matchBatchID: UUID? = nil
    ) {
        guard activeMetadataTasks[bookID] == nil,
              !queuedMetadataJobs.contains(where: { $0.bookID == bookID }) else { return }
        pendingMetadataUUIDs.insert(bookID)
        queuedMetadataJobs.append(MetadataJob(
            bookID: bookID,
            requiresLocalAnalysis: requiresLocalAnalysis,
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
                if job.requiresLocalAnalysis {
                    await self.performMetadataExtraction(
                        for: job.bookID,
                        evaluateMatch: job.evaluateMatch
                    )
                } else {
                    await self.performPostInspection(
                        for: job.bookID,
                        evaluateMatch: job.evaluateMatch
                    )
                }
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
        await performPostInspection(for: bookID, evaluateMatch: evaluateMatch)
    }

    private func performPostInspection(
        for bookID: UUID,
        evaluateMatch: Bool
    ) async {
        guard !Task.isCancelled else { return }
        if let appliedBook = try? mutations.book(id: bookID) {
            wishlist.fulfil(with: [appliedBook])
        }
        if settings.onlineMetadataEnabled {
            let enrichmentSnapshot = (try? mutations.book(id: bookID))
                .flatMap(BookAnalysisSnapshot.init(book:))
            let matched = await metadata.performEnrich(
                bookID: bookID,
                replaceCover: false
            )
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

        let books = batch.bookIDs.compactMap { id in
            try? mutations.book(id: id)
        }
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
        await ImportFileInspectionPipeline.inspect(url)
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
