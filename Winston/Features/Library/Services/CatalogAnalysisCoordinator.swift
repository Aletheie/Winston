import Foundation
import OSLog
import SwiftData

nonisolated enum CatalogAnalysisJobKind: Hashable, Sendable {
    case metadataExtraction
    case onlineEnrichment
    case pageCount
    case fileSize
    case drmInspection
    case assetHash(assetID: UUID)
    case assetInspection(assetID: UUID)

    var label: String {
        switch self {
        case .metadataExtraction: "metadata-extraction"
        case .onlineEnrichment: "online-enrichment"
        case .pageCount: "page-count"
        case .fileSize: "file-size"
        case .drmInspection: "drm-inspection"
        case .assetHash: "asset-hash"
        case .assetInspection: "asset-inspection"
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
        primaryFileName = book.fileName
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
              book.fileName == primaryFileName,
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
        let matches = book.assets.filter { $0.fileName == book.fileName }
        return matches.first(where: { $0.uuid == book.uuid })
            ?? matches.min { $0.uuid.uuidString < $1.uuid.uuidString }
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
}

nonisolated struct CatalogAnalysisJob<Proposal: Sendable>: Sendable {
    let ticket: CatalogAnalysisTicket
    let snapshot: BookAnalysisSnapshot
    fileprivate let task: Task<Proposal?, Never>
}

/// Owns one cancellable worker per `(bookID, jobKind)`. Superseded tasks may
/// finish if an injected/system API ignores cancellation, but their ticket can
/// no longer authorize a catalog commit.
@MainActor
final class CatalogAnalysisCoordinator {
    private struct Key: Hashable {
        let bookID: UUID
        let kind: CatalogAnalysisJobKind
    }

    private struct Entry {
        let ticket: CatalogAnalysisTicket
        let cancel: @Sendable () -> Void
    }

    private var entries: [Key: Entry] = [:]

    var activeJobCount: Int { entries.count }

    func start<Proposal: Sendable>(
        snapshot: BookAnalysisSnapshot,
        kind: CatalogAnalysisJobKind,
        operation: @escaping @Sendable (BookAnalysisSnapshot) async -> Proposal?
    ) -> CatalogAnalysisJob<Proposal> {
        let key = Key(bookID: snapshot.bookID, kind: kind)
        cancelEntry(for: key, reason: "superseded")

        let ticket = CatalogAnalysisTicket(
            bookID: snapshot.bookID,
            kind: kind,
            generation: UUID()
        )
        let task = Task {
            let signposter = Log.metadataSignposter
            let interval = signposter.beginInterval(
                "CatalogAnalysis",
                id: signposter.makeSignpostID(),
                "\(kind.label, privacy: .public) \(snapshot.bookID.uuidString, privacy: .public)"
            )
            defer { signposter.endInterval("CatalogAnalysis", interval) }
            return await operation(snapshot)
        }
        entries[key] = Entry(ticket: ticket, cancel: { task.cancel() })
        return CatalogAnalysisJob(ticket: ticket, snapshot: snapshot, task: task)
    }

    func value<Proposal: Sendable>(for job: CatalogAnalysisJob<Proposal>) async -> Proposal? {
        let proposal = await withTaskCancellationHandler {
            await job.task.value
        } onCancel: {
            job.task.cancel()
        }
        guard let proposal,
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
        entries[Key(bookID: ticket.bookID, kind: ticket.kind)]?.ticket == ticket
    }

    func finish(_ ticket: CatalogAnalysisTicket) {
        let key = Key(bookID: ticket.bookID, kind: ticket.kind)
        guard entries[key]?.ticket == ticket else { return }
        entries.removeValue(forKey: key)
    }

    func cancelAll(for bookID: UUID) {
        let keys = entries.keys.filter { $0.bookID == bookID }
        for key in keys { cancelEntry(for: key, reason: "catalog-changed") }
    }

    func cancelAll(for bookIDs: Set<UUID>) {
        guard !bookIDs.isEmpty else { return }
        let keys = entries.keys.filter { bookIDs.contains($0.bookID) }
        for key in keys { cancelEntry(for: key, reason: "catalog-changed") }
    }

    private func cancelEntry(for key: Key, reason: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.cancel()
        Log.metadataSignposter.emitEvent(
            "CatalogAnalysisCancelled",
            id: Log.metadataSignposter.makeSignpostID(),
            "\(entry.ticket.kind.label, privacy: .public) \(reason, privacy: .public)"
        )
    }
}
