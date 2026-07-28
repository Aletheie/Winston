import AppKit
import Foundation
import OSLog
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

    var fingerprint: ImportFingerprint {
        ImportFingerprint(contentHash: sha256, format: format)
    }

    func identity(fallbackTitle: String) -> ImportIdentityRecord {
        let extractedTitle = metadata.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ImportIdentityRecord(
            title: extractedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle,
            author: metadata.author,
            isbn: metadata.isbn,
            language: metadata.language,
            publisher: metadata.publisher,
            year: metadata.year
        )
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

nonisolated enum ImportSessionSource: String, Sendable, Equatable {
    case standard
    case calibre
}

nonisolated enum ImportSessionStep: String, Sendable, Equatable {
    case sourceDiscovery
    case staging
    case inspection
    case reconciliation
    case modelProposal
    case chunkCommit
    case publishing
    case derivedJobs
    case completed
    case cancelling
    case cancelled
    case failed
}

nonisolated enum ImportSourceDiscoveryError: Error, Sendable, Equatable {
    case invalidURL
    case unsupportedFormat
    case symbolicLink
    case notRegularFile
    case unreadable
}

nonisolated enum ImportFailureReason: String, Codable, Sendable, Equatable, CaseIterable {
    case unsupportedFormat
    case unreadableSource
    case staging
    case validation
    case catalog
    case recoveryDeferred
}

nonisolated struct ImportFailure: Sendable, Equatable {
    let sourceURL: URL?
    let requestedBookID: UUID?
    let reason: ImportFailureReason
    let detail: String
}

nonisolated struct ImportDiscoveredSource: Sendable, Equatable {
    let url: URL
    let format: String
}

nonisolated enum ImportSourceDiscovery {
    static func discover(_ sourceURL: URL) throws -> ImportDiscoveredSource {
        guard sourceURL.isFileURL else {
            throw ImportSourceDiscoveryError.invalidURL
        }
        let url = sourceURL.standardizedFileURL
        let format = url.pathExtension.lowercased()
        guard libraryEbookExtensions.contains(format) else {
            throw ImportSourceDiscoveryError.unsupportedFormat
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isSymbolicLinkKey,
                .isRegularFileKey,
                .isReadableKey
            ])
        } catch {
            throw ImportSourceDiscoveryError.unreadable
        }
        guard values.isSymbolicLink != true else {
            throw ImportSourceDiscoveryError.symbolicLink
        }
        guard values.isRegularFile == true else {
            throw ImportSourceDiscoveryError.notRegularFile
        }
        guard values.isReadable != false else {
            throw ImportSourceDiscoveryError.unreadable
        }
        return ImportDiscoveredSource(url: url, format: format)
    }
}

@MainActor
final class ImportSession {
    let id = UUID()
    let generation = UUID()
    let source: ImportSessionSource
    private(set) var requestedBookIDs: Set<UUID>
    private(set) var step: ImportSessionStep = .sourceDiscovery
    private(set) var failures: [ImportFailure] = []
    private var task: Task<Void, Never>?

    init(
        source: ImportSessionSource = .standard,
        requestedBookIDs: Set<UUID> = []
    ) {
        self.source = source
        self.requestedBookIDs = requestedBookIDs
    }

    var isCancelled: Bool { task?.isCancelled ?? false }

    func cancel() {
        step = .cancelling
        task?.cancel()
    }

    func discover(_ bookIDs: Set<UUID>) {
        requestedBookIDs = bookIDs
        step = .staging
    }

    func advance(to step: ImportSessionStep) {
        guard self.step != .cancelled, self.step != .failed else { return }
        self.step = step
    }

    func recordFailures(_ failures: [ImportFailure]) {
        self.failures.append(contentsOf: failures)
    }

    func start(_ task: Task<Void, Never>) {
        precondition(self.task == nil)
        self.task = task
    }

    func finish(as finalStep: ImportSessionStep? = nil) {
        if let finalStep {
            step = finalStep
        } else if step == .cancelling {
            step = .cancelled
        }
        task = nil
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
        let source: ImportSource
        let uuid: UUID
        let workID: UUID
        let originalName: String

        var sourceURL: URL { source.url }
    }

    nonisolated private struct PreparedImport: Sendable {
        let request: CopyRequest
        let inspection: FileInspectionResult
        let fileTransaction: ManagedFileTransaction

        var transactions: [ManagedFileTransaction] {
            [fileTransaction]
        }

        var reconciliationCandidate: ImportReconciliationCandidate {
            ImportReconciliationCandidate(
                itemID: "standard:\(request.uuid.uuidString)",
                proposedBookID: request.uuid,
                proposedWorkID: request.workID,
                fingerprint: inspection.fingerprint,
                identity: inspection.identity(
                    fallbackTitle: URL(filePath: request.originalName)
                        .deletingPathExtension()
                        .lastPathComponent
                )
            )
        }
    }

    private struct ResolvedPreparedImport {
        let prepared: PreparedImport
        let proposal: ImportModelProposal
        let coverMutation: PreparedCoverMutation?

        var transactions: [ManagedFileTransaction] {
            prepared.transactions + [coverMutation?.transaction].compactMap { $0 }
        }
    }

    private struct ImportedBookPreimage {
        let book: Book
        let assets: [BookAsset]
    }

    private struct ImportedWorkPreimage {
        let work: Work
        let editions: [Book]
        let preferredEditionUUID: UUID?
    }

    nonisolated private enum PreparationOutcome: Sendable {
        case prepared(PreparedImport)
        case failed(ImportFailure)
        case cancelled(UUID)
    }

    private struct ImportChunkResult {
        var importedBookIDs: [UUID] = []
        var reviewBookIDs: [UUID] = []
        var failures: [ImportFailure] = []
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
    private let coverMutations: CoverMutationCoordinator
    private let identityIndex: CatalogIdentityIndex
    private let recoveryQueue: ImportRecoveryQueueStore
    private let importSourceLeases: ImportSourceLeaseStore
    private let analyzeBook: @Sendable (URL) async -> ImportBookAnalysis
    private let measureFile: @Sendable (URL) async -> Int64
    private let inspectDRM: @Sendable (URL) async -> Bool
    private let maximumConcurrentMetadataJobs: Int
    private let importCommitChunkSize: Int

    private(set) var pendingMetadataUUIDs: Set<UUID> = []
    private(set) var lastImportFailures: [ImportFailure] = []
    private(set) var importRecoveryItems: [ImportRecoveryItem] = []
    private(set) var lastRecoveryQueueError: String?
    private(set) var lastMaintenanceError: String?
    private var activeImportOperationCount = 0
    private var activePreparationJobCount = 0
    private var preparingImportUUIDs: Set<UUID> = []
    private var cancelledImportUUIDs: Set<UUID> = []
    private var pendingSourcePaths: Set<String> = []
    private var matchBatches: [UUID: MatchBatch] = [:]
    private var queuedMetadataJobs: ArraySlice<MetadataJob> = []
    private var activeMetadataTasks: [UUID: Task<Void, Never>] = [:]
    private var activeImportSessions: [UUID: ImportSession] = [:]
    private var recoveryQueueWriteTask: Task<Void, Never>?

    init(
        modelContext: ModelContext,
        settings: AppSettings,
        metadata: MetadataService,
        wishlist: WishlistService,
        toasts: ToastCenter,
        editions: CatalogReconciliationService? = nil,
        mutations: CatalogMutationService? = nil,
        managedFiles: ManagedFileCoordinator = .shared,
        identityIndex: CatalogIdentityIndex? = nil,
        recoveryQueue: ImportRecoveryQueueStore = .shared,
        importSourceLeases: ImportSourceLeaseStore = ImportSourceLeaseStore(),
        maximumConcurrentMetadataJobs: Int = BookDoctorService.defaultMaximumConcurrentInspections,
        importCommitChunkSize: Int = 25,
        analyzeBook: @escaping @Sendable (URL) async -> ImportBookAnalysis = ImportService.defaultAnalysis,
        measureFile: @escaping @Sendable (URL) async -> Int64 = ImportService.defaultFileSize,
        inspectDRM: @escaping @Sendable (URL) async -> Bool = ImportService.defaultDRMInspection
    ) {
        let coordinator = mutations?.analysisCoordinator ?? metadata.analysisCoordinator
        let resolvedManagedFiles = mutations?.managedFiles ?? managedFiles
        let resolvedMutations = mutations ?? CatalogMutationService(
            modelContext: modelContext,
            managedFiles: resolvedManagedFiles,
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
        self.managedFiles = resolvedManagedFiles
        coverMutations = CoverMutationCoordinator.resolve(
            modelContext: modelContext,
            mutations: resolvedMutations,
            managedFiles: resolvedManagedFiles
        )
        self.identityIndex = identityIndex
            ?? CatalogIdentityIndexRegistry.resolve(modelContext: modelContext)
        self.recoveryQueue = recoveryQueue
        self.importSourceLeases = importSourceLeases
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

    func reloadImportRecoveryQueue() async {
        await recoveryQueueWriteTask?.value
        do {
            importRecoveryItems = try await recoveryQueue.load()
            lastRecoveryQueueError = nil
        } catch {
            lastRecoveryQueueError = error.localizedDescription
            Log.persistence.error(
                "Could not load the import recovery queue: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func dismissImportRecoveryItems(ids: Set<UUID>) async {
        await recoveryQueueWriteTask?.value
        do {
            importRecoveryItems = try await recoveryQueue.dismiss(ids: ids)
            lastRecoveryQueueError = nil
        } catch {
            lastRecoveryQueueError = error.localizedDescription
            Log.persistence.error(
                "Could not update the import recovery queue: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    @discardableResult
    func retryImportRecoveryItem(id: UUID) -> ImportSession? {
        guard let item = importRecoveryItems.first(where: { $0.id == id }),
              let sourceURL = item.sourceURL,
              item.canRetry else {
            return nil
        }
        let attemptedPath = sourceURL.standardizedFileURL.path(percentEncoded: false)
        var retrySession: ImportSession?
        retrySession = addBooks(from: [sourceURL]) { [weak self] imported in
            guard let self, !imported.isEmpty else { return }
            let failedPaths = Set(retrySession?.failures.compactMap {
                $0.sourceURL?.standardizedFileURL.path(percentEncoded: false)
            } ?? [])
            guard !failedPaths.contains(attemptedPath) else { return }
            Task { await self.dismissImportRecoveryItems(ids: [id]) }
        }
        return retrySession
    }

    @discardableResult
    func addBooks(
        from urls: [URL],
        completion: ImportCompletion? = nil
    ) -> ImportSession? {
        addBooks(
            fromImportSources: urls.map(ImportSource.external),
            assigningTo: nil,
            completion: completion
        )
    }

    @discardableResult
    func addBooks(
        from sources: [ImportSource],
        completion: ImportCompletion? = nil
    ) -> ImportSession? {
        addBooks(
            fromImportSources: sources,
            assigningTo: nil,
            completion: completion
        )
    }

    @discardableResult
    func addBooks(
        from urls: [URL],
        assigningTo targetWork: Work?,
        completion: ImportCompletion? = nil
    ) -> ImportSession? {
        addBooks(
            fromImportSources: urls.map(ImportSource.external),
            assigningTo: targetWork,
            completion: completion
        )
    }

    private func addBooks(
        fromImportSources sources: [ImportSource],
        assigningTo targetWork: Work?,
        completion: ImportCompletion?
    ) -> ImportSession? {
        var requests: [CopyRequest] = []
        var validationFailures: [ImportFailure] = []
        for source in sources {
            let url = source.url
            guard libraryEbookExtensions.contains(url.pathExtension.lowercased()) else {
                validationFailures.append(ImportFailure(
                    sourceURL: url,
                    requestedBookID: nil,
                    reason: .unsupportedFormat,
                    detail: ImportSourceDiscoveryError.unsupportedFormat.localizedDescription
                ))
                cleanupOwnedSource(source)
                continue
            }

            let originalName = url.lastPathComponent
            let sourcePath = url.standardizedFileURL.path(percentEncoded: false)
            guard pendingSourcePaths.insert(sourcePath).inserted else { continue }
            requests.append(CopyRequest(
                source: source,
                uuid: UUID(),
                workID: UUID(),
                originalName: originalName
            ))
        }

        guard !requests.isEmpty else {
            lastImportFailures = validationFailures
            scheduleImportFailurePersistence(validationFailures)
            reportImportFailures(validationFailures)
            completion?([])
            return nil
        }

        let targetWorkID = targetWork?.uuid
        let requestIDs = Set(requests.map(\.uuid))
        pendingMetadataUUIDs.formUnion(requestIDs)
        preparingImportUUIDs.formUnion(requestIDs)
        activeImportOperationCount += 1
        let session = ImportSession(requestedBookIDs: requestIDs)
        session.recordFailures(validationFailures)
        session.discover(requestIDs)
        activeImportSessions[session.id] = session
        let leaseStore = importSourceLeases
        let task = Task { [weak self, requests, session, leaseStore] in
            guard let self else {
                Self.cleanupOwnedSources(
                    requests.map(\.source),
                    using: leaseStore
                )
                completion?([])
                return
            }
            var completedBooks: [Book] = []
            defer {
                activeImportOperationCount -= 1
                session.finish(as: Task.isCancelled ? .cancelled : .completed)
                if activeImportSessions[session.id] === session {
                    activeImportSessions.removeValue(forKey: session.id)
                }
                Self.cleanupOwnedSources(
                    requests.map(\.source),
                    using: leaseStore
                )
                completion?(completedBooks)
            }

            var importedBookIDs: [UUID] = []
            var reviewBookIDs: Set<UUID> = []
            var importFailures = validationFailures
            var pendingRecoveryCount = 0
            var nextIndex = 0
            while nextIndex < requests.count,
                  !Task.isCancelled,
                  activeImportSessions[session.id] === session {
                let end = min(nextIndex + importCommitChunkSize, requests.count)
                let requestChunk = Array(requests[nextIndex..<end])
                session.advance(to: .staging)
                let outcomes = await prepareImports(requestChunk)
                session.advance(to: .inspection)
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
                    case .failed(let failure):
                        let id = failure.requestedBookID
                        if let id {
                            preparingImportUUIDs.remove(id)
                            cancelledImportUUIDs.remove(id)
                            pendingMetadataUUIDs.remove(id)
                        }
                        importFailures.append(failure)
                    case .cancelled(let id):
                        preparingImportUUIDs.remove(id)
                        cancelledImportUUIDs.remove(id)
                        pendingMetadataUUIDs.remove(id)
                    }
                }
                if Task.isCancelled
                    || activeImportSessions[session.id] !== session {
                    await abort(prepared.flatMap(\.transactions))
                    break
                }

                let chunkResult = await commitPreparedImports(
                    prepared,
                    assigningTo: targetWorkID,
                    session: session
                )
                importedBookIDs.append(contentsOf: chunkResult.importedBookIDs)
                reviewBookIDs.formUnion(chunkResult.reviewBookIDs)
                preparingImportUUIDs.subtract(prepared.map(\.request.uuid))
                pendingRecoveryCount += chunkResult.failures.count {
                    $0.reason == .recoveryDeferred
                }
                importFailures.append(contentsOf: chunkResult.failures)
                pendingMetadataUUIDs.subtract(prepared.map(\.request.uuid))

                for request in requestChunk {
                    pendingSourcePaths.remove(
                        request.sourceURL.standardizedFileURL.path(percentEncoded: false)
                    )
                }
                if chunkResult.targetUnavailable {
                    let remaining = requests[end...]
                    for request in remaining {
                        importFailures.append(ImportFailure(
                            sourceURL: request.sourceURL,
                            requestedBookID: request.uuid,
                            reason: .catalog,
                            detail: "The requested target work is no longer available."
                        ))
                        preparingImportUUIDs.remove(request.uuid)
                        cancelledImportUUIDs.remove(request.uuid)
                        pendingMetadataUUIDs.remove(request.uuid)
                        pendingSourcePaths.remove(
                            request.sourceURL.standardizedFileURL.path(percentEncoded: false)
                        )
                    }
                    break
                }
                nextIndex = end
                await Task.yield()
            }

            if Task.isCancelled
                || activeImportSessions[session.id] !== session {
                for request in requests[nextIndex...] {
                    preparingImportUUIDs.remove(request.uuid)
                    cancelledImportUUIDs.remove(request.uuid)
                    pendingMetadataUUIDs.remove(request.uuid)
                    pendingSourcePaths.remove(
                        request.sourceURL.standardizedFileURL.path(percentEncoded: false)
                    )
                }
            }

            guard !Task.isCancelled,
                  activeImportSessions[session.id] === session else {
                return
            }
            let uniqueImportedBookIDs = Array(Set(importedBookIDs))
            session.advance(to: .derivedJobs)
            if targetWorkID != nil, !uniqueImportedBookIDs.isEmpty {
                editions?.refreshEditionCounts()
            }
            let batchID: UUID?
            if targetWorkID == nil, editions != nil, !reviewBookIDs.isEmpty {
                let id = UUID()
                matchBatches[id] = MatchBatch(
                    bookIDs: Array(reviewBookIDs),
                    remaining: reviewBookIDs
                )
                batchID = id
            } else {
                batchID = nil
            }
            for bookID in uniqueImportedBookIDs {
                enqueueMetadataJob(
                    bookID: bookID,
                    requiresLocalAnalysis: false,
                    evaluateMatch: reviewBookIDs.contains(bookID) && batchID == nil,
                    matchBatchID: reviewBookIDs.contains(bookID) ? batchID : nil
                )
            }

            var imported: [Book] = []
            for bookID in uniqueImportedBookIDs {
                do {
                    imported.append(try mutations.book(id: bookID))
                } catch {
                    importFailures.append(ImportFailure(
                        sourceURL: nil,
                        requestedBookID: bookID,
                        reason: .catalog,
                        detail: error.localizedDescription
                    ))
                }
            }
            session.recordFailures(
                Array(importFailures.dropFirst(validationFailures.count))
            )
            lastImportFailures = importFailures
            await persistImportFailures(importFailures)
            reportImportFailures(importFailures)
            if pendingRecoveryCount > 0 {
                toasts.error(String(
                    localized: "Some imported files are waiting for recovery (\(pendingRecoveryCount))."
                ))
            }
            completedBooks = imported
        }
        session.start(task)
        return session
    }

    private func cleanupOwnedSource(_ source: ImportSource) {
        Self.cleanupOwnedSources([source], using: importSourceLeases)
    }

    nonisolated private static func cleanupOwnedSources(
        _ sources: [ImportSource],
        using leaseStore: ImportSourceLeaseStore
    ) {
        for lease in sources.compactMap(\.ownedLease) {
            do {
                try leaseStore.remove(lease)
            } catch {
                Log.persistence.error(
                    "Could not clean import source lease \(lease.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
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

    func cancelAllSessions() {
        for session in activeImportSessions.values {
            session.cancel()
        }
        for (bookID, task) in activeMetadataTasks {
            task.cancel()
            analysisCoordinator.cancelAll(for: bookID)
        }
        pendingMetadataUUIDs.subtract(queuedMetadataJobs.map(\.bookID))
        queuedMetadataJobs = []
        matchBatches.removeAll()
    }

    // MARK: - Maintenance

    func backfillMissingSizes() async {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.fileSizeBytes == 0 })
        let fetched: [Book]
        do {
            fetched = try modelContext.fetch(descriptor)
            lastMaintenanceError = nil
        } catch {
            reportMaintenanceFetchFailure(error, operation: "file-size backfill")
            return
        }
        let snapshots = fetched
            .filter(\.hasCatalogDigitalFile)
            .compactMap(BookAnalysisSnapshot.init(book:))
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
        let legacyDescriptor = FetchDescriptor<Book>(
            predicate: #Predicate { $0.drmProtected == nil }
        )
        var assetDescriptor = FetchDescriptor<BookAsset>(
            predicate: #Predicate { $0.drmProtected == nil }
        )
        assetDescriptor.relationshipKeyPathsForPrefetching = [\BookAsset.book]
        let fetched: [Book]
        do {
            let legacyBooks = try modelContext.fetch(legacyDescriptor)
            let assetBooks = try modelContext.fetch(assetDescriptor).compactMap(\.book)
            fetched = Array(
                Dictionary(
                    (legacyBooks + assetBooks).map { ($0.uuid, $0) },
                    uniquingKeysWith: { first, _ in first }
                ).values
            )
            lastMaintenanceError = nil
        } catch {
            reportMaintenanceFetchFailure(error, operation: "DRM backfill")
            return
        }
        let snapshots = fetched
            .filter {
                $0.hasCatalogDigitalFile
                    && ($0.primaryAsset?.drmProtected ?? $0.drmProtected) == nil
            }
            .compactMap(BookAnalysisSnapshot.init(book:))
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

            var valid: [(
                BookAnalysisSnapshot,
                CatalogAssetInspectionProposal<Bool>,
                Book,
                BookAsset?
            )] = []
            for result in completed {
                let snapshot = result.job.snapshot
                guard analysisCoordinator.isCurrent(result.job.ticket),
                      result.proposal.sourceIsCurrent(for: snapshot),
                      let book = try? mutations.book(id: snapshot.bookID),
                      snapshot.matches(book) else { continue }
                let asset = snapshot.assetID.flatMap { id in
                    book.assets.first(where: { $0.uuid == id })
                }
                guard (asset?.drmProtected ?? book.drmProtected) == nil else { continue }
                valid.append((snapshot, result.proposal, book, asset))
            }

            if !valid.isEmpty {
                let preimages = valid.map { CatalogBookMetadataPreimage($0.2) }
                let assetPreimages = valid.compactMap { $0.3 }.map(CatalogBookAssetPreimage.init)
                let bookIDs = Set(valid.map { $0.0.bookID })
                do {
                    try mutations.commit(
                        .applyAnalysisBatch(bookIDs: Array(bookIDs), kind: .drmInspection),
                        affectedBookIDs: bookIDs,
                        revertingOnFailure: {
                            preimages.forEach { $0.restore() }
                            assetPreimages.forEach { $0.restore() }
                        }
                    ) {
                        for (snapshot, proposal, _, _) in valid {
                            let book = try mutations.book(id: snapshot.bookID)
                            guard snapshot.matches(book),
                                  proposal.sourceIsCurrent(for: snapshot) else {
                                throw CatalogMutationError.staleAnalysis
                            }
                            if let assetID = snapshot.assetID,
                               let asset = book.assets.first(where: { $0.uuid == assetID }) {
                                guard asset.drmProtected == nil else {
                                    throw CatalogMutationError.staleAnalysis
                                }
                                asset.drmProtected = proposal.value
                            } else {
                                guard book.drmProtected == nil else {
                                    throw CatalogMutationError.staleAnalysis
                                }
                                book.drmProtected = proposal.value
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

    func rescanMissingMetadata() async {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.title == nil })
        let fetched: [Book]
        do {
            fetched = try modelContext.fetch(descriptor)
            lastMaintenanceError = nil
        } catch {
            reportMaintenanceFetchFailure(error, operation: "metadata rescan")
            return
        }
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
        let accessing = request.sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { request.sourceURL.stopAccessingSecurityScopedResource() }
        }

        var transactions: [ManagedFileTransaction] = []
        do {
            try Task.checkCancellation()
            let discovered = try ImportSourceDiscovery.discover(request.sourceURL)
            let source = try ManagedFileSource.book(
                sourceURL: discovered.url,
                destination: .newAsset(assetID: request.uuid)
            )
            let fileTransaction = try await managedFiles.stage(
                intent: .importBook,
                sources: [source],
                requirement: ManagedFileRequirement(
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

            return .prepared(PreparedImport(
                request: request,
                inspection: inspection,
                fileTransaction: fileTransaction
            ))
        } catch is CancellationError {
            for transaction in transactions { await managedFiles.abort(transaction) }
            return .cancelled(request.uuid)
        } catch let error as ImportSourceDiscoveryError {
            for transaction in transactions { await managedFiles.abort(transaction) }
            let reason: ImportFailureReason = switch error {
            case .unsupportedFormat:
                .unsupportedFormat
            case .invalidURL, .unreadable:
                .unreadableSource
            case .symbolicLink, .notRegularFile:
                .validation
            }
            return .failed(ImportFailure(
                sourceURL: request.sourceURL,
                requestedBookID: request.uuid,
                reason: reason,
                detail: error.localizedDescription
            ))
        } catch {
            for transaction in transactions { await managedFiles.abort(transaction) }
            return .failed(ImportFailure(
                sourceURL: request.sourceURL,
                requestedBookID: request.uuid,
                reason: .staging,
                detail: error.localizedDescription
            ))
        }
    }

    private func commitPreparedImports(
        _ prepared: [PreparedImport],
        assigningTo targetWorkID: UUID?,
        session: ImportSession
    ) async -> ImportChunkResult {
        guard !prepared.isEmpty else { return ImportChunkResult() }
        guard !modelContext.hasChanges else {
            await abort(prepared.flatMap(\.transactions))
            return ImportChunkResult(failures: importFailures(
                for: prepared,
                reason: .catalog,
                detail: CatalogMutationError.dirtyContext.localizedDescription
            ))
        }

        if let targetWorkID {
            do {
                let work = try mutations.work(id: targetWorkID)
                guard work.modelContext != nil else {
                    throw CatalogMutationError.modelNotFound
                }
            } catch {
                await abort(prepared.flatMap(\.transactions))
                return ImportChunkResult(
                    failures: importFailures(
                        for: prepared,
                        reason: .catalog,
                        detail: error.localizedDescription
                    ),
                    targetUnavailable: true
                )
            }
        }

        session.advance(to: .reconciliation)
        let baseReconciler: ImportReconciler
        do {
            baseReconciler = try identityIndex.reconciler()
        } catch {
            Log.persistence.error(
                "Import reconciliation index failed: \(String(describing: error), privacy: .public)"
            )
            await abort(prepared.flatMap(\.transactions))
            return ImportChunkResult(failures: importFailures(
                for: prepared,
                reason: .catalog,
                detail: error.localizedDescription
            ))
        }
        var reconciler = baseReconciler
        var proposals: [(PreparedImport, ImportModelProposal)] = []
        var result = ImportChunkResult()
        for candidate in prepared {
            let reconciliationCandidate = candidate.reconciliationCandidate
            let proposal = await ImportProposalBuilder.build(
                candidate: reconciliationCandidate,
                using: reconciler,
                assigningTo: targetWorkID
            )
            if case .exactDuplicate = proposal.reconciliation {
                await abort(candidate.transactions)
            } else {
                proposals.append((candidate, proposal))
                reconciler.record(
                    reconciliationCandidate,
                    reconciliation: proposal.reconciliation
                )
            }
        }
        guard !proposals.isEmpty else { return result }

        session.advance(to: .modelProposal)
        let createdBookIDs = Set(proposals.compactMap { candidate -> UUID? in
            switch candidate.1.reconciliation {
            case .createAnotherEdition, .createNewWork, .ambiguousReview:
                candidate.1.candidate.proposedBookID
            case .exactDuplicate, .addFormatToEdition:
                nil
            }
        })
        var resolved: [ResolvedPreparedImport] = []
        var coveredBookIDs: Set<UUID> = []
        do {
            for (candidate, proposal) in proposals {
                let existingReference: CoverReference? = switch proposal.reconciliation {
                case .addFormatToEdition(let existingBookID, _):
                    if createdBookIDs.contains(existingBookID) {
                        nil
                    } else {
                        try mutations.book(id: existingBookID).coverReference
                    }
                case .createAnotherEdition, .createNewWork, .ambiguousReview:
                    nil
                case .exactDuplicate:
                    nil
                }
                let editionOwner = CoverOwner.edition(proposal.targetBookID)
                let shouldPublishCover = candidate.inspection.coverJPEGData != nil
                    && (existingReference == nil
                        || existingReference == CoverReference(
                            owner: editionOwner,
                            version: 0
                        ))
                    && coveredBookIDs.insert(proposal.targetBookID).inserted
                let coverMutation: PreparedCoverMutation?
                if shouldPublishCover, let coverData = candidate.inspection.coverJPEGData {
                    coverMutation = try await coverMutations.prepare(
                        payload: coverData,
                        targetReference: CoverReference(
                            owner: editionOwner,
                            version: (existingReference?.version ?? 0) + 1
                        ),
                        selectedBookIDs: [proposal.targetBookID],
                        expectedBookReferences: existingReference.map {
                            [proposal.targetBookID: $0]
                        } ?? [:],
                        priority: .system,
                        intent: .importBook,
                        targetMayBeCreated: existingReference == nil
                    )
                } else {
                    coverMutation = nil
                }
                resolved.append(ResolvedPreparedImport(
                    prepared: candidate,
                    proposal: proposal,
                    coverMutation: coverMutation
                ))
            }
        } catch {
            Log.persistence.error(
                "Import cover preparation failed: \(String(describing: error), privacy: .public)"
            )
            await abort(prepared.flatMap(\.transactions))
            await abortCoverMutations(resolved.compactMap(\.coverMutation))
            result.failures.append(contentsOf: importFailures(
                for: proposals.map(\.0),
                reason: .staging,
                detail: error.localizedDescription
            ))
            return result
        }

        var requiredBookIDs = Set(resolved.compactMap { candidate -> UUID? in
            guard case .addFormatToEdition(let existingBookID, _) =
                candidate.proposal.reconciliation else { return nil }
            return existingBookID
        })
        requiredBookIDs.subtract(createdBookIDs)
        let createdWorkIDs = Set(resolved.compactMap { candidate -> UUID? in
            switch candidate.proposal.reconciliation {
            case .createNewWork, .ambiguousReview:
                candidate.proposal.candidate.proposedWorkID
            case .exactDuplicate, .addFormatToEdition, .createAnotherEdition:
                nil
            }
        })
        var requiredWorkIDs = Set(resolved.compactMap { candidate -> UUID? in
            guard case .createAnotherEdition(let workID) =
                candidate.proposal.reconciliation else { return nil }
            return workID
        })
        requiredWorkIDs.subtract(createdWorkIDs)
        var bookPreimages: [UUID: ImportedBookPreimage] = [:]
        var workPreimages: [UUID: ImportedWorkPreimage] = [:]
        let targetBookIDsByRequestID = Dictionary(
            uniqueKeysWithValues: resolved.map {
                ($0.prepared.request.uuid, $0.proposal.targetBookID)
            }
        )
        let affectedBookIDs = Set(targetBookIDsByRequestID.values)
        let affectedWorkIDs = Set(resolved.compactMap { candidate -> UUID? in
            switch candidate.proposal.reconciliation {
            case .addFormatToEdition(_, let workID):
                workID
            case .createAnotherEdition(let workID):
                workID
            case .createNewWork, .ambiguousReview:
                candidate.proposal.candidate.proposedWorkID
            case .exactDuplicate:
                nil
            }
        })

        do {
            session.advance(to: .chunkCommit)
            let preparedCovers = resolved.compactMap(\.coverMutation)
            let commit = try await coverMutations.commit(
                preparedCovers,
                command: .importBooks(bookIDs: Array(affectedBookIDs)),
                additionalTransactions: resolved.flatMap(\.prepared.transactions),
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs,
                revertingOnFailure: {
                    for preimage in bookPreimages.values {
                        preimage.book.assets = preimage.assets
                    }
                    for preimage in workPreimages.values {
                        preimage.work.editions = preimage.editions
                        preimage.work.preferredEditionUUID = preimage.preferredEditionUUID
                    }
                }
            ) {
                if let targetWorkID {
                    let target = try self.mutations.work(id: targetWorkID)
                    guard target.modelContext != nil else {
                        throw CatalogMutationError.modelNotFound
                    }
                }

                var booksByID = Dictionary(
                    uniqueKeysWithValues: try requiredBookIDs.map {
                        let book = try self.mutations.book(id: $0)
                        return (book.uuid, book)
                    }
                )
                var worksByID = Dictionary(
                    uniqueKeysWithValues: try requiredWorkIDs.map {
                        let work = try self.mutations.work(id: $0)
                        return (work.uuid, work)
                    }
                )

                for candidate in resolved {
                    let prepared = candidate.prepared
                    let proposal = candidate.proposal
                    let inspection = prepared.inspection
                    let book: Book
                    switch proposal.reconciliation {
                    case .exactDuplicate:
                        continue

                    case .addFormatToEdition(let existingBookID, _):
                        guard let existing = booksByID[existingBookID] else {
                            throw CatalogMutationError.modelNotFound
                        }
                        if !createdBookIDs.contains(existingBookID),
                           bookPreimages[existingBookID] == nil {
                            bookPreimages[existingBookID] = ImportedBookPreimage(
                                book: existing,
                                assets: existing.assets
                            )
                        }
                        book = existing

                    case .createAnotherEdition(let workID):
                        guard let work = worksByID[workID] else {
                            throw CatalogMutationError.modelNotFound
                        }
                        if !createdWorkIDs.contains(workID),
                           workPreimages[workID] == nil {
                            workPreimages[workID] = ImportedWorkPreimage(
                                work: work,
                                editions: work.editions,
                                preferredEditionUUID: work.preferredEditionUUID
                            )
                        }
                        book = self.makeImportedBook(from: prepared, work: work)
                        booksByID[book.uuid] = book

                    case .createNewWork, .ambiguousReview:
                        let work = Work(
                            uuid: proposal.candidate.proposedWorkID,
                            title: inspection.metadata.title,
                            author: inspection.metadata.author
                        )
                        self.modelContext.insert(work)
                        worksByID[work.uuid] = work
                        book = self.makeImportedBook(from: prepared, work: work)
                        booksByID[book.uuid] = book
                    }

                    let asset = BookAsset(
                        uuid: inspection.assetID,
                        fileName: inspection.managedFileName,
                        origin: .original,
                        sourceProvenance: .directImport,
                        contentHash: inspection.sha256,
                        sizeBytes: inspection.sizeBytes,
                        drmProtected: inspection.drmProtected,
                        dateAdded: book.dateAdded,
                        validationStatus: inspection.validation,
                        book: book
                    )
                    self.modelContext.insert(asset)
                }
            }
            session.advance(to: .publishing)
            let pending = Set(commit.pendingTransactionIDs)
            for candidate in resolved {
                let prepared = candidate.prepared
                if candidate.transactions.contains(where: { pending.contains($0.id) }) {
                    result.failures.append(ImportFailure(
                        sourceURL: prepared.request.sourceURL,
                        requestedBookID: prepared.request.uuid,
                        reason: .recoveryDeferred,
                        detail: "The catalog commit succeeded, but managed-file publication is pending recovery."
                    ))
                    continue
                }
                guard let bookID = targetBookIDsByRequestID[prepared.request.uuid] else {
                    continue
                }
                result.importedBookIDs.append(bookID)
                if case .ambiguousReview = candidate.proposal.reconciliation {
                    result.reviewBookIDs.append(bookID)
                }
            }
            return result
        } catch {
            Log.persistence.error(
                "Import catalog commit failed: \(String(describing: error), privacy: .public)"
            )
            result.failures.append(contentsOf: importFailures(
                for: resolved.map(\.prepared),
                reason: .catalog,
                detail: error.localizedDescription
            ))
            return result
        }
    }

    private func makeImportedBook(
        from candidate: PreparedImport,
        work: Work
    ) -> Book {
        let inspection = candidate.inspection
        let book = Book(
            uuid: candidate.request.uuid,
            fileName: inspection.managedFileName,
            originalFileName: candidate.request.originalName
        )
        book.fileSizeBytes = inspection.sizeBytes
        book.drmProtected = inspection.drmProtected
        book.apply(inspection.metadata)
        modelContext.insert(book)
        book.work = work
        if work.preferredEditionUUID == nil { work.preferredEditionUUID = book.uuid }
        refreshWorkIdentity(
            for: book,
            allowDisplayTitleFallback: !settings.onlineMetadataEnabled
        )
        return book
    }

    private func abort(_ transactions: [ManagedFileTransaction]) async {
        for transaction in transactions { await managedFiles.abort(transaction) }
    }

    private func abortCoverMutations(
        _ prepared: [PreparedCoverMutation]
    ) async {
        for mutation in prepared {
            await coverMutations.abort(mutation)
        }
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
                if let assetID = snapshot.assetID,
                   let asset = storedBook.assets.first(where: { $0.uuid == assetID }) {
                    asset.drmProtected = proposal.value.drmProtected
                    asset.validationStatus = proposal.value.validation
                } else {
                    storedBook.drmProtected = proposal.value.drmProtected
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
        mutations.editionIdentity.seedWorkIdentityIfMissing(from: book, work: work)
        if allowDisplayTitleFallback,
           work.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            work.title = book.displayTitle
            work.refreshMatchKey()
        }
    }

    private func importFailures(
        for prepared: [PreparedImport],
        reason: ImportFailureReason,
        detail: String
    ) -> [ImportFailure] {
        prepared.map {
            ImportFailure(
                sourceURL: $0.request.sourceURL,
                requestedBookID: $0.request.uuid,
                reason: reason,
                detail: detail
            )
        }
    }

    private func reportMaintenanceFetchFailure(
        _ error: Error,
        operation: String
    ) {
        lastMaintenanceError = error.localizedDescription
        Log.persistence.error(
            "Catalog \(operation, privacy: .public) fetch failed: \(error.localizedDescription, privacy: .public)"
        )
    }

    private func reportImportFailures(_ failures: [ImportFailure]) {
        let actionable = failures.filter { $0.reason != .recoveryDeferred }
        guard !actionable.isEmpty else { return }
        for failure in actionable {
            Log.persistence.error(
                "Import failed [\(failure.reason.rawValue, privacy: .public)] \(failure.sourceURL?.lastPathComponent ?? "unknown", privacy: .public): \(failure.detail, privacy: .public)"
            )
        }
        let reasons = Set(actionable.map(\.reason))
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.localizedLabel)
            .joined(separator: ", ")
        toasts.error(
            String(localized: "Some files couldn\u{2019}t be imported (\(actionable.count)).")
                + " " + reasons
        )
    }

    private func persistImportFailures(_ failures: [ImportFailure]) async {
        do {
            importRecoveryItems = try await recoveryQueue.record(failures)
            lastRecoveryQueueError = nil
        } catch {
            // The import result is already authoritative. Failure to update
            // its review queue must never reclassify a committed import.
            lastRecoveryQueueError = error.localizedDescription
            Log.persistence.error(
                "Could not persist the import recovery queue: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func scheduleImportFailurePersistence(_ failures: [ImportFailure]) {
        let previous = recoveryQueueWriteTask
        recoveryQueueWriteTask = Task { [weak self] in
            await previous?.value
            await self?.persistImportFailures(failures)
        }
    }
}

extension ImportFailureReason {
    var localizedLabel: String {
        switch self {
        case .unsupportedFormat:
            String(localized: "Unsupported format")
        case .unreadableSource:
            String(localized: "Unreadable source")
        case .staging:
            String(localized: "File staging failed")
        case .validation:
            String(localized: "Source validation failed")
        case .catalog:
            String(localized: "Catalog update failed")
        case .recoveryDeferred:
            String(localized: "Recovery deferred")
        }
    }
}
