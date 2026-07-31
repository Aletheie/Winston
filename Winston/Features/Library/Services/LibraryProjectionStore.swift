import Foundation
import Observation
import OSLog
import SwiftData

enum LibraryProjectionStoreError: Error, LocalizedError {
    case missingChangedBook(UUID)

    var errorDescription: String? {
        switch self {
        case .missingChangedBook(let id):
            String(
                localized: "A changed catalog book could not be projected (\(id.uuidString))."
            )
        }
    }
}

nonisolated struct LibraryProjectionFailure: Equatable, Sendable {
    let message: String
    let isRetryable: Bool
}

nonisolated enum LibraryProjectionStatus: Equatable, Sendable {
    case loading(attempt: Int)
    case ready(generation: Int, lastSuccessAt: Date)
    case stale(
        generation: Int,
        lastSuccessAt: Date,
        failure: LibraryProjectionFailure
    )
    case failed(failure: LibraryProjectionFailure)

    var failure: LibraryProjectionFailure? {
        switch self {
        case .stale(_, _, let failure), .failed(let failure):
            failure
        case .loading, .ready:
            nil
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
    typealias BookFetcher = (
        _ context: ModelContext,
        _ descriptor: FetchDescriptor<Book>
    ) throws -> [Book]
    typealias CollectionFetcher = (
        _ context: ModelContext,
        _ descriptor: FetchDescriptor<BookCollection>
    ) throws -> [BookCollection]
    typealias RetrySleeper = @MainActor (Duration) async throws -> Void

    private(set) var books: [Book] = []
    private(set) var collections: [BookCollection] = []
    private(set) var generation = -1
    private(set) var status: LibraryProjectionStatus = .loading(attempt: 0)
    private(set) var retryRequestID = 0

    @ObservationIgnored private(set) var fullRebuildCount = 0
    @ObservationIgnored private(set) var lastBookFetchCount = 0
    @ObservationIgnored private(set) var lastCollectionFetchCount = 0
    @ObservationIgnored private(set) var lastQueryCount = 0
    @ObservationIgnored private(set) var synchronizationAttemptCount = 0
    @ObservationIgnored private let fetchBooks: BookFetcher
    @ObservationIgnored private let fetchCollections: CollectionFetcher
    @ObservationIgnored private let failureIsRetryable: (any Error) -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var synchronizationToken = 0
    @ObservationIgnored private var lastSuccessAt: Date?

    var isReady: Bool { generation >= 0 }
    var lastError: String? { status.failure?.message }

    init(
        fetchBooks: @escaping BookFetcher = { context, descriptor in
            try context.fetch(descriptor)
        },
        fetchCollections: @escaping CollectionFetcher = { context, descriptor in
            try context.fetch(descriptor)
        },
        failureIsRetryable: @escaping (any Error) -> Bool = { _ in
            switch PersistenceController.lastRecovery {
            case .migrationRequired, .readOnlyRecovery:
                false
            case .retryableFailure, .quarantined, nil:
                true
            }
        },
        now: @escaping () -> Date = { .now }
    ) {
        self.fetchBooks = fetchBooks
        self.fetchCollections = fetchCollections
        self.failureIsRetryable = failureIsRetryable
        self.now = now
    }

    func requestRetry() {
        guard status.failure?.isRetryable == true else { return }
        retryRequestID &+= 1
    }

    /// Invalidates every older synchronization task. SwiftUI's `.task(id:)`
    /// supplies cancellation; this token is the publication guard for delayed
    /// work that does not observe cancellation promptly.
    func beginSynchronization() -> Int {
        synchronizationToken &+= 1
        return synchronizationToken
    }

    func synchronizationIsCurrent(_ token: Int) -> Bool {
        token == synchronizationToken
    }

    func synchronize(
        context: ModelContext,
        delta: LibraryCatalogDelta
    ) throws {
        do {
            try performSynchronization(context: context, delta: delta)
            publishSuccess()
        } catch {
            publishFailure(error)
            logFailure(error, revision: delta.toRevision)
            throw error
        }
    }

    /// Attempts one revision at most three times. The caller owns the revision
    /// token, so a catalog/device revision change or manual retry can invalidate
    /// an older delay before it fetches or publishes.
    func synchronizeWithRetry(
        context: ModelContext,
        delta: () -> LibraryCatalogDelta,
        token: Int,
        maximumAttempts: Int = 3,
        sleeper: RetrySleeper = { duration in
            try await Task.sleep(for: duration)
        }
    ) async -> Bool {
        let attemptLimit = max(1, maximumAttempts)
        let delays: [Duration] = [.milliseconds(50), .milliseconds(150)]

        for attempt in 1 ... attemptLimit {
            guard !Task.isCancelled, synchronizationIsCurrent(token) else {
                return false
            }
            status = .loading(attempt: attempt)
            synchronizationAttemptCount += 1
            let currentDelta = delta()
            do {
                try performSynchronization(
                    context: context,
                    delta: currentDelta
                )
                guard !Task.isCancelled,
                      synchronizationIsCurrent(token) else {
                    return false
                }
                publishSuccess()
                return true
            } catch {
                guard !Task.isCancelled,
                      synchronizationIsCurrent(token) else {
                    return false
                }
                let failure = makeFailure(error)
                logFailure(error, revision: currentDelta.toRevision)
                guard failure.isRetryable, attempt < attemptLimit else {
                    publishFailure(failure)
                    return false
                }
                do {
                    try await sleeper(delays[min(attempt - 1, delays.count - 1)])
                } catch {
                    return false
                }
            }
        }
        return false
    }

    private func performSynchronization(
        context: ModelContext,
        delta: LibraryCatalogDelta
    ) throws {
        lastBookFetchCount = 0
        lastCollectionFetchCount = 0
        lastQueryCount = 0
        if generation < 0
            || delta.requiresFullRebuild
            || delta.fromRevision != generation {
            try rebuild(context: context, generation: delta.toRevision)
            return
        }
        guard delta.toRevision != generation else { return }

        if !delta.affectedBookIDs.isEmpty {
            try applyBooks(
                ids: delta.affectedBookIDs,
                changesMembership: delta.changesBookMembership,
                context: context
            )
        } else if delta.changesBookMembership {
            // A membership change without IDs is not safe to interpret as an
            // empty change set.
            try rebuild(context: context, generation: delta.toRevision)
            return
        }

        if !delta.affectedCollectionIDs.isEmpty {
            try reloadCollections(context: context)
        }
        generation = delta.toRevision
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
        let fetchedBooks = try fetchBooks(context, bookDescriptor)
        let fetchedCollections = try fetchCollections(context, FetchDescriptor<BookCollection>(
            sortBy: [SortDescriptor(\BookCollection.name)]
        ))

        books = fetchedBooks
        collections = fetchedCollections
        self.generation = generation
        fullRebuildCount += 1
        lastBookFetchCount = fetchedBooks.count
        lastCollectionFetchCount = fetchedCollections.count
        lastQueryCount = 2
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
        let changedBooks = try fetchBooks(context, descriptor)
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
        let fetched = try fetchCollections(context, FetchDescriptor<BookCollection>(
            sortBy: [SortDescriptor(\BookCollection.name)]
        ))
        collections = fetched
        lastCollectionFetchCount = fetched.count
        lastQueryCount += 1
    }

    private func publishSuccess() {
        let successAt = now()
        lastSuccessAt = successAt
        status = .ready(
            generation: generation,
            lastSuccessAt: successAt
        )
    }

    private func publishFailure(_ error: any Error) {
        publishFailure(makeFailure(error))
    }

    private func publishFailure(_ failure: LibraryProjectionFailure) {
        if let lastSuccessAt, generation >= 0 {
            status = .stale(
                generation: generation,
                lastSuccessAt: lastSuccessAt,
                failure: failure
            )
        } else {
            status = .failed(failure: failure)
        }
    }

    private func makeFailure(_ error: any Error) -> LibraryProjectionFailure {
        LibraryProjectionFailure(
            message: error.localizedDescription,
            isRetryable: failureIsRetryable(error)
        )
    }

    private func logFailure(_ error: any Error, revision: Int) {
        Log.persistence.error(
            "Library projection synchronization failed at revision \(revision): \(error.localizedDescription, privacy: .public)"
        )
    }

    private static func sourcePrecedes(_ lhs: Book, _ rhs: Book) -> Bool {
        if lhs.dateAdded != rhs.dateAdded {
            return lhs.dateAdded > rhs.dateAdded
        }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }
}
