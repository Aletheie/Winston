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
    case updateMetadataBatch(bookIDs: [UUID], operation: String)
    case assignEdition(bookIDs: [UUID], workID: UUID?)
    case updateWork(workID: UUID)
    case pluginUpdate(bookID: UUID, fields: Set<String>)
    case importBooks(bookIDs: [UUID])
    case calibreImport(bookIDs: [UUID])
    case addFile(bookID: UUID, assetID: UUID)
    case replaceFile(bookID: UUID, assetID: UUID)
    case removeFile(bookID: UUID, assetID: UUID)
    case removeBooks(bookIDs: [UUID])
    case conversionOutput(bookID: UUID, assetID: UUID)
    case legacyMigration(bookIDs: [UUID])
    case updateCover(bookID: UUID, version: Int)
}

struct CatalogChangeSet {
    let command: CatalogMutationCommand
    let affectedBookIDs: Set<UUID>
    let affectedWorkIDs: Set<UUID>
    let affectedCollectionIDs: Set<UUID>
}

enum CatalogMutationError: Error, Equatable {
    case dirtyContext
    case modelNotFound
    case saveFailed(String)
    case fileTransactionFailed(String)
}

struct CatalogFileCommitResult {
    let changeSet: CatalogChangeSet
    let pendingTransactionIDs: [UUID]

    var isFullyPublished: Bool { pendingTransactionIDs.isEmpty }
}

@MainActor
final class CatalogMutationService {
    private let modelContext: ModelContext
    private let saveAdapter: CatalogSaveAdapter
    private let managedFiles: ManagedFileCoordinator

    init(
        modelContext: ModelContext,
        saveAdapter: CatalogSaveAdapter = .live,
        managedFiles: ManagedFileCoordinator = .shared
    ) {
        self.modelContext = modelContext
        self.saveAdapter = saveAdapter
        self.managedFiles = managedFiles
    }

    @discardableResult
    func commit(
        _ command: CatalogMutationCommand,
        affectedBookIDs: Set<UUID> = [],
        affectedWorkIDs: Set<UUID> = [],
        affectedCollectionIDs: Set<UUID> = [],
        catalogChanged: Bool = true,
        applying mutation: () throws -> Void
    ) throws -> CatalogChangeSet {
        guard !modelContext.hasChanges else {
            modelContext.rollback()
            Log.persistence.error("Catalog mutation refused a dirty context and rolled it back")
            throw CatalogMutationError.dirtyContext
        }

        do {
            try mutation()
            try saveAdapter.save(modelContext)
            LibraryMutationLog.shared.bump(catalogChanged: catalogChanged)
            return CatalogChangeSet(
                command: command,
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs,
                affectedCollectionIDs: affectedCollectionIDs
            )
        } catch let error as CatalogMutationError {
            modelContext.rollback()
            Log.persistence.error("Catalog mutation rolled back: \(String(describing: error), privacy: .public)")
            throw error
        } catch {
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
            try saveAdapter.save(modelContext)
            LibraryMutationLog.shared.bump(catalogChanged: catalogChanged)
            return CatalogChangeSet(
                command: command,
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs,
                affectedCollectionIDs: affectedCollectionIDs
            )
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
        revertingOnFailure rollbackMutation: () -> Void = {},
        applying mutation: () throws -> Void
    ) async throws -> CatalogFileCommitResult {
        guard !modelContext.hasChanges else {
            modelContext.rollback()
            await managedFiles.abort(transaction)
            Log.persistence.error("Managed catalog mutation refused a dirty context and rolled it back")
            throw CatalogMutationError.dirtyContext
        }

        var mutationStarted = false
        do {
            try await managedFiles.willCommitCatalog(transaction)
            mutationStarted = true
            try mutation()
            try saveAdapter.save(modelContext)
        } catch let error as CatalogMutationError {
            if mutationStarted { rollbackMutation() }
            modelContext.rollback()
            await managedFiles.abort(transaction)
            throw error
        } catch {
            if mutationStarted { rollbackMutation() }
            modelContext.rollback()
            await managedFiles.abort(transaction)
            Log.persistence.error(
                "Managed catalog mutation failed before commit and rolled back: \(error.localizedDescription, privacy: .public)"
            )
            throw CatalogMutationError.saveFailed(error.localizedDescription)
        }

        LibraryMutationLog.shared.bump(catalogChanged: catalogChanged)
        let changeSet = CatalogChangeSet(
            command: command,
            affectedBookIDs: affectedBookIDs,
            affectedWorkIDs: affectedWorkIDs,
            affectedCollectionIDs: affectedCollectionIDs
        )
        let pending = await finalizeCommittedTransactions([transaction])
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
            try saveAdapter.save(modelContext)
        } catch {
            rollbackMutation()
            modelContext.rollback()
            for transaction in transactions {
                await managedFiles.abort(transaction)
            }
            Log.persistence.error(
                "Staged managed catalog mutation failed before commit and rolled back: \(error.localizedDescription, privacy: .public)"
            )
            throw CatalogMutationError.saveFailed(error.localizedDescription)
        }

        LibraryMutationLog.shared.bump(catalogChanged: catalogChanged)
        let changeSet = CatalogChangeSet(
            command: command,
            affectedBookIDs: affectedBookIDs,
            affectedWorkIDs: affectedWorkIDs,
            affectedCollectionIDs: affectedCollectionIDs
        )
        let pending = await finalizeCommittedTransactions(transactions)
        return CatalogFileCommitResult(changeSet: changeSet, pendingTransactionIDs: pending)
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
        _ transactions: [ManagedFileTransaction]
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
                let outcome = try await managedFiles.reconcile(transaction, against: snapshot)
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
        let books = try modelContext.fetch(FetchDescriptor<Book>())
            .filter { ids.contains($0.uuid) }
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
        let works = try modelContext.fetch(FetchDescriptor<Work>())
            .filter { ids.contains($0.uuid) }
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
