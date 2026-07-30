import Foundation
import OSLog
import SwiftData

@MainActor
struct CatalogSaveAdapter {
    var save: (ModelContext) throws -> Void
    fileprivate let permitsStoreScopedSharing: Bool

    init(_ save: @escaping (ModelContext) throws -> Void) {
        self.save = save
        permitsStoreScopedSharing = false
    }

    private init(
        permitsStoreScopedSharing: Bool,
        save: @escaping (ModelContext) throws -> Void
    ) {
        self.save = save
        self.permitsStoreScopedSharing = permitsStoreScopedSharing
    }

    static let live = CatalogSaveAdapter(permitsStoreScopedSharing: true) {
        try $0.save()
    }
}

nonisolated enum CatalogMutationCheckpoint: Equatable, Sendable {
    case beforeMutation
    case afterMutation
}

@MainActor
struct CatalogMutationHooks {
    var reach: (CatalogMutationCheckpoint) throws -> Void
    fileprivate let permitsStoreScopedSharing: Bool

    init(_ reach: @escaping (CatalogMutationCheckpoint) throws -> Void) {
        self.reach = reach
        permitsStoreScopedSharing = false
    }

    private init(
        permitsStoreScopedSharing: Bool,
        reach: @escaping (CatalogMutationCheckpoint) throws -> Void
    ) {
        self.reach = reach
        self.permitsStoreScopedSharing = permitsStoreScopedSharing
    }

    static let live = CatalogMutationHooks(permitsStoreScopedSharing: true) { _ in }
}

enum CatalogMutationCommand {
    case setReadingStatus(bookIDs: [UUID], status: ReadingStatus)
    case setReadingProgress(bookID: UUID, progress: Double)
    case createCollection(collectionID: UUID, bookIDs: [UUID])
    case updateCollection(collectionID: UUID)
    case deleteCollection(collectionID: UUID)
    case updateMetadata(bookID: UUID, fields: Set<String>)
    case updateMetadataBatch(bookIDs: [UUID], operation: String, fields: Set<String>)
    case assignEdition(bookIDs: [UUID], workID: UUID?)
    case reconcileEditions(survivorID: UUID, removedID: UUID, removesExactDuplicateFiles: Bool)
    case updateWork(workID: UUID, fields: Set<String>)
    case pluginUpdate(bookID: UUID, fields: Set<String>)
    case addPhysicalBook(bookID: UUID, workID: UUID)
    case importBooks(bookIDs: [UUID])
    case calibreImport(bookIDs: [UUID])
    case addFile(bookID: UUID, assetID: UUID)
    case replaceFile(bookID: UUID, assetID: UUID)
    case selectPrimaryAsset(bookID: UUID, assetID: UUID)
    case removeFile(bookID: UUID, assetID: UUID)
    case removeBooks(bookIDs: [UUID])
    case conversionOutput(bookID: UUID, assetID: UUID)
    case legacyMigration(bookIDs: [UUID])
    case updateCover(bookID: UUID, version: Int)
    case applyAnalysis(bookID: UUID, kind: CatalogAnalysisJobKind)
    case applyAnalysisBatch(bookIDs: [UUID], kind: CatalogAnalysisJobKind)
    case updateAssetValidation(assetIDs: [UUID], bookIDs: [UUID])
    case importHighlights(bookIDs: [UUID])
    case maintenanceCleanup(workIDs: [UUID])
    case repairCatalogInvariants(bookIDs: [UUID], workIDs: [UUID])
    case restoreBook(bookID: UUID, fields: CatalogChangeFields, createsBook: Bool)
    case updateAuxiliaryStore(operation: String)

    var changesBookMembership: Bool {
        switch self {
        case .addPhysicalBook, .importBooks, .calibreImport, .removeBooks, .legacyMigration,
             .reconcileEditions:
            true
        case .restoreBook(_, _, let createsBook):
            createsBook
        default:
            false
        }
    }

    var changeFields: CatalogChangeFields {
        switch self {
        case .setReadingStatus, .setReadingProgress:
            [.readingState]

        case .createCollection, .updateCollection, .deleteCollection:
            [.collectionMembership]

        case .updateMetadata(_, let fields),
             .updateMetadataBatch(_, _, let fields),
             .pluginUpdate(_, let fields):
            Self.metadataChangeFields(fields)

        case .updateWork(_, let fields):
            Self.metadataChangeFields(fields).union(.workMembership)

        case .assignEdition:
            [.workMembership]

        case .addFile, .replaceFile, .selectPrimaryAsset, .removeFile, .conversionOutput:
            [.assetAvailability, .displayMetadata, .fullTextSource]

        case .updateCover:
            [.cover]

        case .applyAnalysis(_, let kind),
             .applyAnalysisBatch(_, let kind):
            switch kind {
            case .metadataExtraction, .onlineEnrichment:
                [.identity, .displayMetadata]
            case .coverExtraction:
                [.cover]
            case .assetHash, .assetInspection:
                [.assetAvailability, .fullTextSource]
            case .pageCount:
                [.displayMetadata]
            case .fileSize, .drmInspection:
                [.assetAvailability]
            }

        case .updateAssetValidation:
            [.assetAvailability, .fullTextSource]

        case .importHighlights:
            [.displayMetadata]

        case .maintenanceCleanup:
            [.workMembership]

        case .repairCatalogInvariants:
            .all

        case .restoreBook(_, let fields, _):
            fields

        case .updateAuxiliaryStore:
            []

        case .addPhysicalBook, .importBooks, .calibreImport, .removeBooks, .legacyMigration,
             .reconcileEditions:
            .all
        }
    }

    var changesFullTextIndex: Bool {
        switch self {
        case .reconcileEditions,
             .importBooks,
             .calibreImport,
             .addFile,
             .replaceFile,
             .selectPrimaryAsset,
             .removeFile,
             .removeBooks,
             .conversionOutput,
             .legacyMigration,
             .updateAssetValidation,
             .repairCatalogInvariants:
            true

        case .applyAnalysis(_, let kind),
             .applyAnalysisBatch(_, let kind):
            switch kind {
            case .assetHash, .assetInspection:
                true
            case .metadataExtraction, .onlineEnrichment, .coverExtraction,
                 .pageCount, .fileSize, .drmInspection:
                false
            }

        case .restoreBook(_, let fields, _):
            fields.contains(.fullTextSource)

        case .setReadingStatus,
             .setReadingProgress,
             .createCollection,
             .updateCollection,
             .deleteCollection,
             .updateMetadata,
             .updateMetadataBatch,
             .assignEdition,
             .updateWork,
             .pluginUpdate,
             .addPhysicalBook,
             .updateCover,
             .importHighlights,
             .maintenanceCleanup,
             .updateAuxiliaryStore:
            false
        }
    }

    var affectedAssetIDs: Set<UUID> {
        switch self {
        case .addFile(_, let assetID),
             .replaceFile(_, let assetID),
             .selectPrimaryAsset(_, let assetID),
             .removeFile(_, let assetID),
             .conversionOutput(_, let assetID):
            [assetID]
        case .updateAssetValidation(let assetIDs, _):
            Set(assetIDs)
        default:
            []
        }
    }

    private static func metadataChangeFields(
        _ fields: Set<String>
    ) -> CatalogChangeFields {
        var result: CatalogChangeFields = [.displayMetadata]
        if !fields.isDisjoint(with: identityMetadataFields) {
            result.insert(.identity)
        }
        if fields.contains("readingStatus") || fields.contains("readingProgress") {
            result.insert(.readingState)
        }
        return result
    }

    fileprivate static let identityMetadataFields: Set<String> = [
        "title", "author", "publisher", "year", "language", "translator",
        "isbn", "series", "seriesIndex", "editionStatement", "editionType",
        "originalFileName", "originalTitle", "originalLanguage",
        "openLibraryWorkKey", "hardcoverBookID",
    ]
}

struct CatalogChangeSet {
    let command: CatalogMutationCommand
    let affectedBookIDs: Set<UUID>
    let affectedWorkIDs: Set<UUID>
    let affectedAssetIDs: Set<UUID>
    let affectedCollectionIDs: Set<UUID>
    let fields: CatalogChangeFields

    init(
        command: CatalogMutationCommand,
        affectedBookIDs: Set<UUID>,
        affectedWorkIDs: Set<UUID>,
        affectedAssetIDs: Set<UUID>? = nil,
        affectedCollectionIDs: Set<UUID>,
        fields: CatalogChangeFields? = nil
    ) {
        self.command = command
        self.affectedBookIDs = affectedBookIDs
        self.affectedWorkIDs = affectedWorkIDs
        self.affectedAssetIDs = affectedAssetIDs ?? command.affectedAssetIDs
        self.affectedCollectionIDs = affectedCollectionIDs
        self.fields = fields ?? command.changeFields
    }
}

nonisolated enum CatalogBookMetadataField: String, Hashable, Sendable {
    case title
    case author
    case publisher
    case year
    case language
    case translator
    case isbn
    case series
    case seriesIndex
    case description
    case tags
    case shelfLocation
    case rating
    case notes
    case sampleNoticeDismissed
}

nonisolated struct CatalogBookPatch: Sendable {
    var fields: Set<CatalogBookMetadataField>
    var title: String?
    var author: String?
    var publisher: String?
    var year: String?
    var language: String?
    var translator: String?
    var isbn: String?
    var series: String?
    var seriesIndex: String?
    var bookDescription: String?
    var tags: [String] = []
    var shelfLocation: String?
    var rating: Int?
    var notes: String?
    var sampleNoticeDismissed: Bool?

    init(
        fields: Set<CatalogBookMetadataField>,
        title: String? = nil,
        author: String? = nil,
        publisher: String? = nil,
        year: String? = nil,
        language: String? = nil,
        translator: String? = nil,
        isbn: String? = nil,
        series: String? = nil,
        seriesIndex: String? = nil,
        bookDescription: String? = nil,
        tags: [String] = [],
        shelfLocation: String? = nil,
        rating: Int? = nil,
        notes: String? = nil,
        sampleNoticeDismissed: Bool? = nil
    ) {
        self.fields = fields
        self.title = title
        self.author = author
        self.publisher = publisher
        self.year = year
        self.language = language
        self.translator = translator
        self.isbn = isbn
        self.series = series
        self.seriesIndex = seriesIndex
        self.bookDescription = bookDescription
        self.tags = tags
        self.shelfLocation = shelfLocation
        self.rating = rating
        self.notes = notes
        self.sampleNoticeDismissed = sampleNoticeDismissed
    }

    var commandFields: Set<String> {
        Set(fields.map(\.rawValue))
    }
}

nonisolated enum CatalogBookPatchPolicy: Sendable, Equatable {
    case replace
    case fillEmpty
}

nonisolated enum CatalogTagUpdateMode: Sendable {
    case replace
    case add
}

nonisolated struct CatalogBookUpdate: Sendable {
    let bookID: UUID
    let patch: CatalogBookPatch
    let identityScope: EditionIdentityScope
    let policy: CatalogBookPatchPolicy
    let tagMode: CatalogTagUpdateMode
    let readingStatus: ReadingStatus?

    init(
        bookID: UUID,
        patch: CatalogBookPatch,
        identityScope: EditionIdentityScope = .editionOnly,
        policy: CatalogBookPatchPolicy = .replace,
        tagMode: CatalogTagUpdateMode = .replace,
        readingStatus: ReadingStatus? = nil
    ) {
        self.bookID = bookID
        self.patch = patch
        self.identityScope = identityScope
        self.policy = policy
        self.tagMode = tagMode
        self.readingStatus = readingStatus
    }
}

nonisolated enum CatalogBookUpdateSource: Sendable {
    case manual
    case plugin
}

nonisolated struct CatalogPhysicalBookPayload: Sendable {
    let bookID: UUID
    let workID: UUID
    let title: String
    let author: String?
    let publisher: String?
    let year: String?
    let isbn: String?
    let shelfLocation: String?
    let notes: String?
    let readingStatus: ReadingStatus
}

nonisolated struct CatalogCollectionCreation: Sendable {
    let collectionID: UUID
    let name: String
    let savedSearch: String?
    let smartShelf: SmartShelfDefinition?
    let bookIDs: Set<UUID>
}

nonisolated struct CatalogAssetValidationUpdate: Sendable {
    let assetID: UUID
    let expectedFileName: String
    let expectedDateAdded: Date
    let validation: AssetValidation
}

nonisolated struct CatalogHighlightInsertion: Sendable {
    let bookID: UUID
    let text: String
    let isNote: Bool
    let location: String?
    let addedDate: Date?
}

nonisolated enum CatalogMutationRequest: Sendable {
    case updateBook(CatalogBookUpdate, source: CatalogBookUpdateSource)
    case updateBooks([CatalogBookUpdate], operation: String)
    case setReadingStatus(bookIDs: Set<UUID>, status: ReadingStatus)
    case setReadingProgress(bookID: UUID, progress: Double)
    case addPhysicalBook(CatalogPhysicalBookPayload)
    case createCollection(CatalogCollectionCreation)
    case renameCollection(collectionID: UUID, name: String)
    case updateSmartShelf(collectionID: UUID, name: String, definition: SmartShelfDefinition)
    case addToCollection(collectionID: UUID, bookIDs: Set<UUID>)
    case removeFromCollection(collectionID: UUID, bookIDs: Set<UUID>)
    case deleteCollection(collectionID: UUID)
    case updateWorkIdentity(workID: UUID, title: String?, author: String?)
    case setPreferredEdition(workID: UUID, bookID: UUID)
    case updateAssetValidations([CatalogAssetValidationUpdate])
    case importHighlights([CatalogHighlightInsertion])
}

nonisolated enum EditionIdentityScope: String, CaseIterable, Identifiable, Sendable {
    case editionOnly
    case workIdentity
    case allEditions

    var id: Self { self }
}

nonisolated enum EditionIdentityField: Hashable, Sendable {
    case title
    case author
    case isbn
    case openLibraryWorkKey
    case hardcoverBookID
}

nonisolated struct EditionIdentityPatch: Sendable {
    let fields: Set<EditionIdentityField>
    var title: String?
    var author: String?
    var isbn: String?
    var openLibraryWorkKey: String?
    var hardcoverBookID: String?

    init(
        fields: Set<EditionIdentityField>,
        title: String? = nil,
        author: String? = nil,
        isbn: String? = nil,
        openLibraryWorkKey: String? = nil,
        hardcoverBookID: String? = nil
    ) {
        self.fields = fields
        self.title = title
        self.author = author
        self.isbn = isbn
        self.openLibraryWorkKey = openLibraryWorkKey
        self.hardcoverBookID = hardcoverBookID
    }
}

struct EditionIdentityMutation {
    let affectedBookIDs: Set<UUID>
    let affectedWorkIDs: Set<UUID>
}

@MainActor
struct EditionIdentityCoordinator {
    func affectedModels(
        for book: Book,
        scope: EditionIdentityScope
    ) -> EditionIdentityMutation {
        guard let work = book.work else {
            return EditionIdentityMutation(
                affectedBookIDs: [book.uuid],
                affectedWorkIDs: []
            )
        }
        let bookIDs: Set<UUID> = scope == .editionOnly
            ? [book.uuid]
            : Set(work.editions.map(\.uuid))
        return EditionIdentityMutation(
            affectedBookIDs: bookIDs,
            affectedWorkIDs: scope == .editionOnly ? [] : [work.uuid]
        )
    }

    @discardableResult
    func apply(
        _ patch: EditionIdentityPatch,
        to book: Book,
        scope: EditionIdentityScope
    ) -> EditionIdentityMutation {
        let affected = affectedModels(for: book, scope: scope)
        applyEditionFields(patch, to: book)

        guard scope != .editionOnly, let work = book.work else {
            return affected
        }
        if patch.fields.contains(.title) { work.title = patch.title }
        if patch.fields.contains(.author) { work.author = patch.author }
        if patch.fields.contains(.openLibraryWorkKey) {
            work.openLibraryWorkKey = patch.openLibraryWorkKey
        }
        if patch.fields.contains(.hardcoverBookID) {
            work.hardcoverBookID = patch.hardcoverBookID
        }
        work.refreshMatchKey()

        if scope == .allEditions {
            for edition in work.editions where edition !== book {
                if patch.fields.contains(.title) { edition.title = patch.title }
                if patch.fields.contains(.author) { edition.author = patch.author }
            }
        }
        return affected
    }

    func seedWorkIdentityIfMissing(from book: Book, work: Work) {
        if work.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            work.title = book.title
        }
        if work.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            work.author = book.author
        }
        work.refreshMatchKey()
    }

    private func applyEditionFields(
        _ patch: EditionIdentityPatch,
        to book: Book
    ) {
        if patch.fields.contains(.title) { book.title = patch.title }
        if patch.fields.contains(.author) { book.author = patch.author }
        if patch.fields.contains(.isbn) { book.isbn = patch.isbn }
    }
}

enum CatalogMutationError: Error, Equatable {
    case dirtyContext
    case invalidRequest
    case modelNotFound
    case staleGeneration
    case staleAnalysis
    case staleReconciliation
    case staleConversion
    case checkpointFailed(String)
    case saveFailed(String)
    case fileTransactionFailed(String)
}

struct CatalogFileCommitResult {
    let changeSet: CatalogChangeSet
    let pendingTransactionIDs: [UUID]

    var isFullyPublished: Bool { pendingTransactionIDs.isEmpty }
}

/// Explicit preimage for the scalar catalog fields changed by metadata and
/// plugin commands. SwiftData rollback clears persistence bookkeeping but does
/// not reliably restore values on already-materialized model instances.
struct CatalogBookMetadataPreimage {
    let book: Book
    let title: String?
    let author: String?
    let publisher: String?
    let year: String?
    let language: String?
    let translator: String?
    let isbn: String?
    let series: String?
    let seriesIndex: String?
    let tags: [String]
    let bookDescription: String?
    let rating: Int?
    let communityRating: Double?
    let communityRatingCount: Int?
    let communityRatingSource: String?
    let onlineLookupAt: Date?
    let onlineLookupConfiguration: String?
    let notes: String?
    let shelfLocation: String?
    let sampleNoticeDismissed: Bool?
    let drmProtected: Bool?
    let fileName: String
    let primaryAssetUUID: UUID?
    let fileSizeBytes: Int64
    let coverVersion: Int
    let coverScopeRaw: String?
    let coverAssetUUID: UUID?
    let pageCount: Int?
    let work: Work?

    init(_ book: Book) {
        self.book = book
        title = book.title
        author = book.author
        publisher = book.publisher
        year = book.year
        language = book.language
        translator = book.translator
        isbn = book.isbn
        series = book.series
        seriesIndex = book.seriesIndex
        tags = book.tags
        bookDescription = book.bookDescription
        rating = book.rating
        communityRating = book.communityRating
        communityRatingCount = book.communityRatingCount
        communityRatingSource = book.communityRatingSource
        onlineLookupAt = book.onlineLookupAt
        onlineLookupConfiguration = book.onlineLookupConfiguration
        notes = book.notes
        shelfLocation = book.shelfLocation
        sampleNoticeDismissed = book.sampleNoticeDismissed
        drmProtected = book.drmProtected
        fileName = book.fileName
        primaryAssetUUID = book.primaryAssetUUID
        fileSizeBytes = book.fileSizeBytes
        coverVersion = book.coverVersion
        coverScopeRaw = book.coverScopeRaw
        coverAssetUUID = book.coverAssetUUID
        pageCount = book.pageCount
        work = book.work
    }

    func restore() {
        book.title = title
        book.author = author
        book.publisher = publisher
        book.year = year
        book.language = language
        book.translator = translator
        book.isbn = isbn
        book.series = series
        book.seriesIndex = seriesIndex
        book.tags = tags
        book.bookDescription = bookDescription
        book.rating = rating
        book.communityRating = communityRating
        book.communityRatingCount = communityRatingCount
        book.communityRatingSource = communityRatingSource
        book.onlineLookupAt = onlineLookupAt
        book.onlineLookupConfiguration = onlineLookupConfiguration
        book.notes = notes
        book.shelfLocation = shelfLocation
        book.sampleNoticeDismissed = sampleNoticeDismissed
        book.drmProtected = drmProtected
        book.fileName = fileName
        book.primaryAssetUUID = primaryAssetUUID
        book.fileSizeBytes = fileSizeBytes
        book.coverVersion = coverVersion
        book.coverScopeRaw = coverScopeRaw
        book.coverAssetUUID = coverAssetUUID
        book.pageCount = pageCount
        book.work = work
    }
}

struct CatalogBookAssetPreimage {
    let asset: BookAsset
    let book: Book?
    let fileName: String
    let formatRaw: String?
    let contentHash: String?
    let generatedFromContentHash: String?
    let sizeBytes: Int64
    let drmProtected: Bool?
    let originRaw: String?
    let sourceProvenanceRaw: String?
    let sourceIdentifier: String?
    let validationStatusRaw: String?
    let availabilityRaw: String?
    let coverVersionRaw: Int?
    let dateAdded: Date

    init(_ asset: BookAsset) {
        self.asset = asset
        book = asset.book
        fileName = asset.fileName
        formatRaw = asset.formatRaw
        contentHash = asset.contentHash
        generatedFromContentHash = asset.generatedFromContentHash
        sizeBytes = asset.sizeBytes
        drmProtected = asset.drmProtected
        originRaw = asset.originRaw
        sourceProvenanceRaw = asset.sourceProvenanceRaw
        sourceIdentifier = asset.sourceIdentifier
        validationStatusRaw = asset.validationStatusRaw
        availabilityRaw = asset.availabilityRaw
        coverVersionRaw = asset.coverVersionRaw
        dateAdded = asset.dateAdded
    }

    func restore() {
        asset.book = book
        asset.fileName = fileName
        asset.formatRaw = formatRaw
        asset.contentHash = contentHash
        asset.generatedFromContentHash = generatedFromContentHash
        asset.sizeBytes = sizeBytes
        asset.drmProtected = drmProtected
        asset.originRaw = originRaw
        asset.sourceProvenanceRaw = sourceProvenanceRaw
        asset.sourceIdentifier = sourceIdentifier
        asset.validationStatusRaw = validationStatusRaw
        asset.availabilityRaw = availabilityRaw
        asset.coverVersionRaw = coverVersionRaw
        asset.dateAdded = dateAdded
    }
}

struct CatalogWorkPreimage {
    let work: Work
    let editions: [Book]
    let title: String?
    let author: String?
    let originalTitle: String?
    let originalLanguage: String?
    let matchKey: String?
    let openLibraryWorkKey: String?
    let hardcoverBookID: String?
    let preferredEditionUUID: UUID?
    let coverVersionRaw: Int?
    let notes: String?

    init(_ work: Work) {
        self.work = work
        editions = work.editions
        title = work.title
        author = work.author
        originalTitle = work.originalTitle
        originalLanguage = work.originalLanguage
        matchKey = work.matchKey
        openLibraryWorkKey = work.openLibraryWorkKey
        hardcoverBookID = work.hardcoverBookID
        preferredEditionUUID = work.preferredEditionUUID
        coverVersionRaw = work.coverVersionRaw
        notes = work.notes
    }

    func restore() {
        work.editions = editions
        work.title = title
        work.author = author
        work.originalTitle = originalTitle
        work.originalLanguage = originalLanguage
        work.matchKey = matchKey
        work.openLibraryWorkKey = openLibraryWorkKey
        work.hardcoverBookID = hardcoverBookID
        work.preferredEditionUUID = preferredEditionUUID
        work.coverVersionRaw = coverVersionRaw
        work.notes = notes
    }
}

private struct CatalogReadingSessionPreimage {
    let session: ReadingSession
    let startedAt: Date
    let endedAt: Date?
    let statusRaw: String
    let progress: Double
}

private struct CatalogReadingStatePreimage {
    let book: Book
    let readingStatusRaw: String?
    let dateStarted: Date?
    let dateFinished: Date?
    let sessions: [CatalogReadingSessionPreimage]

    init(_ book: Book) {
        self.book = book
        readingStatusRaw = book.readingStatusRaw
        dateStarted = book.dateStarted
        dateFinished = book.dateFinished
        sessions = book.readingSessions.map {
            CatalogReadingSessionPreimage(
                session: $0,
                startedAt: $0.startedAt,
                endedAt: $0.endedAt,
                statusRaw: $0.statusRaw,
                progress: $0.progress
            )
        }
    }

    func restore(in context: ModelContext) {
        let originalSessions = Set(sessions.map { ObjectIdentifier($0.session) })
        for session in book.readingSessions
        where !originalSessions.contains(ObjectIdentifier(session)) {
            session.book = nil
            if session.modelContext != nil { context.delete(session) }
        }
        book.readingSessions = sessions.map(\.session)
        for preimage in sessions {
            preimage.session.startedAt = preimage.startedAt
            preimage.session.endedAt = preimage.endedAt
            preimage.session.statusRaw = preimage.statusRaw
            preimage.session.progress = preimage.progress
            preimage.session.book = book
        }
        book.readingStatusRaw = readingStatusRaw
        book.dateStarted = dateStarted
        book.dateFinished = dateFinished
    }
}

private struct CatalogCollectionPreimage {
    let collection: BookCollection
    let name: String
    let savedSearch: String?
    let smartShelfRulesData: Data?
    let books: [Book]

    init(_ collection: BookCollection) {
        self.collection = collection
        name = collection.name
        savedSearch = collection.savedSearch
        smartShelfRulesData = collection.smartShelfRulesData
        books = collection.books
    }

    func restore() {
        collection.name = name
        collection.savedSearch = savedSearch
        collection.smartShelfRulesData = smartShelfRulesData
        collection.books = books
    }
}

/// Proof that one short, no-suspension catalog transaction reached durable
/// storage. File publication may continue asynchronously after this receipt.
struct CatalogCommitReceipt {
    let operationID: UUID
    let changeSet: CatalogChangeSet
}

/// The single owner of write ordering for one ModelContainer.
///
/// The coordinator is MainActor-isolated deliberately: SwiftData models never
/// cross an actor boundary, and `commit` contains no suspension point. A clean
/// context at entry therefore proves that every pending change on failure was
/// created by the current operation and may be rolled back safely.
@MainActor
final class CatalogWriteCoordinator {
    let modelContext: ModelContext

    private let saveAdapter: CatalogSaveAdapter
    private let hooks: CatalogMutationHooks
    private var activeOperationID: UUID?

    init(
        modelContext: ModelContext,
        saveAdapter: CatalogSaveAdapter = .live,
        hooks: CatalogMutationHooks = .live
    ) {
        self.modelContext = modelContext
        self.saveAdapter = saveAdapter
        self.hooks = hooks
    }

    func commit(
        operationID: UUID = UUID(),
        command: CatalogMutationCommand,
        affectedBookIDs: Set<UUID>,
        affectedWorkIDs: Set<UUID>,
        affectedAssetIDs: Set<UUID>?,
        affectedCollectionIDs: Set<UUID>,
        revertingOnFailure rollbackMutation: () -> Void,
        repairingInvariants repairInvariants: () throws -> Void,
        applying mutation: () throws -> Void
    ) throws -> CatalogCommitReceipt {
        precondition(
            activeOperationID == nil,
            "CatalogWriteCoordinator transaction re-entered without suspension"
        )

        modelContext.processPendingChanges()
        guard !modelContext.hasChanges else {
            Log.persistence.error(
                "Catalog operation \(operationID.uuidString, privacy: .public) refused unknown pending changes without rolling them back"
            )
            throw CatalogMutationError.dirtyContext
        }

        activeOperationID = operationID
        defer { activeOperationID = nil }

        do {
            try reach(.beforeMutation)
            try mutation()
            try reach(.afterMutation)
            modelContext.processPendingChanges()
            try repairInvariants()
            modelContext.processPendingChanges()
            try saveAdapter.save(modelContext)
            return CatalogCommitReceipt(
                operationID: operationID,
                changeSet: CatalogChangeSet(
                    command: command,
                    affectedBookIDs: affectedBookIDs,
                    affectedWorkIDs: affectedWorkIDs,
                    affectedAssetIDs: affectedAssetIDs,
                    affectedCollectionIDs: affectedCollectionIDs
                )
            )
        } catch let error as CatalogMutationError {
            rollbackOwnedChanges(
                operationID: operationID,
                reverting: rollbackMutation
            )
            Log.persistence.error(
                "Catalog operation \(operationID.uuidString, privacy: .public) rolled back: \(String(describing: error), privacy: .public)"
            )
            throw error
        } catch {
            rollbackOwnedChanges(
                operationID: operationID,
                reverting: rollbackMutation
            )
            Log.persistence.error(
                "Catalog operation \(operationID.uuidString, privacy: .public) save failed and rolled back: \(error.localizedDescription, privacy: .public)"
            )
            throw CatalogMutationError.saveFailed(error.localizedDescription)
        }
    }

    private func rollbackOwnedChanges(
        operationID: UUID,
        reverting rollbackMutation: () -> Void
    ) {
        precondition(activeOperationID == operationID)
        rollbackMutation()
        modelContext.processPendingChanges()
        modelContext.rollback()
        modelContext.processPendingChanges()
        if modelContext.hasChanges {
            // Any inverse updates queued here were produced synchronously by
            // this operation; no other MainActor work could interleave.
            modelContext.rollback()
        }
    }

    private func reach(_ checkpoint: CatalogMutationCheckpoint) throws {
        do {
            try hooks.reach(checkpoint)
        } catch {
            throw CatalogMutationError.checkpointFailed(error.localizedDescription)
        }
    }
}

@MainActor
private final class CatalogWriteCoordinatorRegistryEntry {
    weak var container: ModelContainer?
    weak var coordinator: CatalogWriteCoordinator?

    init(container: ModelContainer, coordinator: CatalogWriteCoordinator) {
        self.container = container
        self.coordinator = coordinator
    }
}

/// Production services resolving the same ModelContainer share one coordinator.
/// Custom save adapters and checkpoint hooks are test seams and intentionally
/// receive an isolated coordinator so one test's injected behavior cannot leak
/// into another service.
@MainActor
private enum CatalogWriteCoordinatorRegistry {
    private static var entries: [ObjectIdentifier: CatalogWriteCoordinatorRegistryEntry] = [:]

    static func resolve(
        modelContext: ModelContext,
        saveAdapter: CatalogSaveAdapter,
        hooks: CatalogMutationHooks
    ) -> CatalogWriteCoordinator {
        guard saveAdapter.permitsStoreScopedSharing,
              hooks.permitsStoreScopedSharing else {
            return CatalogWriteCoordinator(
                modelContext: modelContext,
                saveAdapter: saveAdapter,
                hooks: hooks
            )
        }

        let container = modelContext.container
        let key = ObjectIdentifier(container)
        if let entry = entries[key],
           entry.container === container,
           let coordinator = entry.coordinator {
            return coordinator
        }

        entries = entries.filter {
            $0.value.container != nil && $0.value.coordinator != nil
        }
        let coordinator = CatalogWriteCoordinator(
            modelContext: modelContext,
            saveAdapter: saveAdapter,
            hooks: hooks
        )
        entries[key] = CatalogWriteCoordinatorRegistryEntry(
            container: container,
            coordinator: coordinator
        )
        return coordinator
    }
}

nonisolated struct ManagedFileVerificationMetrics: Sendable, Equatable {
    let transactionCount: Int
    let fetchCount: Int
    let requestedBookCount: Int
    let requestedFileNameCount: Int
    let requestedWorkOwnerCount: Int
    let requestedAssetOwnerCount: Int
}

nonisolated struct ManagedFileVerificationSnapshot: Sendable, Equatable {
    let catalog: ManagedFileCatalogSnapshot
    let metrics: ManagedFileVerificationMetrics
}

@MainActor
final class CatalogMutationService {
    private let modelContext: ModelContext
    private let writeCoordinator: CatalogWriteCoordinator
    let managedFiles: ManagedFileCoordinator
    let analysisCoordinator: CatalogAnalysisCoordinator
    let editionIdentity = EditionIdentityCoordinator()

    var storeWriteOwnerIdentifier: ObjectIdentifier {
        ObjectIdentifier(writeCoordinator)
    }

    init(
        modelContext: ModelContext,
        saveAdapter: CatalogSaveAdapter = .live,
        managedFiles: ManagedFileCoordinator = .shared,
        analysisCoordinator: CatalogAnalysisCoordinator? = nil,
        hooks: CatalogMutationHooks = .live,
        writeCoordinator: CatalogWriteCoordinator? = nil
    ) {
        let resolvedWriteCoordinator = writeCoordinator
            ?? CatalogWriteCoordinatorRegistry.resolve(
                modelContext: modelContext,
                saveAdapter: saveAdapter,
                hooks: hooks
            )
        self.modelContext = resolvedWriteCoordinator.modelContext
        self.writeCoordinator = resolvedWriteCoordinator
        self.managedFiles = managedFiles
        self.analysisCoordinator = analysisCoordinator ?? CatalogAnalysisCoordinator()
    }

    func execute(
        _ request: CatalogMutationRequest,
        validatingGeneration generationIsCurrent: () -> Bool = { true }
    ) -> Result<CatalogChangeSet, CatalogMutationError> {
        do {
            return .success(try executeThrowing(
                request,
                validatingGeneration: generationIsCurrent
            ))
        } catch let error as CatalogMutationError {
            return .failure(error)
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }

    private func executeThrowing(
        _ request: CatalogMutationRequest,
        validatingGeneration generationIsCurrent: () -> Bool
    ) throws -> CatalogChangeSet {
        switch request {
        case .updateBook(let update, let source):
            return try executeBookUpdates(
                [update],
                source: source,
                operation: nil,
                validatingGeneration: generationIsCurrent
            )

        case .updateBooks(let updates, let operation):
            return try executeBookUpdates(
                updates,
                source: .manual,
                operation: operation,
                validatingGeneration: generationIsCurrent
            )

        case .setReadingStatus(let bookIDs, let status):
            guard !bookIDs.isEmpty else { throw CatalogMutationError.invalidRequest }
            let storedBooks = try books(ids: bookIDs)
            let preimages = storedBooks.map(CatalogReadingStatePreimage.init)
            return try commit(
                .setReadingStatus(bookIDs: Array(bookIDs), status: status),
                affectedBookIDs: bookIDs,
                revertingOnFailure: {
                    preimages.forEach { $0.restore(in: self.modelContext) }
                }
            ) {
                guard generationIsCurrent() else {
                    throw CatalogMutationError.staleGeneration
                }
                for book in try self.books(ids: bookIDs) {
                    book.setStatus(status)
                }
            }

        case .setReadingProgress(let bookID, let progress):
            let storedBook = try book(id: bookID)
            let preimage = CatalogReadingStatePreimage(storedBook)
            return try commit(
                .setReadingProgress(bookID: bookID, progress: progress),
                affectedBookIDs: [bookID],
                revertingOnFailure: { preimage.restore(in: self.modelContext) }
            ) {
                guard generationIsCurrent() else {
                    throw CatalogMutationError.staleGeneration
                }
                guard try self.book(id: bookID).updateReadingProgress(progress) else {
                    throw CatalogMutationError.invalidRequest
                }
            }

        case .addPhysicalBook(let payload):
            return try commit(
                .addPhysicalBook(bookID: payload.bookID, workID: payload.workID),
                affectedBookIDs: [payload.bookID],
                affectedWorkIDs: [payload.workID]
            ) {
                guard generationIsCurrent() else {
                    throw CatalogMutationError.staleGeneration
                }
                let book = Book(
                    uuid: payload.bookID,
                    fileName: "",
                    originalFileName: payload.title
                )
                book.title = payload.title
                book.author = payload.author
                book.publisher = payload.publisher
                book.year = payload.year
                book.isbn = payload.isbn
                book.shelfLocation = payload.shelfLocation
                book.notes = payload.notes
                book.hasPhysicalCopy = true
                if payload.readingStatus != .unread {
                    book.setStatus(payload.readingStatus)
                }
                let work = Work(
                    uuid: payload.workID,
                    title: payload.title,
                    author: payload.author,
                    dateCreated: book.dateAdded
                )
                work.preferredEditionUUID = book.uuid
                self.modelContext.insert(work)
                self.modelContext.insert(book)
                book.work = work
            }

        case .createCollection(let creation):
            var insertedCollection: BookCollection?
            return try commit(
                .createCollection(
                    collectionID: creation.collectionID,
                    bookIDs: Array(creation.bookIDs)
                ),
                affectedBookIDs: creation.bookIDs,
                affectedCollectionIDs: [creation.collectionID],
                revertingOnFailure: {
                    insertedCollection?.books.removeAll()
                    if let insertedCollection, insertedCollection.modelContext != nil {
                        self.modelContext.delete(insertedCollection)
                    }
                }
            ) {
                guard generationIsCurrent() else {
                    throw CatalogMutationError.staleGeneration
                }
                let collection = BookCollection(
                    id: creation.collectionID,
                    name: creation.name,
                    savedSearch: creation.savedSearch
                )
                collection.smartShelfDefinition = creation.smartShelf
                collection.books = try self.books(ids: creation.bookIDs)
                insertedCollection = collection
                self.modelContext.insert(collection)
            }

        case .renameCollection(let collectionID, let name):
            return try executeCollectionMutation(
                collectionID: collectionID,
                bookIDs: [],
                validatingGeneration: generationIsCurrent
            ) {
                $0.name = name
            }

        case .updateSmartShelf(let collectionID, let name, let definition):
            return try executeCollectionMutation(
                collectionID: collectionID,
                bookIDs: [],
                validatingGeneration: generationIsCurrent
            ) {
                $0.name = name
                $0.savedSearch = nil
                $0.smartShelfDefinition = definition
            }

        case .addToCollection(let collectionID, let bookIDs):
            return try executeCollectionMutation(
                collectionID: collectionID,
                bookIDs: bookIDs,
                validatingGeneration: generationIsCurrent
            ) { collection in
                for book in try self.books(ids: bookIDs)
                where !collection.books.contains(where: { $0.uuid == book.uuid }) {
                    collection.books.append(book)
                }
            }

        case .removeFromCollection(let collectionID, let bookIDs):
            return try executeCollectionMutation(
                collectionID: collectionID,
                bookIDs: bookIDs,
                validatingGeneration: generationIsCurrent
            ) {
                $0.books.removeAll { bookIDs.contains($0.uuid) }
            }

        case .deleteCollection(let collectionID):
            let storedCollection = try collection(id: collectionID)
            let bookIDs = Set(storedCollection.books.map(\.uuid))
            return try commit(
                .deleteCollection(collectionID: collectionID),
                affectedBookIDs: bookIDs,
                affectedCollectionIDs: [collectionID]
            ) {
                guard generationIsCurrent() else {
                    throw CatalogMutationError.staleGeneration
                }
                self.modelContext.delete(try self.collection(id: collectionID))
            }

        case .updateWorkIdentity(let workID, let title, let author):
            let storedWork = try work(id: workID)
            let preimage = CatalogWorkPreimage(storedWork)
            return try commit(
                .updateWork(workID: workID, fields: ["title", "author"]),
                affectedWorkIDs: [workID],
                revertingOnFailure: preimage.restore
            ) {
                guard generationIsCurrent() else {
                    throw CatalogMutationError.staleGeneration
                }
                let work = try self.work(id: workID)
                work.title = title
                work.author = author
                work.refreshMatchKey()
            }

        case .setPreferredEdition(let workID, let bookID):
            let storedWork = try work(id: workID)
            let preimage = CatalogWorkPreimage(storedWork)
            return try commit(
                .updateWork(workID: workID, fields: ["preferredEditionUUID"]),
                affectedBookIDs: [bookID],
                affectedWorkIDs: [workID],
                revertingOnFailure: preimage.restore
            ) {
                guard generationIsCurrent() else {
                    throw CatalogMutationError.staleGeneration
                }
                let book = try self.book(id: bookID)
                let work = try self.work(id: workID)
                guard book.work?.uuid == workID else {
                    throw CatalogMutationError.invalidRequest
                }
                work.preferredEditionUUID = book.uuid
            }

        case .updateAssetValidations(let updates):
            guard !updates.isEmpty else { throw CatalogMutationError.invalidRequest }
            let updatesByID = Dictionary(
                updates.map { ($0.assetID, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            let storedAssets = try assets(ids: Set(updatesByID.keys))
            let preimages = storedAssets.map(CatalogBookAssetPreimage.init)
            let bookIDs = Set(storedAssets.compactMap { $0.book?.uuid })
            return try commit(
                .updateAssetValidation(
                    assetIDs: Array(updatesByID.keys),
                    bookIDs: Array(bookIDs)
                ),
                affectedBookIDs: bookIDs,
                affectedAssetIDs: Set(updatesByID.keys),
                revertingOnFailure: { preimages.forEach { $0.restore() } }
            ) {
                guard generationIsCurrent() else {
                    throw CatalogMutationError.staleGeneration
                }
                for asset in try self.assets(ids: Set(updatesByID.keys)) {
                    guard let update = updatesByID[asset.uuid],
                          asset.fileName == update.expectedFileName,
                          asset.dateAdded == update.expectedDateAdded else {
                        throw CatalogMutationError.staleGeneration
                    }
                    asset.validationStatus = update.validation
                }
            }

        case .importHighlights(let insertions):
            guard !insertions.isEmpty else { throw CatalogMutationError.invalidRequest }
            let bookIDs = Set(insertions.map(\.bookID))
            _ = try books(ids: bookIDs)
            var insertedHighlights: [Highlight] = []
            return try commit(
                .importHighlights(bookIDs: Array(bookIDs)),
                affectedBookIDs: bookIDs,
                revertingOnFailure: {
                    for highlight in insertedHighlights {
                        highlight.book = nil
                        if highlight.modelContext != nil {
                            self.modelContext.delete(highlight)
                        }
                    }
                }
            ) {
                guard generationIsCurrent() else {
                    throw CatalogMutationError.staleGeneration
                }
                let books = Dictionary(
                    uniqueKeysWithValues: try self.books(ids: bookIDs).map { ($0.uuid, $0) }
                )
                for insertion in insertions {
                    guard let book = books[insertion.bookID] else {
                        throw CatalogMutationError.modelNotFound
                    }
                    let highlight = Highlight(
                        text: insertion.text,
                        isNote: insertion.isNote,
                        location: insertion.location,
                        addedDate: insertion.addedDate
                    )
                    highlight.book = book
                    insertedHighlights.append(highlight)
                    self.modelContext.insert(highlight)
                }
            }
        }
    }

    private func executeBookUpdates(
        _ updates: [CatalogBookUpdate],
        source: CatalogBookUpdateSource,
        operation: String?,
        validatingGeneration generationIsCurrent: () -> Bool
    ) throws -> CatalogChangeSet {
        guard !updates.isEmpty else { throw CatalogMutationError.invalidRequest }
        let targetBookIDs = Set(updates.map(\.bookID))
        let storedBooks = try books(ids: targetBookIDs)
        let storedByID = Dictionary(uniqueKeysWithValues: storedBooks.map { ($0.uuid, $0) })
        var affectedBookIDs = targetBookIDs
        var affectedWorkIDs: Set<UUID> = []
        var commandFields: Set<String> = []
        for update in updates {
            guard let book = storedByID[update.bookID] else {
                throw CatalogMutationError.modelNotFound
            }
            commandFields.formUnion(update.patch.commandFields)
            if update.readingStatus != nil { commandFields.insert("readingStatus") }
            if !update.patch.fields.isDisjoint(with: [.title, .author, .isbn]) {
                let affected = editionIdentity.affectedModels(
                    for: book,
                    scope: update.identityScope
                )
                affectedBookIDs.formUnion(affected.affectedBookIDs)
                affectedWorkIDs.formUnion(affected.affectedWorkIDs)
            }
        }
        let bookPreimages = try books(ids: affectedBookIDs).map(CatalogBookMetadataPreimage.init)
        let readingBookIDs = Set(updates.compactMap {
            $0.readingStatus == nil ? nil : $0.bookID
        })
        let readingPreimages = try books(ids: readingBookIDs)
            .map(CatalogReadingStatePreimage.init)
        let workPreimages = try works(ids: affectedWorkIDs).map(CatalogWorkPreimage.init)
        let command: CatalogMutationCommand
        if let operation {
            command = .updateMetadataBatch(
                bookIDs: Array(affectedBookIDs),
                operation: operation,
                fields: commandFields
            )
        } else {
            guard updates.count == 1, let update = updates.first else {
                throw CatalogMutationError.invalidRequest
            }
            command = switch source {
            case .manual:
                .updateMetadata(bookID: update.bookID, fields: commandFields)
            case .plugin:
                .pluginUpdate(bookID: update.bookID, fields: commandFields)
            }
        }
        return try commit(
            command,
            affectedBookIDs: affectedBookIDs,
            affectedWorkIDs: affectedWorkIDs,
            revertingOnFailure: {
                bookPreimages.forEach { $0.restore() }
                readingPreimages.forEach { $0.restore(in: self.modelContext) }
                workPreimages.forEach { $0.restore() }
            }
        ) {
            guard generationIsCurrent() else {
                throw CatalogMutationError.staleGeneration
            }
            for update in updates {
                let book = try self.book(id: update.bookID)
                self.apply(
                    update.patch,
                    to: book,
                    scope: update.identityScope,
                    policy: update.policy,
                    tagMode: update.tagMode
                )
                if let readingStatus = update.readingStatus {
                    book.setStatus(readingStatus)
                }
            }
        }
    }

    private func executeCollectionMutation(
        collectionID: UUID,
        bookIDs: Set<UUID>,
        validatingGeneration generationIsCurrent: () -> Bool,
        applying mutation: (BookCollection) throws -> Void
    ) throws -> CatalogChangeSet {
        let storedCollection = try collection(id: collectionID)
        guard !storedCollection.isSystem else {
            throw CatalogMutationError.invalidRequest
        }
        let preimage = CatalogCollectionPreimage(storedCollection)
        return try commit(
            .updateCollection(collectionID: collectionID),
            affectedBookIDs: bookIDs,
            affectedCollectionIDs: [collectionID],
            revertingOnFailure: preimage.restore
        ) {
            guard generationIsCurrent() else {
                throw CatalogMutationError.staleGeneration
            }
            try mutation(try self.collection(id: collectionID))
        }
    }

    private func apply(
        _ patch: CatalogBookPatch,
        to book: Book,
        scope: EditionIdentityScope,
        policy: CatalogBookPatchPolicy,
        tagMode: CatalogTagUpdateMode
    ) {
        func stringMayApply(_ current: String?, _ proposed: String?) -> Bool {
            switch policy {
            case .replace:
                true
            case .fillEmpty:
                current?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                    && proposed?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
        }

        var identityFields: Set<EditionIdentityField> = []
        if patch.fields.contains(.title), stringMayApply(book.title, patch.title) {
            identityFields.insert(.title)
        }
        if patch.fields.contains(.author), stringMayApply(book.author, patch.author) {
            identityFields.insert(.author)
        }
        if patch.fields.contains(.isbn), stringMayApply(book.isbn, patch.isbn) {
            identityFields.insert(.isbn)
        }
        if !identityFields.isEmpty {
            editionIdentity.apply(
                EditionIdentityPatch(
                    fields: identityFields,
                    title: patch.title,
                    author: patch.author,
                    isbn: patch.isbn
                ),
                to: book,
                scope: scope
            )
        }
        if patch.fields.contains(.publisher), stringMayApply(book.publisher, patch.publisher) {
            book.publisher = patch.publisher
        }
        if patch.fields.contains(.year), stringMayApply(book.year, patch.year) {
            book.year = patch.year
        }
        if patch.fields.contains(.language), stringMayApply(book.language, patch.language) {
            book.language = patch.language
        }
        if patch.fields.contains(.translator), stringMayApply(book.translator, patch.translator) {
            book.translator = patch.translator
        }
        if patch.fields.contains(.series), stringMayApply(book.series, patch.series) {
            book.series = patch.series
        }
        if patch.fields.contains(.seriesIndex), stringMayApply(book.seriesIndex, patch.seriesIndex) {
            book.seriesIndex = patch.seriesIndex
        }
        if patch.fields.contains(.description),
           stringMayApply(book.bookDescription, patch.bookDescription) {
            book.bookDescription = patch.bookDescription
        }
        if patch.fields.contains(.shelfLocation),
           stringMayApply(book.shelfLocation, patch.shelfLocation) {
            book.shelfLocation = patch.shelfLocation
        }
        if patch.fields.contains(.notes), stringMayApply(book.notes, patch.notes) {
            book.notes = patch.notes
        }
        if patch.fields.contains(.tags),
           policy == .replace || book.tags.isEmpty {
            switch tagMode {
            case .replace:
                book.tags = patch.tags
            case .add:
                book.tags = Array(Set(book.tags + patch.tags)).sorted()
            }
        }
        if patch.fields.contains(.rating),
           policy == .replace || book.rating == nil {
            book.rating = patch.rating
        }
        if patch.fields.contains(.sampleNoticeDismissed),
           policy == .replace || book.sampleNoticeDismissed == nil {
            book.sampleNoticeDismissed = patch.sampleNoticeDismissed
        }
    }

    @discardableResult
    func commit(
        _ command: CatalogMutationCommand,
        affectedBookIDs: Set<UUID> = [],
        affectedWorkIDs: Set<UUID> = [],
        affectedAssetIDs: Set<UUID>? = nil,
        affectedCollectionIDs: Set<UUID> = [],
        catalogChanged: Bool = true,
        revertingOnFailure rollbackMutation: () -> Void = {},
        applying mutation: () throws -> Void
    ) throws -> CatalogChangeSet {
        let receipt = try writeCoordinator.commit(
            command: command,
            affectedBookIDs: affectedBookIDs,
            affectedWorkIDs: affectedWorkIDs,
            affectedAssetIDs: affectedAssetIDs,
            affectedCollectionIDs: affectedCollectionIDs,
            revertingOnFailure: rollbackMutation,
            repairingInvariants: {
                try self.repairInvariants(
                    for: command,
                    affectedBookIDs: affectedBookIDs,
                    affectedWorkIDs: affectedWorkIDs
                )
            },
            applying: mutation
        )
        return publish(receipt.changeSet, catalogChanged: catalogChanged)
    }

    /// Runs a prepared value-only batch in the coordinator's store-scoped
    /// context. Callers may inspect and prepare IDs before this method, but all
    /// SwiftData changes must happen inside `mutation`.
    @discardableResult
    func commitPrepared(
        _ command: CatalogMutationCommand,
        affectedBookIDs: Set<UUID> = [],
        affectedWorkIDs: Set<UUID> = [],
        affectedAssetIDs: Set<UUID>? = nil,
        affectedCollectionIDs: Set<UUID> = [],
        catalogChanged: Bool = true,
        revertingOnFailure rollbackMutation: () -> Void = {},
        applying mutation: (ModelContext) throws -> Void
    ) throws -> CatalogChangeSet {
        let receipt = try writeCoordinator.commit(
            command: command,
            affectedBookIDs: affectedBookIDs,
            affectedWorkIDs: affectedWorkIDs,
            affectedAssetIDs: affectedAssetIDs,
            affectedCollectionIDs: affectedCollectionIDs,
            revertingOnFailure: rollbackMutation,
            repairingInvariants: {
                try self.repairInvariants(
                    for: command,
                    affectedBookIDs: affectedBookIDs,
                    affectedWorkIDs: affectedWorkIDs
                )
            },
            applying: {
                try mutation(self.modelContext)
            }
        )
        return publish(receipt.changeSet, catalogChanged: catalogChanged)
    }

    /// Commits the SwiftData half of a managed-file transaction, then publishes
    /// staged payloads. A post-save filesystem failure is returned as pending
    /// recovery; the durable catalog mutation is never reported as rolled back.
    func commitFileMutation(
        _ command: CatalogMutationCommand,
        transaction: ManagedFileTransaction,
        affectedBookIDs: Set<UUID> = [],
        affectedWorkIDs: Set<UUID> = [],
        affectedAssetIDs: Set<UUID>? = nil,
        affectedCollectionIDs: Set<UUID> = [],
        catalogChanged: Bool = true,
        progress: ManagedFileProgressHandler? = nil,
        revertingOnFailure rollbackMutation: () -> Void = {},
        applying mutation: () throws -> Void
    ) async throws -> CatalogFileCommitResult {
        let receipt: CatalogCommitReceipt
        do {
            try await managedFiles.willCommitCatalog(transaction)
            receipt = try writeCoordinator.commit(
                operationID: transaction.id,
                command: command,
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs,
                affectedAssetIDs: affectedAssetIDs,
                affectedCollectionIDs: affectedCollectionIDs,
                revertingOnFailure: rollbackMutation,
                repairingInvariants: {
                    try self.repairInvariants(
                        for: command,
                        affectedBookIDs: affectedBookIDs,
                        affectedWorkIDs: affectedWorkIDs
                    )
                },
                applying: mutation
            )
        } catch let error as CatalogMutationError {
            await managedFiles.abort(transaction)
            throw error
        } catch {
            await managedFiles.abort(transaction)
            Log.persistence.error(
                "Managed catalog preflight failed before operation \(transaction.id.uuidString, privacy: .public) could commit: \(error.localizedDescription, privacy: .public)"
            )
            throw CatalogMutationError.fileTransactionFailed(error.localizedDescription)
        }

        let changeSet = publish(receipt.changeSet, catalogChanged: catalogChanged)
        let pending = await finalizeCommittedTransactions(
            [transaction],
            progress: progress
        )
        return CatalogFileCommitResult(changeSet: changeSet, pendingTransactionIDs: pending)
    }

    /// Commits models already inserted by a bounded import or migration chunk.
    /// Every transaction is aborted if the catalog save fails; after a durable
    /// save each journal is independently publishable and recoverable.
    func commitStagedFiles(
        _ command: CatalogMutationCommand,
        transactions: [ManagedFileTransaction],
        affectedBookIDs: Set<UUID> = [],
        affectedWorkIDs: Set<UUID> = [],
        affectedAssetIDs: Set<UUID>? = nil,
        affectedCollectionIDs: Set<UUID> = [],
        catalogChanged: Bool = true,
        revertingOnFailure rollbackMutation: () -> Void = {},
        applying mutation: () throws -> Void
    ) async throws -> CatalogFileCommitResult {
        let operationID = transactions.first?.id ?? UUID()
        let receipt: CatalogCommitReceipt
        do {
            for transaction in transactions {
                try await managedFiles.willCommitCatalog(transaction)
            }
            try Task.checkCancellation()
            receipt = try writeCoordinator.commit(
                operationID: operationID,
                command: command,
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs,
                affectedAssetIDs: affectedAssetIDs,
                affectedCollectionIDs: affectedCollectionIDs,
                revertingOnFailure: rollbackMutation,
                repairingInvariants: {
                    try self.repairInvariants(
                        for: command,
                        affectedBookIDs: affectedBookIDs,
                        affectedWorkIDs: affectedWorkIDs
                    )
                },
                applying: mutation
            )
        } catch let error as CatalogMutationError {
            for transaction in transactions {
                await managedFiles.abort(transaction)
            }
            throw error
        } catch {
            for transaction in transactions {
                await managedFiles.abort(transaction)
            }
            Log.persistence.error(
                "Managed catalog preflight failed before operation \(operationID.uuidString, privacy: .public) could commit: \(error.localizedDescription, privacy: .public)"
            )
            throw CatalogMutationError.fileTransactionFailed(error.localizedDescription)
        }

        let changeSet = publish(receipt.changeSet, catalogChanged: catalogChanged)
        let pending = await finalizeCommittedTransactions(transactions)
        return CatalogFileCommitResult(changeSet: changeSet, pendingTransactionIDs: pending)
    }

    private func repairInvariants(
        for command: CatalogMutationCommand,
        affectedBookIDs: Set<UUID>,
        affectedWorkIDs: Set<UUID>
    ) throws {
        var workIDs = affectedWorkIDs
        // Every catalog write is an opportunity to converge legacy rows. This
        // keeps compatibility mirrors and explicit cover ownership correct even
        // when an older caller only updates Book-level fields.
        let books: [Book]
        if affectedBookIDs.isEmpty {
            books = []
        } else {
            let requestedBookIDs = Array(affectedBookIDs)
            books = try modelContext.fetch(FetchDescriptor<Book>(
                predicate: #Predicate {
                    requestedBookIDs.contains($0.uuid)
                }
            ))
        }
        for book in books where book.modelContext != nil {
            CatalogModelInvariantService.repair(book: book)
            if let workID = book.work?.uuid { workIDs.insert(workID) }
        }
        if !workIDs.isEmpty {
            let requestedWorkIDs = Array(workIDs)
            let works = try modelContext.fetch(FetchDescriptor<Work>(
                predicate: #Predicate {
                    requestedWorkIDs.contains($0.uuid)
                }
            ))
            for work in works where work.modelContext != nil {
                WorkService.repairCatalogInvariant(work)
            }
        }
    }

    /// Repairs only model-derived catalog state for a targeted integrity
    /// snapshot. Missing Work rows receive pre-generated identities inside the
    /// same short store-scoped commit; no filesystem work or suspension occurs.
    @discardableResult
    func repairCatalogInvariants(
        bookIDs: Set<UUID>,
        workIDs: Set<UUID>
    ) throws -> CatalogChangeSet {
        guard !bookIDs.isEmpty || !workIDs.isEmpty else {
            throw CatalogMutationError.invalidRequest
        }

        let storedBooks = try books(ids: bookIDs)
        var resolvedWorkIDs = workIDs
        resolvedWorkIDs.formUnion(storedBooks.compactMap { $0.work?.uuid })
        let storedWorks = try works(ids: resolvedWorkIDs)
        let newWorkIDs = Dictionary(uniqueKeysWithValues:
            storedBooks.compactMap { book in
                book.work == nil ? (book.uuid, UUID()) : nil
            }
        )
        let affectedWorkIDs = resolvedWorkIDs.union(newWorkIDs.values)
        let affectedBookIDs = bookIDs.union(
            storedWorks.flatMap { $0.editions.map(\.uuid) }
        )
        let affectedAssetIDs = Set(storedBooks.flatMap { $0.assets.map(\.uuid) })
        let bookPreimages = storedBooks.map(CatalogBookMetadataPreimage.init)
        let assetPreimages = storedBooks
            .flatMap(\.assets)
            .map(CatalogBookAssetPreimage.init)
        let workPreimages = storedWorks.map(CatalogWorkPreimage.init)
        var insertedWorks: [Work] = []

        return try commit(
            .repairCatalogInvariants(
                bookIDs: Array(affectedBookIDs),
                workIDs: Array(affectedWorkIDs)
            ),
            affectedBookIDs: affectedBookIDs,
            affectedWorkIDs: affectedWorkIDs,
            affectedAssetIDs: affectedAssetIDs,
            revertingOnFailure: {
                for work in insertedWorks where work.modelContext != nil {
                    self.modelContext.delete(work)
                }
                workPreimages.forEach { $0.restore() }
                bookPreimages.forEach { $0.restore() }
                assetPreimages.forEach { $0.restore() }
            }
        ) {
            for book in storedBooks {
                if book.work == nil, let workID = newWorkIDs[book.uuid] {
                    let work = Work(
                        uuid: workID,
                        title: book.displayTitle,
                        author: book.author,
                        dateCreated: book.dateAdded
                    )
                    self.modelContext.insert(work)
                    book.work = work
                    work.preferredEditionUUID = book.uuid
                    insertedWorks.append(work)
                }
                CatalogModelInvariantService.repair(book: book)
            }
            for work in storedWorks + insertedWorks {
                WorkService.repairCatalogInvariant(work)
            }
        }
    }

    /// Full-library evidence is intentionally reserved for startup recovery
    /// and explicit integrity work. Normal commits use
    /// `managedFileVerificationSnapshot(for:)` below.
    func managedFileRecoverySnapshot() throws -> ManagedFileCatalogSnapshot {
        let books = try modelContext.fetch(FetchDescriptor<Book>())
        var fileNames: Set<String> = []
        var coverOwnerVersions: [CoverOwner: Int] = [:]
        var coverReferencesByBookID: [UUID: CoverReference] = [:]
        for book in books {
            if ManagedLeafName(rawValue: book.fileName) != nil {
                fileNames.insert(book.fileName)
            }
            fileNames.formUnion(
                book.assets.lazy.map(\.fileName).filter { ManagedLeafName(rawValue: $0) != nil }
            )
            coverOwnerVersions[.edition(book.uuid)] = book.coverVersion
            if let work = book.work {
                coverOwnerVersions[.work(work.uuid)] = work.coverVersion
            }
            for asset in book.assets {
                coverOwnerVersions[.generatedAsset(asset.uuid)] = asset.coverVersion
            }
            coverReferencesByBookID[book.uuid] = book.coverReference
        }
        return ManagedFileCatalogSnapshot(
            presentBookIDs: Set(books.map(\.uuid)),
            referencedBookFileNames: fileNames,
            coverVersions: Dictionary(uniqueKeysWithValues: books.map { ($0.uuid, $0.coverVersion) }),
            coverReferencesByBookID: coverReferencesByBookID,
            coverOwnerVersions: coverOwnerVersions
        )
    }

    /// Builds only the durable evidence mentioned by the committed journals.
    /// The number of fetches is bounded by model type, not catalog size.
    func managedFileVerificationSnapshot(
        for transactions: [ManagedFileTransaction]
    ) throws -> ManagedFileVerificationSnapshot {
        var bookIDs: Set<UUID> = []
        var fileNames: Set<String> = []
        var legacyCoverBookIDs: Set<UUID> = []
        var selectedCoverBookIDs: Set<UUID> = []
        var editionOwnerIDs: Set<UUID> = []
        var workOwnerIDs: Set<UUID> = []
        var assetOwnerIDs: Set<UUID> = []

        for transaction in transactions {
            let requirement = transaction.requirement
            bookIDs.formUnion(requirement.presentBookIDs)
            bookIDs.formUnion(requirement.absentBookIDs)
            bookIDs.formUnion(requirement.coverVersions.keys)
            legacyCoverBookIDs.formUnion(requirement.coverVersions.keys)
            fileNames.formUnion(requirement.referencedBookFileNames)
            fileNames.formUnion(requirement.unreferencedBookFileNames)

            for coverRequirement in requirement.coverRequirements ?? [] {
                selectedCoverBookIDs.formUnion(coverRequirement.selectedBookIDs)
                bookIDs.formUnion(coverRequirement.selectedBookIDs)
                switch coverRequirement.owner {
                case .edition(let id):
                    editionOwnerIDs.insert(id)
                    bookIDs.insert(id)
                case .work(let id):
                    workOwnerIDs.insert(id)
                case .generatedAsset(let id):
                    assetOwnerIDs.insert(id)
                }
            }
        }

        let requestedBookIDs = Array(bookIDs)
        let requestedFileNames = Array(fileNames)
        let requestedWorkIDs = Array(workOwnerIDs)
        let requestedAssetIDs = Array(assetOwnerIDs)
        var fetchCount = 0

        let books: [Book]
        if requestedBookIDs.isEmpty && requestedFileNames.isEmpty {
            books = []
        } else {
            let descriptor = FetchDescriptor<Book>(
                predicate: #Predicate {
                    requestedBookIDs.contains($0.uuid)
                        || requestedFileNames.contains($0.fileName)
                }
            )
            books = try modelContext.fetch(descriptor)
            fetchCount += 1
        }

        let assets: [BookAsset]
        if requestedAssetIDs.isEmpty && requestedFileNames.isEmpty {
            assets = []
        } else {
            let descriptor = FetchDescriptor<BookAsset>(
                predicate: #Predicate {
                    requestedAssetIDs.contains($0.uuid)
                        || requestedFileNames.contains($0.fileName)
                }
            )
            assets = try modelContext.fetch(descriptor)
            fetchCount += 1
        }

        let works: [Work]
        if requestedWorkIDs.isEmpty {
            works = []
        } else {
            let descriptor = FetchDescriptor<Work>(
                predicate: #Predicate { requestedWorkIDs.contains($0.uuid) }
            )
            works = try modelContext.fetch(descriptor)
            fetchCount += 1
        }

        var presentBookIDs: Set<UUID> = []
        var referencedBookFileNames: Set<String> = []
        var coverVersions: [UUID: Int] = [:]
        var coverReferencesByBookID: [UUID: CoverReference] = [:]
        var coverOwnerVersions: [CoverOwner: Int] = [:]

        for book in books {
            if bookIDs.contains(book.uuid) {
                presentBookIDs.insert(book.uuid)
            }
            if fileNames.contains(book.fileName),
               ManagedLeafName(rawValue: book.fileName) != nil {
                referencedBookFileNames.insert(book.fileName)
            }
            if legacyCoverBookIDs.contains(book.uuid) {
                coverVersions[book.uuid] = book.coverVersion
            }
            if editionOwnerIDs.contains(book.uuid) {
                coverOwnerVersions[.edition(book.uuid)] = book.coverVersion
            }
            if selectedCoverBookIDs.contains(book.uuid) {
                coverReferencesByBookID[book.uuid] = book.coverReference
            }
        }

        for asset in assets {
            if fileNames.contains(asset.fileName),
               ManagedLeafName(rawValue: asset.fileName) != nil {
                referencedBookFileNames.insert(asset.fileName)
            }
            if assetOwnerIDs.contains(asset.uuid) {
                coverOwnerVersions[.generatedAsset(asset.uuid)] = asset.coverVersion
            }
        }

        for work in works where workOwnerIDs.contains(work.uuid) {
            coverOwnerVersions[.work(work.uuid)] = work.coverVersion
        }

        let catalog = ManagedFileCatalogSnapshot(
            presentBookIDs: presentBookIDs,
            referencedBookFileNames: referencedBookFileNames,
            coverVersions: coverVersions,
            coverReferencesByBookID: coverReferencesByBookID,
            coverOwnerVersions: coverOwnerVersions
        )
        return ManagedFileVerificationSnapshot(
            catalog: catalog,
            metrics: ManagedFileVerificationMetrics(
                transactionCount: transactions.count,
                fetchCount: fetchCount,
                requestedBookCount: bookIDs.count,
                requestedFileNameCount: fileNames.count,
                requestedWorkOwnerCount: workOwnerIDs.count,
                requestedAssetOwnerCount: assetOwnerIDs.count
            )
        )
    }

    func recoverManagedFiles() async -> ManagedFileRecoveryReport {
        do {
            return await managedFiles.recover(against: try managedFileRecoverySnapshot())
        } catch {
            Log.persistence.error("Could not snapshot the catalog for managed-file recovery: \(error.localizedDescription, privacy: .public)")
            var report = ManagedFileRecoveryReport()
            report.failureMessages.append(error.localizedDescription)
            return report
        }
    }

    private func finalizeCommittedTransactions(
        _ transactions: [ManagedFileTransaction],
        progress: ManagedFileProgressHandler? = nil
    ) async -> [UUID] {
        let verification: ManagedFileVerificationSnapshot
        do {
            verification = try managedFileVerificationSnapshot(for: transactions)
        } catch {
            Log.persistence.error(
                "Managed file publication deferred because targeted catalog verification failed: \(error.localizedDescription, privacy: .public)"
            )
            return transactions.map(\.id)
        }

        let metrics = verification.metrics
        Log.persistence.debug(
            "Targeted managed-file verification used \(metrics.fetchCount) fetches for \(metrics.transactionCount) transactions, \(metrics.requestedBookCount) books, and \(metrics.requestedFileNameCount) file names"
        )
        var pending: [UUID] = []
        for transaction in transactions {
            do {
                try await managedFiles.catalogDidCommit(transaction)
                let outcome = try await managedFiles.reconcile(
                    transaction,
                    against: verification.catalog,
                    progress: progress
                )
                if outcome == .abortedCatalogDidNotCommit {
                    pending.append(transaction.id)
                }
            } catch {
                pending.append(transaction.id)
                Log.persistence.error(
                    "Managed file transaction \(transaction.id.uuidString, privacy: .public) is pending recovery: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return pending
    }

    private func publish(
        _ changeSet: CatalogChangeSet,
        catalogChanged: Bool
    ) -> CatalogChangeSet {
        var affectedBookIDs = changeSet.affectedBookIDs
        let workVisibleFields: CatalogChangeFields = [
            .identity,
            .displayMetadata,
            .workMembership,
        ]
        if !changeSet.affectedWorkIDs.isEmpty,
           !changeSet.fields.intersection(workVisibleFields).isEmpty {
            for workID in changeSet.affectedWorkIDs {
                if let work = try? work(id: workID) {
                    affectedBookIDs.formUnion(work.editions.map(\.uuid))
                }
            }
        }
        let publishedChangeSet = CatalogChangeSet(
            command: changeSet.command,
            affectedBookIDs: affectedBookIDs,
            affectedWorkIDs: changeSet.affectedWorkIDs,
            affectedAssetIDs: changeSet.affectedAssetIDs,
            affectedCollectionIDs: changeSet.affectedCollectionIDs,
            fields: changeSet.fields
        )
        invalidateAnalysis(for: publishedChangeSet)
        let fullTextAffectedBookIDs = fullTextAffectedBookIDs(for: publishedChangeSet)
        LibraryMutationLog.shared.bump(
            catalogChanged: catalogChanged,
            affectedBookIDs: publishedChangeSet.affectedBookIDs,
            affectedWorkIDs: publishedChangeSet.affectedWorkIDs,
            affectedAssetIDs: publishedChangeSet.affectedAssetIDs,
            affectedCollectionIDs: publishedChangeSet.affectedCollectionIDs,
            fields: publishedChangeSet.fields,
            changesBookMembership: publishedChangeSet.command.changesBookMembership,
            fullTextAffectedBookIDs: fullTextAffectedBookIDs
        )
        return publishedChangeSet
    }

    private func fullTextAffectedBookIDs(
        for changeSet: CatalogChangeSet
    ) -> Set<UUID>? {
        guard changeSet.command.changesFullTextIndex else { return [] }
        var bookIDs = changeSet.affectedBookIDs

        switch changeSet.command {
        case .updateMetadata(let bookID, _),
             .pluginUpdate(let bookID, _),
             .addFile(let bookID, _),
             .replaceFile(let bookID, _),
             .selectPrimaryAsset(let bookID, _),
             .removeFile(let bookID, _),
             .conversionOutput(let bookID, _),
             .applyAnalysis(let bookID, _):
            bookIDs.insert(bookID)

        case .updateMetadataBatch(let commandBookIDs, _, _),
             .assignEdition(let commandBookIDs, _),
             .importBooks(let commandBookIDs),
             .calibreImport(let commandBookIDs),
             .removeBooks(let commandBookIDs),
             .legacyMigration(let commandBookIDs),
             .applyAnalysisBatch(let commandBookIDs, _),
             .repairCatalogInvariants(let commandBookIDs, _):
            bookIDs.formUnion(commandBookIDs)

        case .addPhysicalBook(let bookID, _):
            bookIDs.insert(bookID)

        case .updateAssetValidation(_, let commandBookIDs):
            bookIDs.formUnion(commandBookIDs)

        case .restoreBook(let bookID, _, _):
            bookIDs.insert(bookID)

        case .reconcileEditions(let survivorID, let removedID, _):
            bookIDs.formUnion([survivorID, removedID])

        case .updateWork(let commandWorkID, _):
            for workID in changeSet.affectedWorkIDs.union([commandWorkID]) {
                guard let affectedWork = try? work(id: workID) else {
                    return nil
                }
                bookIDs.formUnion(affectedWork.editions.map(\.uuid))
            }

        case .setReadingStatus, .setReadingProgress,
             .createCollection, .updateCollection, .deleteCollection,
             .updateCover, .importHighlights, .maintenanceCleanup,
             .updateAuxiliaryStore:
            break
        }
        return bookIDs
    }

    private func invalidateAnalysis(for changeSet: CatalogChangeSet) {
        var invalidatedBookIDs: Set<UUID> = []

        switch changeSet.command {
        case .updateMetadata(let bookID, let fields),
             .pluginUpdate(let bookID, let fields):
            if !fields.isDisjoint(with: CatalogMutationCommand.identityMetadataFields) {
                invalidatedBookIDs.insert(bookID)
            }

        case .updateMetadataBatch(let bookIDs, _, let fields):
            if !fields.isDisjoint(with: CatalogMutationCommand.identityMetadataFields) {
                invalidatedBookIDs.formUnion(bookIDs)
            }

        case .assignEdition(let bookIDs, _):
            invalidatedBookIDs.formUnion(bookIDs)

        case .repairCatalogInvariants(let bookIDs, _):
            invalidatedBookIDs.formUnion(bookIDs)

        case .reconcileEditions(let survivorID, let removedID, _):
            invalidatedBookIDs.formUnion([survivorID, removedID])

        case .updateWork(_, let fields):
            if !fields.isDisjoint(with: CatalogMutationCommand.identityMetadataFields) {
                for workID in changeSet.affectedWorkIDs {
                    if let work = try? work(id: workID) {
                        invalidatedBookIDs.formUnion(work.editions.map(\.uuid))
                    }
                }
            }

        case .addFile(let bookID, _),
             .replaceFile(let bookID, _),
             .selectPrimaryAsset(let bookID, _),
             .removeFile(let bookID, _):
            invalidatedBookIDs.insert(bookID)

        case .removeBooks(let bookIDs):
            invalidatedBookIDs.formUnion(bookIDs)

        case .restoreBook(let bookID, let fields, _):
            if !fields.intersection([.identity, .assetAvailability, .fullTextSource]).isEmpty {
                invalidatedBookIDs.insert(bookID)
            }

        case .setReadingStatus, .setReadingProgress,
             .createCollection, .updateCollection, .deleteCollection,
             .addPhysicalBook, .importBooks, .calibreImport, .conversionOutput, .legacyMigration,
             .updateCover, .applyAnalysis, .applyAnalysisBatch,
             .updateAssetValidation, .importHighlights, .maintenanceCleanup,
             .updateAuxiliaryStore:
            break
        }

        analysisCoordinator.cancelAll(for: invalidatedBookIDs)
    }

    func book(id: UUID) throws -> Book {
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.uuid == id })
        descriptor.fetchLimit = 1
        guard let book = try modelContext.fetch(descriptor).first else {
            throw CatalogMutationError.modelNotFound
        }
        return book
    }

    func books(ids: Set<UUID>) throws -> [Book] {
        guard !ids.isEmpty else { return [] }
        let requestedIDs = Array(ids)
        let descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { requestedIDs.contains($0.uuid) }
        )
        let books = try modelContext.fetch(descriptor)
        guard books.count == ids.count else {
            throw CatalogMutationError.modelNotFound
        }
        return books
    }

    func work(id: UUID) throws -> Work {
        var descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.uuid == id })
        descriptor.fetchLimit = 1
        guard let work = try modelContext.fetch(descriptor).first else {
            throw CatalogMutationError.modelNotFound
        }
        return work
    }

    func works(ids: Set<UUID>) throws -> [Work] {
        guard !ids.isEmpty else { return [] }
        let requestedIDs = Array(ids)
        let descriptor = FetchDescriptor<Work>(
            predicate: #Predicate { requestedIDs.contains($0.uuid) }
        )
        let works = try modelContext.fetch(descriptor)
        guard works.count == ids.count else {
            throw CatalogMutationError.modelNotFound
        }
        return works
    }

    func assets(ids: Set<UUID>) throws -> [BookAsset] {
        guard !ids.isEmpty else { return [] }
        let requestedIDs = Array(ids)
        let descriptor = FetchDescriptor<BookAsset>(
            predicate: #Predicate { requestedIDs.contains($0.uuid) }
        )
        let assets = try modelContext.fetch(descriptor)
        guard assets.count == ids.count else {
            throw CatalogMutationError.modelNotFound
        }
        return assets
    }

    func collection(id: UUID) throws -> BookCollection {
        var descriptor = FetchDescriptor<BookCollection>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let collection = try modelContext.fetch(descriptor).first else {
            throw CatalogMutationError.modelNotFound
        }
        return collection
    }
}
