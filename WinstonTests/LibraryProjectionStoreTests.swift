import Foundation
import SwiftData
import Testing
@testable import Winston

@Suite("Library projection store", .serialized)
@MainActor
struct LibraryProjectionStoreTests {
    private struct InjectedFetchFailure: Error, LocalizedError {
        var errorDescription: String? { "Injected projection fetch failure." }
    }

    private final class FetchScript {
        var calls = 0
        var failingCalls: Set<Int>

        init(failingCalls: Set<Int>) {
            self.failingCalls = failingCalls
        }

        func fetch(
            context: ModelContext,
            descriptor: FetchDescriptor<Book>
        ) throws -> [Book] {
            calls += 1
            if failingCalls.contains(calls) {
                throw InjectedFetchFailure()
            }
            return try context.fetch(descriptor)
        }
    }

    @MainActor
    private final class RetryGate: @unchecked Sendable {
        private(set) var entered = false
        private var continuation: CheckedContinuation<Void, any Error>?

        func sleep(_: Duration) async throws {
            entered = true
            try await withCheckedThrowingContinuation {
                continuation = $0
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test func semanticChangesFetchOnlyAffectedBooksAfterBootstrap() async throws {
        let library = try await TestLibrary()
        var target: Book?
        for index in 0..<128 {
            let book = Book(
                fileName: "projection-\(index).epub",
                originalFileName: "projection-\(index).epub",
                dateAdded: Date(timeIntervalSince1970: TimeInterval(index))
            )
            book.title = "Projection \(index)"
            library.context.insert(book)
            if index == 42 { target = book }
        }
        try library.context.save()

        let projected = LibraryProjectionStore()
        try projected.synchronize(
            context: library.context,
            delta: fullDelta(from: -1, to: 0)
        )
        #expect(projected.books.count == 128)
        #expect(projected.fullRebuildCount == 1)
        #expect(projected.lastBookFetchCount == 128)
        #expect(projected.lastQueryCount == 2)

        let targetBook = try #require(target)
        targetBook.title = "Changed projection"
        try library.context.save()
        try projected.synchronize(
            context: library.context,
            delta: LibraryCatalogDelta(
                fromRevision: 0,
                toRevision: 1,
                affectedBookIDs: [targetBook.uuid],
                affectedCollectionIDs: [],
                fields: [.identity, .displayMetadata],
                requiresFullRebuild: false,
                changesBookMembership: false
            )
        )

        #expect(projected.fullRebuildCount == 1)
        #expect(projected.lastQueryCount == 1)
        #expect(projected.lastBookFetchCount == 1)
        #expect(projected.books.first(where: { $0.uuid == targetBook.uuid })?.title
            == "Changed projection")

        let targetID = targetBook.uuid
        library.context.delete(targetBook)
        try library.context.save()
        try projected.synchronize(
            context: library.context,
            delta: LibraryCatalogDelta(
                fromRevision: 1,
                toRevision: 2,
                affectedBookIDs: [targetID],
                affectedCollectionIDs: [],
                fields: .all,
                requiresFullRebuild: false,
                changesBookMembership: true
            )
        )

        #expect(projected.books.count == 127)
        #expect(projected.fullRebuildCount == 1)
        #expect(projected.lastQueryCount == 1)
        #expect(projected.lastBookFetchCount == 0)
    }

    @Test func transientInitialFailureRetriesAtTheSameRevision() async throws {
        let library = try await TestLibrary()
        library.context.insert(Book(
            fileName: "retry.epub",
            originalFileName: "retry.epub"
        ))
        try library.context.save()
        let fetches = FetchScript(failingCalls: [1])
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let projected = LibraryProjectionStore(
            fetchBooks: fetches.fetch,
            now: { fixedNow }
        )
        let token = projected.beginSynchronization()

        let succeeded = await projected.synchronizeWithRetry(
            context: library.context,
            delta: { fullDelta(from: -1, to: 0) },
            token: token,
            sleeper: { _ in }
        )

        #expect(succeeded)
        #expect(fetches.calls == 2)
        #expect(projected.books.count == 1)
        #expect(projected.status == .ready(
            generation: 0,
            lastSuccessAt: fixedNow
        ))
    }

    @Test func persistentFailureIsBoundedAndManualRetryNeedsNoMutation() async throws {
        let library = try await TestLibrary()
        let fetches = FetchScript(failingCalls: [1, 2, 3])
        let projected = LibraryProjectionStore(fetchBooks: fetches.fetch)
        let firstToken = projected.beginSynchronization()

        let firstSucceeded = await projected.synchronizeWithRetry(
            context: library.context,
            delta: { fullDelta(from: -1, to: 0) },
            token: firstToken,
            sleeper: { _ in }
        )

        #expect(!firstSucceeded)
        #expect(fetches.calls == 3)
        #expect(projected.synchronizationAttemptCount == 3)
        if case .failed(let failure) = projected.status {
            #expect(failure.isRetryable)
        } else {
            Issue.record("initial persistent failure should be visible")
        }

        let previousRetryID = projected.retryRequestID
        projected.requestRetry()
        #expect(projected.retryRequestID == previousRetryID + 1)
        let retryToken = projected.beginSynchronization()
        let retrySucceeded = await projected.synchronizeWithRetry(
            context: library.context,
            delta: { fullDelta(from: -1, to: 0) },
            token: retryToken,
            sleeper: { _ in }
        )

        #expect(retrySucceeded)
        #expect(fetches.calls == 4)
        #expect(projected.generation == 0)
    }

    @Test func failureAfterReadinessKeepsLastKnownRowsAndMarksThemStale() async throws {
        let library = try await TestLibrary()
        let book = Book(fileName: "known.epub", originalFileName: "known.epub")
        library.context.insert(book)
        try library.context.save()
        let fetches = FetchScript(failingCalls: [2, 3, 4])
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let projected = LibraryProjectionStore(
            fetchBooks: fetches.fetch,
            now: { fixedNow }
        )
        try projected.synchronize(
            context: library.context,
            delta: fullDelta(from: -1, to: 0)
        )
        let token = projected.beginSynchronization()

        let succeeded = await projected.synchronizeWithRetry(
            context: library.context,
            delta: { fullDelta(from: 0, to: 1) },
            token: token,
            sleeper: { _ in }
        )

        #expect(!succeeded)
        #expect(projected.books.map(\.uuid) == [book.uuid])
        #expect(projected.generation == 0)
        if case .stale(let generation, let lastSuccessAt, let failure)
            = projected.status {
            #expect(generation == 0)
            #expect(lastSuccessAt == fixedNow)
            #expect(failure.isRetryable)
        } else {
            Issue.record("post-ready failure should preserve a stale projection")
        }
    }

    @Test func newerRevisionInvalidatesAnOlderRetryDelay() async throws {
        let library = try await TestLibrary()
        let fetches = FetchScript(failingCalls: [1])
        let projected = LibraryProjectionStore(fetchBooks: fetches.fetch)
        let gate = RetryGate()
        let oldToken = projected.beginSynchronization()
        let oldTask = Task {
            await projected.synchronizeWithRetry(
                context: library.context,
                delta: { fullDelta(from: -1, to: 0) },
                token: oldToken,
                sleeper: { duration in
                    try await gate.sleep(duration)
                }
            )
        }
        while !gate.entered {
            await Task.yield()
        }

        oldTask.cancel()
        let newToken = projected.beginSynchronization()
        let newSucceeded = await projected.synchronizeWithRetry(
            context: library.context,
            delta: { fullDelta(from: -1, to: 1) },
            token: newToken,
            sleeper: { _ in }
        )
        gate.release()
        let oldSucceeded = await oldTask.value

        #expect(newSucceeded)
        #expect(!oldSucceeded)
        #expect(projected.generation == 1)
        #expect(fetches.calls == 2)
    }

    @Test func staleTokenCannotOverwriteANewerProjection() async throws {
        let library = try await TestLibrary()
        let fetches = FetchScript(failingCalls: [])
        let projected = LibraryProjectionStore(fetchBooks: fetches.fetch)
        let staleToken = projected.beginSynchronization()
        let currentToken = projected.beginSynchronization()

        #expect(await projected.synchronizeWithRetry(
            context: library.context,
            delta: { fullDelta(from: -1, to: 2) },
            token: currentToken,
            sleeper: { _ in }
        ))
        let callCountAfterCurrentRevision = fetches.calls
        #expect(!(await projected.synchronizeWithRetry(
            context: library.context,
            delta: { fullDelta(from: -1, to: 1) },
            token: staleToken,
            sleeper: { _ in }
        )))

        #expect(projected.generation == 2)
        #expect(fetches.calls == callCountAfterCurrentRevision)
    }

    @Test func terminalRecoveryFailureDoesNotRetryOrOfferRetry() async throws {
        let library = try await TestLibrary()
        let fetches = FetchScript(failingCalls: [1, 2, 3])
        var sleepCount = 0
        let projected = LibraryProjectionStore(
            fetchBooks: fetches.fetch,
            failureIsRetryable: { _ in false }
        )
        let token = projected.beginSynchronization()

        let succeeded = await projected.synchronizeWithRetry(
            context: library.context,
            delta: { fullDelta(from: -1, to: 0) },
            token: token,
            sleeper: { _ in sleepCount += 1 }
        )

        #expect(!succeeded)
        #expect(fetches.calls == 1)
        #expect(sleepCount == 0)
        #expect(projected.status.failure?.isRetryable == false)
        let retryID = projected.retryRequestID
        projected.requestRetry()
        #expect(projected.retryRequestID == retryID)
    }

    private func fullDelta(from: Int, to: Int) -> LibraryCatalogDelta {
        LibraryCatalogDelta(
            fromRevision: from,
            toRevision: to,
            affectedBookIDs: [],
            affectedCollectionIDs: [],
            fields: .all,
            requiresFullRebuild: true,
            changesBookMembership: true
        )
    }
}
