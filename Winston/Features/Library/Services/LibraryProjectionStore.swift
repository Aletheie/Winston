import Foundation
import Observation
import OSLog
import SwiftData

enum LibraryProjectionStoreError: Error, LocalizedError {
    case missingChangedBook(UUID)

    var errorDescription: String? {
        switch self {
        case .missingChangedBook(let id):
            "A changed catalog book could not be projected (\(id.uuidString))."
        }
    }
}

/// Main-actor bridge from SwiftData into the value-oriented library read model.
///
/// Unlike a root `@Query`, this store controls when a full fetch is permitted
/// and applies ordinary semantic changes with ID-bounded fetches.
@MainActor
@Observable
final class LibraryProjectionStore {
    private(set) var books: [Book] = []
    private(set) var collections: [BookCollection] = []
    private(set) var generation = -1
    private(set) var lastError: String?

    @ObservationIgnored private(set) var fullRebuildCount = 0
    @ObservationIgnored private(set) var lastBookFetchCount = 0
    @ObservationIgnored private(set) var lastCollectionFetchCount = 0
    @ObservationIgnored private(set) var lastQueryCount = 0

    var isReady: Bool { generation >= 0 }

    func synchronize(
        context: ModelContext,
        delta: LibraryCatalogDelta
    ) throws {
        lastBookFetchCount = 0
        lastCollectionFetchCount = 0
        lastQueryCount = 0
        do {
            if generation < 0
                || delta.requiresFullRebuild
                || delta.fromRevision != generation {
                try rebuild(context: context, generation: delta.toRevision)
                return
            }
            guard delta.toRevision != generation else {
                lastError = nil
                return
            }

            if !delta.affectedBookIDs.isEmpty {
                try applyBooks(
                    ids: delta.affectedBookIDs,
                    changesMembership: delta.changesBookMembership,
                    context: context
                )
            } else if delta.changesBookMembership {
                // A membership change without IDs is not safe to interpret as
                // an empty change set.
                try rebuild(context: context, generation: delta.toRevision)
                return
            }

            if !delta.affectedCollectionIDs.isEmpty {
                try reloadCollections(context: context)
            }
            generation = delta.toRevision
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.persistence.error(
                "Library projection synchronization failed at revision \(delta.toRevision): \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    private func rebuild(context: ModelContext, generation: Int) throws {
        let signposter = Log.librarySignposter
        let interval = signposter.beginInterval(
            "LibraryProjectionRebuild",
            id: signposter.makeSignpostID()
        )
        LibraryPerformanceDiagnostics.beginSQLScope("library_projection_rebuild")
        defer {
            LibraryPerformanceDiagnostics.endSQLScope("library_projection_rebuild")
            signposter.endInterval("LibraryProjectionRebuild", interval)
        }

        var bookDescriptor = FetchDescriptor<Book>(
            sortBy: [
                SortDescriptor(\Book.dateAdded, order: .reverse),
                SortDescriptor(\Book.uuid),
            ]
        )
        bookDescriptor.relationshipKeyPathsForPrefetching = [
            \Book.assets,
            \Book.collections,
            \Book.highlights,
            \Book.work,
        ]
        let fetchedBooks = try context.fetch(bookDescriptor)
        let fetchedCollections = try context.fetch(FetchDescriptor<BookCollection>(
            sortBy: [SortDescriptor(\BookCollection.name)]
        ))

        books = fetchedBooks
        collections = fetchedCollections
        self.generation = generation
        fullRebuildCount += 1
        lastBookFetchCount = fetchedBooks.count
        lastCollectionFetchCount = fetchedCollections.count
        lastQueryCount = 2
        lastError = nil
    }

    private func applyBooks(
        ids: Set<UUID>,
        changesMembership: Bool,
        context: ModelContext
    ) throws {
        let requestedIDs = Array(ids)
        var descriptor = FetchDescriptor<Book>(
            predicate: #Predicate {
                requestedIDs.contains($0.uuid)
            }
        )
        descriptor.relationshipKeyPathsForPrefetching = [
            \Book.assets,
            \Book.collections,
            \Book.highlights,
            \Book.work,
        ]
        let changedBooks = try context.fetch(descriptor)
        lastBookFetchCount = changedBooks.count
        lastQueryCount += 1
        let changedByID = Dictionary(
            uniqueKeysWithValues: changedBooks.map { ($0.uuid, $0) }
        )

        if changesMembership {
            var projectedByID = Dictionary(
                uniqueKeysWithValues: books.map { ($0.uuid, $0) }
            )
            for id in ids {
                projectedByID[id] = changedByID[id]
            }
            books = projectedByID.values.sorted(by: Self.sourcePrecedes)
            return
        }

        let existingIDs = Set(books.map(\.uuid))
        for id in ids where changedByID[id] == nil && existingIDs.contains(id) {
            throw LibraryProjectionStoreError.missingChangedBook(id)
        }
        guard !changedBooks.isEmpty else { return }
        books = books.map { changedByID[$0.uuid] ?? $0 }
    }

    private func reloadCollections(context: ModelContext) throws {
        let fetched = try context.fetch(FetchDescriptor<BookCollection>(
            sortBy: [SortDescriptor(\BookCollection.name)]
        ))
        collections = fetched
        lastCollectionFetchCount = fetched.count
        lastQueryCount += 1
    }

    private static func sourcePrecedes(_ lhs: Book, _ rhs: Book) -> Bool {
        if lhs.dateAdded != rhs.dateAdded {
            return lhs.dateAdded > rhs.dateAdded
        }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }
}
