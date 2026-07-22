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
    case calibreImport(bookIDs: [UUID])
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
}

@MainActor
final class CatalogMutationService {
    private let modelContext: ModelContext
    private let saveAdapter: CatalogSaveAdapter

    init(
        modelContext: ModelContext,
        saveAdapter: CatalogSaveAdapter = .live
    ) {
        self.modelContext = modelContext
        self.saveAdapter = saveAdapter
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
