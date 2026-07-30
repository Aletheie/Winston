import Foundation
import SwiftData

nonisolated enum LibraryTimeMachineRestoreScope: String, Sendable, Identifiable {
    case metadata
    case cover
    case book

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .metadata: "Restore Metadata"
        case .cover: "Restore Cover"
        case .book: "Restore Book"
        }
    }

    var confirmationTitle: LocalizedStringResource {
        switch self {
        case .metadata: "Restore this book’s metadata?"
        case .cover: "Restore this book’s cover?"
        case .book: "Restore this book from the backup?"
        }
    }

    var confirmationMessage: LocalizedStringResource {
        switch self {
        case .metadata:
            "Current bibliographic metadata, ratings, and notes will be replaced. Reading history, highlights, collections, and book files stay untouched."
        case .cover:
            "The current saved cover will be replaced. Metadata, reading data, and book files stay untouched."
        case .book:
            "Metadata, reading history, highlights, collection memberships, and the saved cover will return to this backup’s state. Book files stay untouched."
        }
    }
}

nonisolated struct LibraryTimeMachineRestoreResult: Equatable, Sendable {
    let bookID: UUID
    let scope: LibraryTimeMachineRestoreScope
    let createdBook: Bool
    let bookFileMissing: Bool
    let skippedCollectionCount: Int
    let safetyBackupURL: URL
}

enum LibraryTimeMachineRestoreError: LocalizedError {
    case bookUnavailable
    case backupCoverUnavailable
    case backupCoverUnreadable
    case backupWorkCoverOwnerUnavailable
    case backupAssetCoverOwnerUnavailable
    case backupCoverOwnerInvalid
    case safetyBackupFailed(String)
    case coverWriteFailed
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .bookUnavailable:
            String(localized: "This book is no longer available for that restore action.")
        case .backupCoverUnavailable:
            String(localized: "This backup does not contain a saved cover for the book.")
        case .backupCoverUnreadable:
            String(localized: "The saved cover in this backup could not be read.")
        case .backupWorkCoverOwnerUnavailable:
            String(localized: "The backup cover refers to a work that is unavailable.")
        case .backupAssetCoverOwnerUnavailable:
            String(localized: "The backup cover refers to a generated file that is unavailable.")
        case .backupCoverOwnerInvalid:
            String(localized: "The backup contains an invalid saved-cover owner.")
        case .safetyBackupFailed(let reason):
            String(
                localized: "A safety backup could not be created: \(reason)",
                comment: "Restore error. The interpolated value describes the underlying failure."
            )
        case .coverWriteFailed:
            String(localized: "The restored cover could not be saved.")
        case .saveFailed(let reason):
            String(
                localized: "The restored book could not be saved: \(reason)",
                comment: "Restore error. The interpolated value describes the underlying failure."
            )
        }
    }
}

@MainActor
private struct LibraryTimeMachineBookPreimage {
    private struct Session {
        let model: ReadingSession
        let startedAt: Date
        let endedAt: Date?
        let statusRaw: String
        let progress: Double
    }

    let book: Book
    let metadata: CatalogBookMetadataPreimage
    let readingStatusRaw: String?
    let dateStarted: Date?
    let dateFinished: Date?
    let editionStatement: String?
    let editionTypeRaw: String?
    let hasPhysicalCopyRaw: Bool?
    let collections: [BookCollection]
    let highlights: [Highlight]
    private let sessions: [Session]

    init(_ book: Book) {
        self.book = book
        metadata = CatalogBookMetadataPreimage(book)
        readingStatusRaw = book.readingStatusRaw
        dateStarted = book.dateStarted
        dateFinished = book.dateFinished
        editionStatement = book.editionStatement
        editionTypeRaw = book.editionTypeRaw
        hasPhysicalCopyRaw = book.hasPhysicalCopyRaw
        collections = book.collections
        highlights = book.highlights
        sessions = book.readingSessions.map {
            Session(
                model: $0,
                startedAt: $0.startedAt,
                endedAt: $0.endedAt,
                statusRaw: $0.statusRaw,
                progress: $0.progress
            )
        }
    }

    func restore(in context: ModelContext) {
        metadata.restore()
        book.readingStatusRaw = readingStatusRaw
        book.dateStarted = dateStarted
        book.dateFinished = dateFinished
        book.editionStatement = editionStatement
        book.editionTypeRaw = editionTypeRaw
        book.hasPhysicalCopyRaw = hasPhysicalCopyRaw
        book.collections = collections

        let originalHighlights = Set(highlights.map(ObjectIdentifier.init))
        for highlight in book.highlights
        where !originalHighlights.contains(ObjectIdentifier(highlight)) {
            highlight.book = nil
            if highlight.modelContext != nil { context.delete(highlight) }
        }
        book.highlights = highlights
        highlights.forEach { $0.book = book }

        let originalSessions = Set(sessions.map { ObjectIdentifier($0.model) })
        for session in book.readingSessions
        where !originalSessions.contains(ObjectIdentifier(session)) {
            session.book = nil
            if session.modelContext != nil { context.delete(session) }
        }
        book.readingSessions = sessions.map(\.model)
        for session in sessions {
            session.model.startedAt = session.startedAt
            session.model.endedAt = session.endedAt
            session.model.statusRaw = session.statusRaw
            session.model.progress = session.progress
            session.model.book = book
        }
    }
}

@MainActor
struct LibraryTimeMachineRestorer {
    typealias SafetyBackupAction = @Sendable (URL) async throws -> URL

    private struct CoverRestorePlan {
        let owner: CoverOwner
        let selectedBookIDs: Set<UUID>
        let expectedBookReferences: [UUID: CoverReference]
        let targetMayBeCreated: Bool
    }

    private let modelContext: ModelContext
    private let createSafetyBackup: SafetyBackupAction
    private let mutations: CatalogMutationService
    private let managedFiles: ManagedFileCoordinator
    private let coverMutations: CoverMutationCoordinator

    init(
        modelContext: ModelContext,
        liveStoreURL: URL = PersistenceController.storeURL,
        coversDirectory: URL = AppPaths.coversDirectory,
        createSafetyBackup: SafetyBackupAction? = nil,
        managedFiles: ManagedFileCoordinator? = nil,
        mutationService: CatalogMutationService? = nil,
        coverMutationCoordinator: CoverMutationCoordinator? = nil
    ) {
        self.modelContext = modelContext
        let fileCoordinator: ManagedFileCoordinator
        if let managedFiles {
            fileCoordinator = managedFiles
        } else if let mutationService {
            fileCoordinator = mutationService.managedFiles
        } else if coversDirectory.standardizedFileURL == AppPaths.coversDirectory.standardizedFileURL {
            fileCoordinator = .shared
        } else {
            let root = coversDirectory.deletingLastPathComponent()
            fileCoordinator = ManagedFileCoordinator(
                booksDirectory: root.appending(path: "Books", directoryHint: .isDirectory),
                coversDirectory: coversDirectory,
                stateDirectory: root.appending(path: "ManagedFiles", directoryHint: .isDirectory)
            )
        }
        self.managedFiles = fileCoordinator
        let resolvedMutations = mutationService ?? CatalogMutationService(
            modelContext: modelContext,
            managedFiles: fileCoordinator
        )
        mutations = resolvedMutations
        coverMutations = coverMutationCoordinator ?? CoverMutationCoordinator.resolve(
            modelContext: modelContext,
            mutations: resolvedMutations,
            managedFiles: fileCoordinator
        )
        if let createSafetyBackup {
            self.createSafetyBackup = createSafetyBackup
        } else {
            self.createSafetyBackup = { sourceBackup in
                do {
                    return try await fileCoordinator.createBackup(
                        storeURL: liveStoreURL,
                        to: sourceBackup.deletingLastPathComponent(),
                        keepLast: Int.max
                    )
                } catch {
                    throw LibraryTimeMachineRestoreError.safetyBackupFailed(
                        error.localizedDescription
                    )
                }
            }
        }
    }

    func restore(
        _ snapshot: LibraryTimeMachineBookSnapshot,
        scope: LibraryTimeMachineRestoreScope,
        from sourceBackup: URL
    ) async throws -> LibraryTimeMachineRestoreResult {
        let existing: Book?
        do {
            existing = try mutations.book(id: snapshot.id)
        } catch CatalogMutationError.modelNotFound {
            existing = nil
        } catch {
            throw LibraryTimeMachineRestoreError.saveFailed(
                error.localizedDescription
            )
        }
        if scope != .book, existing == nil {
            throw LibraryTimeMachineRestoreError.bookUnavailable
        }

        guard !modelContext.hasChanges else {
            throw LibraryTimeMachineRestoreError.saveFailed(
                "The catalog contains unrelated unsaved changes."
            )
        }
        let coverIsIncluded = scope == .cover || scope == .book
        let createdBook = scope == .book && existing == nil
        let coverPlan = try coverIsIncluded
            ? makeCoverRestorePlan(
                for: snapshot,
                existing: existing,
                createdBook: createdBook
            )
            : nil
        let restoredCoverData = try await coverData(for: snapshot, scope: scope)

        let safetyBackup: URL
        do {
            safetyBackup = try await createSafetyBackup(sourceBackup)
        } catch let error as LibraryTimeMachineRestoreError {
            throw error
        } catch {
            throw LibraryTimeMachineRestoreError.safetyBackupFailed(error.localizedDescription)
        }

        var restoredBook: Book?
        var skippedCollections = 0
        var insertedWork: Work?
        let preimage = existing.map(LibraryTimeMachineBookPreimage.init)
        let fields: CatalogChangeFields = switch scope {
        case .metadata: [.identity, .displayMetadata]
        case .cover: [.cover]
        case .book: .all
        }
        var affectedWorkIDs = Set([
            existing?.work?.uuid,
            createdBook ? snapshot.work?.id : nil,
        ].compactMap { $0 })
        var affectedAssetIDs = createdBook
            ? Set(snapshot.assets.map(\.id))
            : Set(existing?.assets.map(\.uuid) ?? [])
        if let owner = coverPlan?.owner {
            switch owner {
            case .work(let workID):
                affectedWorkIDs.insert(workID)
            case .generatedAsset(let assetID):
                affectedAssetIDs.insert(assetID)
            case .edition:
                break
            }
        }
        let affectedCollectionIDs = scope == .book
            ? Set(snapshot.collections.map(\.id))
            : []
        let preparedCover: PreparedCoverMutation?
        if let coverPlan {
            do {
                preparedCover = try await coverMutations.prepare(
                    payload: restoredCoverData,
                    targetReference: CoverReference(
                        owner: coverPlan.owner,
                        version: snapshot.coverVersion
                    ),
                    selectedBookIDs: coverPlan.selectedBookIDs,
                    expectedBookReferences: coverPlan.expectedBookReferences,
                    priority: .user,
                    intent: .restore,
                    targetMayBeCreated: coverPlan.targetMayBeCreated
                )
            } catch {
                throw LibraryTimeMachineRestoreError.coverWriteFailed
            }
        } else {
            preparedCover = nil
        }

        let rollbackMutation = {
            if let preimage {
                preimage.restore(in: self.modelContext)
            } else if let restoredBook {
                self.discardInsertedBook(
                    restoredBook,
                    insertedWork: insertedWork
                )
            }
        }
        let applyMutation = {
            switch scope {
            case .metadata:
                guard let existing else {
                    throw CatalogMutationError.modelNotFound
                }
                restoredBook = existing
                applyMetadata(snapshot.metadata, to: existing)

            case .cover:
                guard let existing else {
                    throw CatalogMutationError.modelNotFound
                }
                restoredBook = existing

            case .book:
                let book: Book
                if let existing {
                    book = existing
                } else {
                    book = makeBook(from: snapshot)
                    self.modelContext.insert(book)
                }
                restoredBook = book
                applyMetadata(snapshot.metadata, to: book)
                book.readingStatusRaw = snapshot.reading.statusRaw
                book.dateStarted = snapshot.reading.dateStarted
                book.dateFinished = snapshot.reading.dateFinished
                replaceReadingSessions(on: book, with: snapshot.reading.sessions)
                replaceHighlights(on: book, with: snapshot.highlights)
                skippedCollections = try restoreCollectionMemberships(
                    on: book,
                    from: snapshot.collections
                )
                if createdBook {
                    restoreAssets(
                        on: book,
                        from: snapshot.assets,
                        primaryAssetID: snapshot.primaryAssetID
                    )
                    insertedWork = try restoreWork(
                        on: book,
                        from: snapshot.work
                    )
                }
            }

        }

        do {
            if let preparedCover {
                _ = try await coverMutations.commit(
                    preparedCover,
                    command: .restoreBook(
                        bookID: snapshot.id,
                        fields: fields,
                        createsBook: createdBook
                    ),
                    affectedBookIDs: [snapshot.id],
                    affectedWorkIDs: affectedWorkIDs,
                    affectedAssetIDs: affectedAssetIDs,
                    affectedCollectionIDs: affectedCollectionIDs,
                    revertingOnFailure: rollbackMutation,
                    applying: applyMutation
                )
            } else {
                try mutations.commit(
                    .restoreBook(
                        bookID: snapshot.id,
                        fields: fields,
                        createsBook: createdBook
                    ),
                    affectedBookIDs: [snapshot.id],
                    affectedWorkIDs: affectedWorkIDs,
                    affectedAssetIDs: affectedAssetIDs,
                    affectedCollectionIDs: affectedCollectionIDs,
                    revertingOnFailure: rollbackMutation,
                    applying: applyMutation
                )
            }
        } catch {
            throw LibraryTimeMachineRestoreError.saveFailed(error.localizedDescription)
        }

        return LibraryTimeMachineRestoreResult(
            bookID: snapshot.id,
            scope: scope,
            createdBook: createdBook,
            bookFileMissing: restoredBook.map { book in
                guard let url = book.primaryFileURL else { return false }
                return !FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
            } ?? true,
            skippedCollectionCount: skippedCollections,
            safetyBackupURL: safetyBackup
        )
    }

    private func makeCoverRestorePlan(
        for snapshot: LibraryTimeMachineBookSnapshot,
        existing: Book?,
        createdBook: Bool
    ) throws -> CoverRestorePlan {
        guard let owner = snapshot.coverOwner else {
            switch snapshot.coverScopeRaw.flatMap(CoverScope.init(rawValue:)) {
            case .work:
                throw LibraryTimeMachineRestoreError.backupWorkCoverOwnerUnavailable
            case .generatedAsset:
                throw LibraryTimeMachineRestoreError.backupAssetCoverOwnerUnavailable
            case .edition, .none:
                throw LibraryTimeMachineRestoreError.backupCoverOwnerInvalid
            }
        }

        var selectedBookIDs: Set<UUID> = [snapshot.id]
        switch owner {
        case .edition(let bookID):
            guard bookID == snapshot.id else {
                throw LibraryTimeMachineRestoreError.backupCoverOwnerInvalid
            }

        case .work(let workID):
            guard snapshot.work?.id == workID else {
                throw LibraryTimeMachineRestoreError.backupWorkCoverOwnerUnavailable
            }
            let work: Work?
            do {
                work = try mutations.work(id: workID)
            } catch CatalogMutationError.modelNotFound {
                guard createdBook else {
                    throw LibraryTimeMachineRestoreError.backupWorkCoverOwnerUnavailable
                }
                work = nil
            } catch {
                throw LibraryTimeMachineRestoreError.saveFailed(
                    error.localizedDescription
                )
            }
            if let existing, existing.work?.uuid != workID {
                throw LibraryTimeMachineRestoreError.backupWorkCoverOwnerUnavailable
            }
            if let work {
                selectedBookIDs.formUnion(
                    work.editions.lazy
                        .filter { $0.coverReference.owner == owner }
                        .map(\.uuid)
                )
            }

        case .generatedAsset(let assetID):
            guard snapshot.coverAssetUUID == assetID,
                  snapshot.assets.contains(where: { $0.id == assetID }) else {
                throw LibraryTimeMachineRestoreError.backupAssetCoverOwnerUnavailable
            }
            if let existing,
               !existing.assets.contains(where: { $0.uuid == assetID }) {
                throw LibraryTimeMachineRestoreError.backupAssetCoverOwnerUnavailable
            }
        }

        var expectedBookReferences: [UUID: CoverReference] = [:]
        for bookID in selectedBookIDs {
            do {
                let book = try mutations.book(id: bookID)
                expectedBookReferences[bookID] = book.coverReference
            } catch CatalogMutationError.modelNotFound
                        where createdBook && bookID == snapshot.id {
                continue
            } catch {
                throw LibraryTimeMachineRestoreError.saveFailed(
                    error.localizedDescription
                )
            }
        }
        return CoverRestorePlan(
            owner: owner,
            selectedBookIDs: selectedBookIDs,
            expectedBookReferences: expectedBookReferences,
            targetMayBeCreated: createdBook
        )
    }

    private func coverData(
        for snapshot: LibraryTimeMachineBookSnapshot,
        scope: LibraryTimeMachineRestoreScope
    ) async throws -> Data? {
        guard scope == .cover || scope == .book else { return nil }
        if scope == .cover, snapshot.coverURL == nil {
            throw LibraryTimeMachineRestoreError.backupCoverUnavailable
        }
        guard let coverURL = snapshot.coverURL else { return nil }
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: coverURL)
        }.value
        guard let data else { throw LibraryTimeMachineRestoreError.backupCoverUnreadable }
        return data
    }

    private func applyMetadata(
        _ metadata: LibraryTimeMachineMetadataSnapshot,
        to book: Book
    ) {
        mutations.editionIdentity.apply(
            EditionIdentityPatch(
                fields: [.title, .author, .isbn],
                title: metadata.title,
                author: metadata.author,
                isbn: metadata.isbn
            ),
            to: book,
            scope: .editionOnly
        )
        book.publisher = metadata.publisher
        book.year = metadata.year
        book.language = metadata.language
        book.translator = metadata.translator
        book.series = metadata.series
        book.seriesIndex = metadata.seriesIndex
        book.tags = metadata.tags
        book.bookDescription = metadata.bookDescription
        book.rating = metadata.rating
        book.communityRating = metadata.communityRating
        book.communityRatingCount = metadata.communityRatingCount
        book.communityRatingSource = metadata.communityRatingSource
        book.notes = metadata.notes
        if book.assets.isEmpty {
            // Legacy snapshots predate per-asset DRM. Invariant repair seeds
            // the restored primary asset from this compatibility value.
            book.drmProtected = metadata.drmProtected
        }
        book.pageCount = metadata.pageCount
        book.editionStatement = metadata.editionStatement
        book.editionTypeRaw = metadata.editionTypeRaw
        book.hasPhysicalCopyRaw = metadata.hasPhysicalCopyRaw
        book.shelfLocation = metadata.shelfLocation
    }

    private func makeBook(from snapshot: LibraryTimeMachineBookSnapshot) -> Book {
        let book = Book(
            uuid: snapshot.id,
            fileName: snapshot.fileName,
            originalFileName: snapshot.originalFileName,
            dateAdded: snapshot.dateAdded
        )
        book.fileSizeBytes = snapshot.fileSizeBytes
        book.coverVersion = snapshot.coverVersion
        book.coverScopeRaw = snapshot.coverScopeRaw
        book.coverAssetUUID = snapshot.coverAssetUUID
        return book
    }

    private func replaceReadingSessions(
        on book: Book,
        with snapshots: [LibraryTimeMachineReadingSessionSnapshot]
    ) {
        let existing = book.readingSessions
        book.readingSessions.removeAll()
        existing.forEach(modelContext.delete)
        for snapshot in snapshots {
            let session = ReadingSession(
                uuid: snapshot.id,
                startedAt: snapshot.startedAt,
                endedAt: snapshot.endedAt,
                status: ReadingSessionStatus(rawValue: snapshot.statusRaw) ?? .reading,
                progress: snapshot.progress,
                book: book
            )
            session.statusRaw = snapshot.statusRaw
            modelContext.insert(session)
        }
    }

    private func replaceHighlights(
        on book: Book,
        with snapshots: [LibraryTimeMachineHighlightSnapshot]
    ) {
        let existing = book.highlights
        book.highlights.removeAll()
        existing.forEach(modelContext.delete)
        for snapshot in snapshots {
            let highlight = Highlight(
                text: snapshot.text,
                isNote: snapshot.kindRaw == "note",
                location: snapshot.location,
                addedDate: snapshot.addedDate
            )
            highlight.kindRaw = snapshot.kindRaw
            highlight.dateImported = snapshot.dateImported
            highlight.book = book
            modelContext.insert(highlight)
        }
    }

    private func restoreCollectionMemberships(
        on book: Book,
        from snapshots: [LibraryTimeMachineCollectionSnapshot]
    ) throws -> Int {
        let collections = try modelContext.fetch(FetchDescriptor<BookCollection>())
        let byID = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byName = Dictionary(
            collections.map { ($0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var restored: [BookCollection] = []
        var skipped = 0
        for snapshot in snapshots {
            let nameKey = snapshot.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if let collection = byID[snapshot.id] ?? byName[nameKey] {
                restored.append(collection)
            } else {
                skipped += 1
            }
        }
        book.collections = restored
        return skipped
    }

    private func restoreAssets(
        on book: Book,
        from snapshots: [LibraryTimeMachineAssetSnapshot],
        primaryAssetID: UUID?
    ) {
        for snapshot in snapshots {
            let asset = BookAsset(
                uuid: snapshot.id,
                fileName: snapshot.fileName,
                origin: snapshot.originRaw.flatMap(AssetOrigin.init(rawValue:)) ?? .original,
                format: snapshot.formatRaw,
                sourceProvenance: snapshot.sourceProvenanceRaw
                    .flatMap(AssetSourceProvenance.init(rawValue:))
                    ?? .backupRestore,
                sourceIdentifier: snapshot.sourceIdentifier,
                contentHash: snapshot.contentHash,
                generatedFromContentHash: snapshot.generatedFromContentHash,
                sizeBytes: snapshot.sizeBytes,
                drmProtected: snapshot.drmProtected,
                dateAdded: snapshot.dateAdded,
                validationStatus: snapshot.validationStatusRaw.flatMap(AssetValidation.init(rawValue:)),
                availability: snapshot.availabilityRaw.flatMap(AssetAvailability.init(rawValue:)),
                coverVersion: snapshot.coverVersionRaw ?? 0,
                book: book
            )
            asset.formatRaw = snapshot.formatRaw
            asset.originRaw = snapshot.originRaw
            asset.sourceProvenanceRaw = snapshot.sourceProvenanceRaw
                ?? AssetSourceProvenance.backupRestore.rawValue
            asset.validationStatusRaw = snapshot.validationStatusRaw
            asset.availabilityRaw = snapshot.availabilityRaw
            asset.coverVersionRaw = snapshot.coverVersionRaw
            modelContext.insert(asset)
        }
        book.primaryAssetUUID = primaryAssetID.flatMap { requestedID in
            snapshots.contains(where: { $0.id == requestedID }) ? requestedID : nil
        } ?? snapshots.first(where: { $0.id == book.uuid })?.id
            ?? snapshots.first(where: { $0.fileName == book.fileName })?.id
    }

    private func restoreWork(
        on book: Book,
        from snapshot: LibraryTimeMachineWorkSnapshot?
    ) throws -> Work? {
        guard let snapshot else { return nil }
        let works = try modelContext.fetch(FetchDescriptor<Work>())
        if let existing = works.first(where: { $0.uuid == snapshot.id }) {
            book.work = existing
            if let preferred = existing.preferredEditionUUID,
               preferred != book.uuid,
               !existing.editions.contains(where: { $0.uuid == preferred }) {
                existing.preferredEditionUUID = book.uuid
            } else if existing.preferredEditionUUID == nil {
                existing.preferredEditionUUID = book.uuid
            }
            return nil
        }
        let work = Work(
            uuid: snapshot.id,
            title: snapshot.title,
            author: snapshot.author,
            dateCreated: snapshot.dateCreated
        )
        work.originalTitle = snapshot.originalTitle
        work.originalLanguage = snapshot.originalLanguage
        work.openLibraryWorkKey = snapshot.openLibraryWorkKey
        work.hardcoverBookID = snapshot.hardcoverBookID
        work.preferredEditionUUID = snapshot.preferredEditionUUID
        work.coverVersionRaw = snapshot.coverVersionRaw
        work.notes = snapshot.notes
        work.preferredEditionUUID = book.uuid
        modelContext.insert(work)
        book.work = work
        return work
    }

    private func discardInsertedBook(
        _ book: Book,
        insertedWork: Work?
    ) {
        book.collections.removeAll()
        for highlight in book.highlights {
            highlight.book = nil
            if highlight.modelContext != nil { modelContext.delete(highlight) }
        }
        book.highlights.removeAll()
        for session in book.readingSessions {
            session.book = nil
            if session.modelContext != nil { modelContext.delete(session) }
        }
        book.readingSessions.removeAll()
        for asset in book.assets {
            asset.book = nil
            if asset.modelContext != nil { modelContext.delete(asset) }
        }
        book.assets.removeAll()
        book.work = nil
        if book.modelContext != nil { modelContext.delete(book) }
        if let insertedWork, insertedWork.modelContext != nil {
            modelContext.delete(insertedWork)
        }
    }

}
