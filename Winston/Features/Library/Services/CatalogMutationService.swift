import Foundation
import OSLog
import SwiftData

@MainActor
struct CatalogSaveAdapter {
    var save: (ModelContext) throws -> Void

    static let live = CatalogSaveAdapter { context in
        try context.save()
    }
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

    var changesBookMembership: Bool {
        switch self {
        case .addPhysicalBook, .importBooks, .calibreImport, .removeBooks, .legacyMigration,
             .reconcileEditions:
            true
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
                [.identity, .displayMetadata, .fullTextSource]
            case .assetHash, .assetInspection:
                [.assetAvailability, .fullTextSource]
            case .pageCount:
                [.displayMetadata]
            case .fileSize, .drmInspection:
                [.assetAvailability]
            }

        case .addPhysicalBook, .importBooks, .calibreImport, .removeBooks, .legacyMigration,
             .reconcileEditions:
            .all
        }
    }

    var changesFullTextIndex: Bool {
        changeFields.contains(.fullTextSource)
    }

    var affectedAssetIDs: Set<UUID> {
        switch self {
        case .addFile(_, let assetID),
             .replaceFile(_, let assetID),
             .selectPrimaryAsset(_, let assetID),
             .removeFile(_, let assetID),
             .conversionOutput(_, let assetID):
            [assetID]
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
        if !fields.isDisjoint(with: ["title", "author"]) {
            result.insert(.fullTextSource)
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
    case modelNotFound
    case staleAnalysis
    case staleReconciliation
    case staleConversion
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
    let pageCount: Int?

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
        pageCount = book.pageCount
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
        book.pageCount = pageCount
    }
}

struct CatalogBookAssetPreimage {
    let asset: BookAsset
    let contentHash: String?
    let sizeBytes: Int64
    let validationStatusRaw: String?

    init(_ asset: BookAsset) {
        self.asset = asset
        contentHash = asset.contentHash
        sizeBytes = asset.sizeBytes
        validationStatusRaw = asset.validationStatusRaw
    }

    func restore() {
        asset.contentHash = contentHash
        asset.sizeBytes = sizeBytes
        asset.validationStatusRaw = validationStatusRaw
    }
}

struct CatalogWorkPreimage {
    let work: Work
    let title: String?
    let author: String?
    let originalTitle: String?
    let originalLanguage: String?
    let matchKey: String?
    let openLibraryWorkKey: String?
    let hardcoverBookID: String?
    let preferredEditionUUID: UUID?
    let notes: String?

    init(_ work: Work) {
        self.work = work
        title = work.title
        author = work.author
        originalTitle = work.originalTitle
        originalLanguage = work.originalLanguage
        matchKey = work.matchKey
        openLibraryWorkKey = work.openLibraryWorkKey
        hardcoverBookID = work.hardcoverBookID
        preferredEditionUUID = work.preferredEditionUUID
        notes = work.notes
    }

    func restore() {
        work.title = title
        work.author = author
        work.originalTitle = originalTitle
        work.originalLanguage = originalLanguage
        work.matchKey = matchKey
        work.openLibraryWorkKey = openLibraryWorkKey
        work.hardcoverBookID = hardcoverBookID
        work.preferredEditionUUID = preferredEditionUUID
        work.notes = notes
    }
}

@MainActor
final class CatalogMutationService {
    private let modelContext: ModelContext
    private let saveAdapter: CatalogSaveAdapter
    private let managedFiles: ManagedFileCoordinator
    let analysisCoordinator: CatalogAnalysisCoordinator
    let editionIdentity = EditionIdentityCoordinator()

    init(
        modelContext: ModelContext,
        saveAdapter: CatalogSaveAdapter = .live,
        managedFiles: ManagedFileCoordinator = .shared,
        analysisCoordinator: CatalogAnalysisCoordinator? = nil
    ) {
        self.modelContext = modelContext
        self.saveAdapter = saveAdapter
        self.managedFiles = managedFiles
        self.analysisCoordinator = analysisCoordinator ?? CatalogAnalysisCoordinator()
    }

    @discardableResult
    func commit(
        _ command: CatalogMutationCommand,
        affectedBookIDs: Set<UUID> = [],
        affectedWorkIDs: Set<UUID> = [],
        affectedCollectionIDs: Set<UUID> = [],
        catalogChanged: Bool = true,
        revertingOnFailure rollbackMutation: () -> Void = {},
        applying mutation: () throws -> Void
    ) throws -> CatalogChangeSet {
        guard !modelContext.hasChanges else {
            modelContext.rollback()
            Log.persistence.error("Catalog mutation refused a dirty context and rolled it back")
            throw CatalogMutationError.dirtyContext
        }

        do {
            try mutation()
            modelContext.processPendingChanges()
            repairInvariants(
                for: command,
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs
            )
            modelContext.processPendingChanges()
            try saveAdapter.save(modelContext)
            return publish(CatalogChangeSet(
                command: command,
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs,
                affectedCollectionIDs: affectedCollectionIDs
            ), catalogChanged: catalogChanged)
        } catch let error as CatalogMutationError {
            rollbackMutation()
            modelContext.rollback()
            Log.persistence.error("Catalog mutation rolled back: \(String(describing: error), privacy: .public)")
            throw error
        } catch {
            rollbackMutation()
            modelContext.rollback()
            Log.persistence.error("Catalog mutation save failed and rolled back: \(error.localizedDescription, privacy: .public)")
            throw CatalogMutationError.saveFailed(error.localizedDescription)
        }
    }

    /// Commits a deliberately staged batch, such as a bounded import chunk.
    /// Unlike `commit`, the caller has already inserted or changed the models.
    @discardableResult
    func commitStaged(
        _ command: CatalogMutationCommand,
        affectedBookIDs: Set<UUID> = [],
        affectedWorkIDs: Set<UUID> = [],
        affectedCollectionIDs: Set<UUID> = [],
        catalogChanged: Bool = true
    ) throws -> CatalogChangeSet {
        do {
            modelContext.processPendingChanges()
            repairInvariants(
                for: command,
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs
            )
            modelContext.processPendingChanges()
            try saveAdapter.save(modelContext)
            return publish(CatalogChangeSet(
                command: command,
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs,
                affectedCollectionIDs: affectedCollectionIDs
            ), catalogChanged: catalogChanged)
        } catch {
            modelContext.rollback()
            Log.persistence.error("Staged catalog mutation save failed and rolled back: \(error.localizedDescription, privacy: .public)")
            throw CatalogMutationError.saveFailed(error.localizedDescription)
        }
    }

    /// Commits the SwiftData half of a managed-file transaction, then publishes
    /// staged payloads. A post-save filesystem failure is returned as pending
    /// recovery; the durable catalog mutation is never reported as rolled back.
    func commitFileMutation(
        _ command: CatalogMutationCommand,
        transaction: ManagedFileTransaction,
        affectedBookIDs: Set<UUID> = [],
        affectedWorkIDs: Set<UUID> = [],
        affectedCollectionIDs: Set<UUID> = [],
        catalogChanged: Bool = true,
        progress: ManagedFileProgressHandler? = nil,
        revertingOnFailure rollbackMutation: () -> Void = {},
        applying mutation: () throws -> Void
    ) async throws -> CatalogFileCommitResult {
        guard !modelContext.hasChanges else {
            discardPendingChanges()
            await managedFiles.abort(transaction)
            discardPendingChanges()
            Log.persistence.error("Managed catalog mutation refused a dirty context and rolled it back")
            throw CatalogMutationError.dirtyContext
        }

        var mutationStarted = false
        do {
            try await managedFiles.willCommitCatalog(transaction)
            mutationStarted = true
            try mutation()
            modelContext.processPendingChanges()
            repairInvariants(
                for: command,
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs
            )
            modelContext.processPendingChanges()
            try saveAdapter.save(modelContext)
        } catch let error as CatalogMutationError {
            if mutationStarted { rollbackMutation() }
            discardPendingChanges()
            await managedFiles.abort(transaction)
            discardPendingChanges()
            throw error
        } catch {
            if mutationStarted { rollbackMutation() }
            discardPendingChanges()
            await managedFiles.abort(transaction)
            discardPendingChanges()
            Log.persistence.error(
                "Managed catalog mutation failed before commit and rolled back: \(error.localizedDescription, privacy: .public)"
            )
            throw CatalogMutationError.saveFailed(error.localizedDescription)
        }

        let changeSet = publish(CatalogChangeSet(
            command: command,
            affectedBookIDs: affectedBookIDs,
            affectedWorkIDs: affectedWorkIDs,
            affectedCollectionIDs: affectedCollectionIDs
        ), catalogChanged: catalogChanged)
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
        affectedCollectionIDs: Set<UUID> = [],
        catalogChanged: Bool = true,
        revertingOnFailure rollbackMutation: () -> Void = {}
    ) async throws -> CatalogFileCommitResult {
        do {
            for transaction in transactions {
                try await managedFiles.willCommitCatalog(transaction)
            }
            modelContext.processPendingChanges()
            repairInvariants(
                for: command,
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs
            )
            modelContext.processPendingChanges()
            try saveAdapter.save(modelContext)
        } catch {
            rollbackMutation()
            discardPendingChanges()
            for transaction in transactions {
                await managedFiles.abort(transaction)
            }
            discardPendingChanges()
            Log.persistence.error(
                "Staged managed catalog mutation failed before commit and rolled back: \(error.localizedDescription, privacy: .public)"
            )
            throw CatalogMutationError.saveFailed(error.localizedDescription)
        }

        let changeSet = publish(CatalogChangeSet(
            command: command,
            affectedBookIDs: affectedBookIDs,
            affectedWorkIDs: affectedWorkIDs,
            affectedCollectionIDs: affectedCollectionIDs
        ), catalogChanged: catalogChanged)
        let pending = await finalizeCommittedTransactions(transactions)
        return CatalogFileCommitResult(changeSet: changeSet, pendingTransactionIDs: pending)
    }

    private func repairInvariants(
        for command: CatalogMutationCommand,
        affectedBookIDs: Set<UUID>,
        affectedWorkIDs: Set<UUID>
    ) {
        var workIDs = affectedWorkIDs
        if command.changeFields.contains(.assetAvailability)
            || command.changesBookMembership {
            for bookID in affectedBookIDs {
                guard let book = try? book(id: bookID), book.modelContext != nil else {
                    continue
                }
                book.repairPrimaryAssetInvariant()
                if let workID = book.work?.uuid { workIDs.insert(workID) }
            }
        }
        if command.changeFields.contains(.workMembership)
            || command.changesBookMembership {
            for workID in workIDs {
                guard let work = try? work(id: workID), work.modelContext != nil else {
                    continue
                }
                WorkService.repairPreferredEditionInvariant(work)
            }
        }
    }

    func managedFileSnapshot() throws -> ManagedFileCatalogSnapshot {
        let books = try modelContext.fetch(FetchDescriptor<Book>())
        var fileNames: Set<String> = []
        for book in books {
            if ManagedLeafName(rawValue: book.fileName) != nil {
                fileNames.insert(book.fileName)
            }
            fileNames.formUnion(
                book.assets.lazy.map(\.fileName).filter { ManagedLeafName(rawValue: $0) != nil }
            )
        }
        return ManagedFileCatalogSnapshot(
            presentBookIDs: Set(books.map(\.uuid)),
            referencedBookFileNames: fileNames,
            coverVersions: Dictionary(uniqueKeysWithValues: books.map { ($0.uuid, $0.coverVersion) })
        )
    }

    func recoverManagedFiles() async -> ManagedFileRecoveryReport {
        do {
            return await managedFiles.recover(against: try managedFileSnapshot())
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
        let snapshot: ManagedFileCatalogSnapshot
        do {
            snapshot = try managedFileSnapshot()
        } catch {
            Log.persistence.error(
                "Managed file publication deferred because catalog snapshot failed: \(error.localizedDescription, privacy: .public)"
            )
            return transactions.map(\.id)
        }

        var pending: [UUID] = []
        for transaction in transactions {
            do {
                try await managedFiles.catalogDidCommit(transaction)
                let outcome = try await managedFiles.reconcile(
                    transaction,
                    against: snapshot,
                    progress: progress
                )
                if outcome != .completed { pending.append(transaction.id) }
            } catch {
                pending.append(transaction.id)
                Log.persistence.error(
                    "Managed file transaction \(transaction.id.uuidString, privacy: .public) is pending recovery: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return pending
    }

    /// SwiftData can enqueue inverse-relationship updates while a compensator
    /// removes freshly inserted models. Flush those callbacks before and after
    /// rollback so the main context cannot become dirty again on the next run
    /// loop turn and leak a failed mutation into an unrelated save.
    private func discardPendingChanges() {
        modelContext.processPendingChanges()
        modelContext.rollback()
        modelContext.processPendingChanges()
        if modelContext.hasChanges { modelContext.rollback() }
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
             .applyAnalysisBatch(let commandBookIDs, _):
            bookIDs.formUnion(commandBookIDs)

        case .addPhysicalBook(let bookID, _):
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
             .updateCover:
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

        case .setReadingStatus, .setReadingProgress,
             .createCollection, .updateCollection, .deleteCollection,
             .addPhysicalBook, .importBooks, .calibreImport, .conversionOutput, .legacyMigration,
             .updateCover, .applyAnalysis, .applyAnalysisBatch:
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

    func collection(id: UUID) throws -> BookCollection {
        var descriptor = FetchDescriptor<BookCollection>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let collection = try modelContext.fetch(descriptor).first else {
            throw CatalogMutationError.modelNotFound
        }
        return collection
    }
}
