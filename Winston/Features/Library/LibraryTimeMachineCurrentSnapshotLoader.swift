import Foundation
import SwiftData

nonisolated struct LibraryTimeMachineSnapshotLoadProgress: Equatable, Sendable {
    let completedCount: Int
    let totalCount: Int

    var fractionCompleted: Double {
        guard totalCount > 0 else { return 1 }
        return min(1, max(0, Double(completedCount) / Double(totalCount)))
    }
}

nonisolated enum LibraryTimeMachineSnapshotLoadPurpose: Equatable, Sendable {
    case opening
    case refreshing
}

@MainActor
final class LibraryTimeMachineReloadCoalescer {
    private var task: Task<Void, Never>?

    func schedule(
        delay: Duration = .milliseconds(180),
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        task?.cancel()
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

@MainActor
struct LibraryTimeMachineCurrentSnapshotLoader {
    typealias ProgressReporter = @MainActor @Sendable (
        LibraryTimeMachineSnapshotLoadProgress
    ) -> Void

    let modelContext: ModelContext
    let pageSize: Int
    let coversDirectory: URL
    let booksDirectory: URL
    private let beforePage: @MainActor @Sendable (Int) async throws -> Void

    init(
        modelContext: ModelContext,
        pageSize: Int = 128,
        coversDirectory: URL = AppPaths.coversDirectory,
        booksDirectory: URL = AppPaths.booksDirectory,
        beforePage: @escaping @MainActor @Sendable (Int) async throws -> Void = { _ in }
    ) {
        self.modelContext = modelContext
        self.pageSize = max(1, pageSize)
        self.coversDirectory = coversDirectory
        self.booksDirectory = booksDirectory
        self.beforePage = beforePage
    }

    func load(
        onProgress: @escaping ProgressReporter = { _ in }
    ) async throws -> [LibraryTimeMachineBookSnapshot] {
        try Task.checkCancellation()
        let totalCount = try modelContext.fetchCount(FetchDescriptor<Book>())
        onProgress(LibraryTimeMachineSnapshotLoadProgress(
            completedCount: 0,
            totalCount: totalCount
        ))
        guard totalCount > 0 else { return [] }

        var snapshots: [LibraryTimeMachineBookSnapshot] = []
        snapshots.reserveCapacity(totalCount)
        var offset = 0
        var pageIndex = 0
        while offset < totalCount {
            try Task.checkCancellation()
            try await beforePage(pageIndex)
            try Task.checkCancellation()

            var descriptor = FetchDescriptor<Book>(sortBy: [
                SortDescriptor(\Book.dateAdded, order: .forward),
                SortDescriptor(\Book.uuid, order: .forward),
            ])
            descriptor.fetchLimit = min(pageSize, totalCount - offset)
            descriptor.fetchOffset = offset
            descriptor.relationshipKeyPathsForPrefetching = [
                \Book.readingSessions,
                \Book.highlights,
                \Book.collections,
                \Book.assets,
                \Book.work,
            ]
            let books = try modelContext.fetch(descriptor)
            guard !books.isEmpty else { break }

            let pageSnapshots = await LibraryTimeMachineDiffBuilder.snapshotCurrentBooks(
                books,
                currentCoversDirectory: coversDirectory,
                currentBooksDirectory: booksDirectory
            )
            try Task.checkCancellation()
            guard pageSnapshots.count == books.count else {
                throw CancellationError()
            }
            snapshots.append(contentsOf: pageSnapshots)
            offset += books.count
            pageIndex += 1
            onProgress(LibraryTimeMachineSnapshotLoadProgress(
                completedCount: min(offset, totalCount),
                totalCount: totalCount
            ))
            await Task.yield()
        }
        try Task.checkCancellation()
        return snapshots
    }
}
