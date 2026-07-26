import Foundation
import OSLog
import SwiftData

/// Cancellation-aware bounded executor shared by catalog and cover analysis
/// lanes. Waiting tasks do not consume a permit and are resumed exactly once.
actor AsyncPermitPool {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var activeCount = 0
    private var peakActiveCount = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    func usage() -> (active: Int, peak: Int) {
        (activeCount, peakActiveCount)
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if activeCount < limit {
            activeCount += 1
            peakActiveCount = max(peakActiveCount, activeCount)
            return
        }

        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        guard granted else { throw CancellationError() }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume(returning: true)
        } else {
            activeCount = max(0, activeCount - 1)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

nonisolated enum CatalogAnalysisJobKind: Hashable, Sendable {
    case metadataExtraction
    case onlineEnrichment
    case coverExtraction
    case pageCount
    case fileSize
    case drmInspection
    case assetHash(assetID: UUID)
    case assetInspection(assetID: UUID)

    var label: String {
        switch self {
        case .metadataExtraction: "metadata-extraction"
        case .onlineEnrichment: "online-enrichment"
        case .coverExtraction: "cover-extraction"
        case .pageCount: "page-count"
        case .fileSize: "file-size"
        case .drmInspection: "drm-inspection"
        case .assetHash: "asset-hash"
        case .assetInspection: "asset-inspection"
        }
    }

    fileprivate var lane: CatalogAnalysisLane {
        switch self {
        case .onlineEnrichment:
            .network
        case .metadataExtraction, .coverExtraction, .pageCount, .fileSize,
             .drmInspection, .assetHash, .assetInspection:
            .local
        }
    }
}

/// The identity fields that make a local or online result belong to a specific
/// edition/work. Reading progress, notes, ratings and other unrelated state are
/// deliberately absent so they do not invalidate useful analysis.
nonisolated struct BookIdentityRevision: Hashable, Sendable {
    let title: String?
    let author: String?
    let publisher: String?
    let year: String?
    let language: String?
    let translator: String?
    let isbn: String?
    let series: String?
    let seriesIndex: String?
    let editionStatement: String?
    let editionTypeRaw: String?
    let originalFileName: String

    let workID: UUID?
    let workTitle: String?
    let workAuthor: String?
    let workOriginalTitle: String?
    let workOriginalLanguage: String?
    let workMatchKey: String?
    let openLibraryWorkKey: String?
    let hardcoverBookID: String?

    @MainActor
    init(book: Book) {
        title = book.title
        author = book.author
        publisher = book.publisher
        year = book.year
        language = book.language
        translator = book.translator
        isbn = book.isbn
        series = book.series
        seriesIndex = book.seriesIndex
        editionStatement = book.editionStatement
        editionTypeRaw = book.editionTypeRaw
        originalFileName = book.originalFileName

        workID = book.work?.uuid
        workTitle = book.work?.title
        workAuthor = book.work?.author
        workOriginalTitle = book.work?.originalTitle
        workOriginalLanguage = book.work?.originalLanguage
        workMatchKey = book.work?.matchKey
        openLibraryWorkKey = book.work?.openLibraryWorkKey
        hardcoverBookID = book.work?.hardcoverBookID
    }
}

nonisolated struct BookAssetRevision: Hashable, Sendable {
    let id: UUID
    let fileName: String
    let dateAdded: Date
    let contentHash: String?

    @MainActor
    init(_ asset: BookAsset) {
        id = asset.uuid
        fileName = asset.fileName
        dateAdded = asset.dateAdded
        contentHash = asset.contentHash
    }
}

/// Generation of the concrete managed source selected for an analysis. It is a
/// value token rather than a live file/model lease, so it can safely cross
/// suspension points and be compared again during the catalog commit.
nonisolated struct BookAnalysisSourceGeneration: Hashable, Sendable {
    let primaryFileName: String
    let primaryAsset: BookAssetRevision?
    let sourceAsset: BookAssetRevision?
}

/// Immutable input authority for every long-running catalog analysis. A
/// proposal may be committed only while every value still matches the catalog.
nonisolated struct BookAnalysisSnapshot: Hashable, Sendable {
    let bookID: UUID
    let primaryFileName: String
    let primaryAsset: BookAssetRevision?
    let sourceAsset: BookAssetRevision?
    let identityRevision: BookIdentityRevision
    let lookupISBN: String?
    let lookupTitle: String
    let lookupAuthor: String?

    var assetID: UUID? { sourceAsset?.id }
    var fileName: String { sourceAsset?.fileName ?? primaryFileName }
    var assetDateAdded: Date? { sourceAsset?.dateAdded }
    var contentHash: String? { sourceAsset?.contentHash }
    var fileURL: URL? { BookFileStore.validatedURL(for: fileName) }
    var sourceGeneration: BookAnalysisSourceGeneration {
        BookAnalysisSourceGeneration(
            primaryFileName: primaryFileName,
            primaryAsset: primaryAsset,
            sourceAsset: sourceAsset
        )
    }
    var identityGeneration: BookIdentityRevision { identityRevision }

    @MainActor
    init?(book: Book) {
        guard book.modelContext != nil else { return nil }
        let primary = Self.primaryAsset(in: book)
        self.init(book: book, primary: primary, source: primary)
    }

    @MainActor
    init?(book: Book, sourceAsset: BookAsset) {
        guard book.modelContext != nil,
              sourceAsset.modelContext != nil,
              (sourceAsset.book?.uuid == book.uuid
                  || book.assets.contains(where: { $0.uuid == sourceAsset.uuid })) else { return nil }
        self.init(book: book, primary: Self.primaryAsset(in: book), source: sourceAsset)
    }

    @MainActor
    private init(book: Book, primary: BookAsset?, source: BookAsset?) {
        bookID = book.uuid
        primaryFileName = primary?.fileName ?? book.fileName
        primaryAsset = primary.map(BookAssetRevision.init)
        sourceAsset = source.map(BookAssetRevision.init)
        identityRevision = BookIdentityRevision(book: book)
        lookupISBN = book.isbn
        lookupTitle = book.displayTitle
        lookupAuthor = book.displayAuthor
    }

    @MainActor
    func matches(_ book: Book) -> Bool {
        guard book.modelContext != nil,
              book.uuid == bookID,
              (book.primaryAsset?.fileName ?? book.fileName) == primaryFileName,
              BookIdentityRevision(book: book) == identityRevision,
              Self.primaryAsset(in: book).map(BookAssetRevision.init) == primaryAsset
        else { return false }

        guard let sourceAsset else { return true }
        guard let liveAsset = book.assets.first(where: { $0.uuid == sourceAsset.id }),
              liveAsset.modelContext != nil,
              (liveAsset.book?.uuid == bookID
                  || book.assets.contains(where: { $0.uuid == liveAsset.uuid })) else { return false }
        return BookAssetRevision(liveAsset) == sourceAsset
    }

    @MainActor
    private static func primaryAsset(in book: Book) -> BookAsset? {
        book.primaryAsset
    }
}

/// Cheap filesystem generation check surrounding the actual worker. It closes
/// the gap where a managed file is atomically replaced without the worker ever
/// observing the new path contents.
nonisolated struct CatalogFileGeneration: Equatable, Sendable {
    let resourceIdentifier: String?
    let modificationDate: Date?
    let fileSize: Int64

    static func capture(at url: URL) -> CatalogFileGeneration? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
              let values = try? url.resourceValues(forKeys: [
                  .fileResourceIdentifierKey,
                  .contentModificationDateKey,
                  .fileSizeKey,
              ]) else { return nil }
        return CatalogFileGeneration(
            resourceIdentifier: values.fileResourceIdentifier.map { String(reflecting: $0) },
            modificationDate: values.contentModificationDate,
            fileSize: Int64(values.fileSize ?? -1)
        )
    }
}

nonisolated struct CatalogAssetInspectionProposal<Value: Sendable>: Sendable {
    let value: Value
    let finalFileGeneration: CatalogFileGeneration

    func sourceIsCurrent(for snapshot: BookAnalysisSnapshot) -> Bool {
        guard let url = snapshot.fileURL else { return false }
        return CatalogFileGeneration.capture(at: url) == finalFileGeneration
    }
}

nonisolated enum CatalogAnalysisWorker {
    /// Runs without a live SwiftData model and rejects a file that changes while
    /// the analyzer is suspended or reading it.
    @concurrent
    static func inspect<Value: Sendable>(
        snapshot: BookAnalysisSnapshot,
        operation: @escaping @Sendable (URL) async -> Value?
    ) async -> CatalogAssetInspectionProposal<Value>? {
        guard !Task.isCancelled,
              let url = snapshot.fileURL,
              let before = CatalogFileGeneration.capture(at: url) else { return nil }
        guard let value = await operation(url), !Task.isCancelled,
              let after = CatalogFileGeneration.capture(at: url),
              before == after else { return nil }
        return CatalogAssetInspectionProposal(value: value, finalFileGeneration: after)
    }
}

nonisolated struct CatalogAnalysisTicket: Hashable, Sendable {
    let bookID: UUID
    let kind: CatalogAnalysisJobKind
    fileprivate let generation: UUID
    fileprivate let leaseID: UUID
}

nonisolated struct CatalogAnalysisJob<Proposal: Sendable>: Sendable {
    let ticket: CatalogAnalysisTicket
    let snapshot: BookAnalysisSnapshot
    fileprivate let task: Task<Proposal?, Never>
}

nonisolated struct CatalogAnalysisSchedulerDiagnostics: Equatable, Sendable {
    let activeLocalJobs: Int
    let peakLocalJobs: Int
    let activeNetworkJobs: Int
    let peakNetworkJobs: Int
}

private nonisolated enum CatalogAnalysisLane: Sendable {
    case local
    case network
}

/// Bounded execution owner shared by import, maintenance, detail and explicit
/// refresh analysis. Cover decoding keeps its finer I/O/CPU permit split, while
/// catalog-level cover jobs still enter through the local lane here.
private actor CatalogAnalysisScheduler {
    private let localPermits: AsyncPermitPool
    private let networkPermits: AsyncPermitPool

    init(maximumConcurrentLocalJobs: Int, maximumConcurrentNetworkJobs: Int) {
        localPermits = AsyncPermitPool(limit: maximumConcurrentLocalJobs)
        networkPermits = AsyncPermitPool(limit: maximumConcurrentNetworkJobs)
    }

    func run<Proposal: Sendable>(
        kind: CatalogAnalysisJobKind,
        operation: @escaping @Sendable () async -> Proposal?
    ) async -> Proposal? {
        do {
            switch kind.lane {
            case .local:
                return try await localPermits.run(operation)
            case .network:
                return try await networkPermits.run(operation)
            }
        } catch {
            return nil
        }
    }

    func diagnostics() async -> CatalogAnalysisSchedulerDiagnostics {
        let local = await localPermits.usage()
        let network = await networkPermits.usage()
        return CatalogAnalysisSchedulerDiagnostics(
            activeLocalJobs: local.active,
            peakLocalJobs: local.peak,
            activeNetworkJobs: network.active,
            peakNetworkJobs: network.peak
        )
    }
}

private protocol CatalogAnalysisTaskBox: AnyObject {
    func cancel()
}

private final class TypedCatalogAnalysisTaskBox<Proposal: Sendable>: CatalogAnalysisTaskBox {
    let task: Task<Proposal?, Never>

    init(task: Task<Proposal?, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

/// Owns one versioned worker per `(bookID, jobKind)`. Equal requests share the
/// same worker and hold independent leases; a changed source/identity/request
/// generation supersedes and cancels the old worker. A late task may still
/// finish if an injected/system API ignores cancellation, but its ticket can no
/// longer authorize a catalog commit.
@MainActor
final class CatalogAnalysisCoordinator {
    private struct Key: Hashable {
        let bookID: UUID
        let kind: CatalogAnalysisJobKind
    }

    private struct Entry {
        let generation: UUID
        let snapshot: BookAnalysisSnapshot
        let requestGeneration: String?
        let taskBox: any CatalogAnalysisTaskBox
        var leases: Set<UUID>
    }

    private var entries: [Key: Entry] = [:]
    private let scheduler: CatalogAnalysisScheduler

    init(
        maximumConcurrentLocalJobs: Int = 4,
        maximumConcurrentNetworkJobs: Int = 4
    ) {
        scheduler = CatalogAnalysisScheduler(
            maximumConcurrentLocalJobs: max(1, maximumConcurrentLocalJobs),
            maximumConcurrentNetworkJobs: max(1, maximumConcurrentNetworkJobs)
        )
    }

    var activeJobCount: Int { entries.count }
    var activeLeaseCount: Int {
        entries.values.reduce(0) { $0 + $1.leases.count }
    }

    func start<Proposal: Sendable>(
        snapshot: BookAnalysisSnapshot,
        kind: CatalogAnalysisJobKind,
        requestGeneration: String? = nil,
        operation: @escaping @Sendable (BookAnalysisSnapshot) async -> Proposal?
    ) -> CatalogAnalysisJob<Proposal> {
        let key = Key(bookID: snapshot.bookID, kind: kind)
        let leaseID = UUID()
        if var existing = entries[key],
           existing.snapshot == snapshot,
           existing.requestGeneration == requestGeneration,
           let typedBox = existing.taskBox as? TypedCatalogAnalysisTaskBox<Proposal> {
            existing.leases.insert(leaseID)
            entries[key] = existing
            let ticket = CatalogAnalysisTicket(
                bookID: snapshot.bookID,
                kind: kind,
                generation: existing.generation,
                leaseID: leaseID
            )
            Log.metadataSignposter.emitEvent(
                "CatalogAnalysisCoalesced",
                id: Log.metadataSignposter.makeSignpostID(),
                "\(kind.label, privacy: .public) \(snapshot.bookID.uuidString, privacy: .public)"
            )
            return CatalogAnalysisJob(
                ticket: ticket,
                snapshot: snapshot,
                task: typedBox.task
            )
        }
        cancelEntry(for: key, reason: "superseded")

        let generation = UUID()
        let ticket = CatalogAnalysisTicket(
            bookID: snapshot.bookID,
            kind: kind,
            generation: generation,
            leaseID: leaseID
        )
        let scheduler = scheduler
        let task: Task<Proposal?, Never> = Task {
            let signposter = Log.metadataSignposter
            let interval = signposter.beginInterval(
                "CatalogAnalysis",
                id: signposter.makeSignpostID(),
                "\(kind.label, privacy: .public) \(snapshot.bookID.uuidString, privacy: .public)"
            )
            defer { signposter.endInterval("CatalogAnalysis", interval) }
            let proposal: Proposal? = await scheduler.run(kind: kind) {
                guard !Task.isCancelled else { return nil }
                return await operation(snapshot)
            }
            return proposal
        }
        entries[key] = Entry(
            generation: generation,
            snapshot: snapshot,
            requestGeneration: requestGeneration,
            taskBox: TypedCatalogAnalysisTaskBox<Proposal>(task: task),
            leases: [leaseID]
        )
        return CatalogAnalysisJob(ticket: ticket, snapshot: snapshot, task: task)
    }

    func value<Proposal: Sendable>(for job: CatalogAnalysisJob<Proposal>) async -> Proposal? {
        let proposal = await withTaskCancellationHandler {
            await job.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(job.ticket, reason: "consumer-cancelled")
            }
        }
        guard let proposal,
              !Task.isCancelled,
              !job.task.isCancelled,
              isCurrent(job.ticket) else {
            Log.metadataSignposter.emitEvent(
                "CatalogAnalysisDiscarded",
                id: Log.metadataSignposter.makeSignpostID(),
                "\(job.ticket.kind.label, privacy: .public) \(job.ticket.bookID.uuidString, privacy: .public)"
            )
            return nil
        }
        return proposal
    }

    func isCurrent(_ ticket: CatalogAnalysisTicket) -> Bool {
        guard let entry = entries[Key(bookID: ticket.bookID, kind: ticket.kind)] else {
            return false
        }
        return entry.generation == ticket.generation
            && entry.leases.contains(ticket.leaseID)
    }

    func finish(_ ticket: CatalogAnalysisTicket) {
        // Cancelling an already-completed Task is harmless. Doing this
        // unconditionally also stops queued/running work when an owner exits
        // before ever awaiting all of the jobs it started.
        release(
            ticket,
            emitCancellation: false,
            reason: "finished"
        )
    }

    func cancelAll(for bookID: UUID) {
        let keys = entries.keys.filter { $0.bookID == bookID }
        for key in keys { cancelEntry(for: key, reason: "catalog-changed") }
    }

    func cancel(bookID: UUID, kind: CatalogAnalysisJobKind) {
        cancelEntry(
            for: Key(bookID: bookID, kind: kind),
            reason: "owner-cancelled"
        )
    }

    func cancelAll(for bookIDs: Set<UUID>) {
        guard !bookIDs.isEmpty else { return }
        let keys = entries.keys.filter { bookIDs.contains($0.bookID) }
        for key in keys { cancelEntry(for: key, reason: "catalog-changed") }
    }

    func schedulerDiagnostics() async -> CatalogAnalysisSchedulerDiagnostics {
        await scheduler.diagnostics()
    }

    private func cancel(_ ticket: CatalogAnalysisTicket, reason: String) {
        release(
            ticket,
            emitCancellation: true,
            reason: reason
        )
    }

    private func release(
        _ ticket: CatalogAnalysisTicket,
        emitCancellation: Bool,
        reason: String
    ) {
        let key = Key(bookID: ticket.bookID, kind: ticket.kind)
        guard var entry = entries[key],
              entry.generation == ticket.generation,
              entry.leases.remove(ticket.leaseID) != nil else { return }
        guard entry.leases.isEmpty else {
            entries[key] = entry
            return
        }
        entries.removeValue(forKey: key)
        entry.taskBox.cancel()
        if emitCancellation {
            Log.metadataSignposter.emitEvent(
                "CatalogAnalysisCancelled",
                id: Log.metadataSignposter.makeSignpostID(),
                "\(ticket.kind.label, privacy: .public) \(reason, privacy: .public)"
            )
        }
    }

    private func cancelEntry(for key: Key, reason: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.taskBox.cancel()
        Log.metadataSignposter.emitEvent(
            "CatalogAnalysisCancelled",
            id: Log.metadataSignposter.makeSignpostID(),
            "\(key.kind.label, privacy: .public) \(reason, privacy: .public)"
        )
    }
}
