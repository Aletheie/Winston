import Foundation
import OSLog
import SwiftData

enum ReadingHistoryBackfill {
    private struct SessionSeed {
        let bookID: UUID
        let startedAt: Date
        let endedAt: Date?
        let status: ReadingSessionStatus
        let progress: Double
    }

    @discardableResult
    static func run(
        context: ModelContext,
        mutations: CatalogMutationService? = nil
    ) throws -> Int {
        context.processPendingChanges()
        guard !context.hasChanges else {
            Log.persistence.error("Reading-history backfill refused a dirty catalog context")
            throw CatalogMutationError.invalidRequest
        }

        var descriptor = FetchDescriptor<Book>()
        descriptor.relationshipKeyPathsForPrefetching = [\.readingSessions]
        let seeds = try context.fetch(descriptor).compactMap {
            book -> SessionSeed? in
            guard book.readingSessions.isEmpty else { return nil }
            let status = book.readingStatus
            let startedAt = book.dateStarted ?? book.dateFinished ?? book.dateAdded
            let sessionStatus: ReadingSessionStatus
            let endedAt: Date?
            let progress: Double

            switch status {
            case .unread:
                return nil
            case .reading:
                sessionStatus = .reading
                endedAt = nil
                progress = 0
            case .paused:
                sessionStatus = .paused
                endedAt = nil
                progress = 0
            case .finished:
                sessionStatus = .finished
                endedAt = book.dateFinished ?? startedAt
                progress = 1
            case .didNotFinish:
                sessionStatus = .didNotFinish
                endedAt = book.dateFinished ?? startedAt
                progress = 0
            }

            return SessionSeed(
                bookID: book.uuid,
                startedAt: startedAt,
                endedAt: endedAt,
                status: sessionStatus,
                progress: progress
            )
        }

        var inserted = 0
        let affectedBookIDs = Set(seeds.map(\.bookID))
        if !seeds.isEmpty {
            let writer = mutations ?? CatalogMutationService(modelContext: context)
            do {
                try writer.commitPrepared(
                    .updateMetadataBatch(
                        bookIDs: Array(affectedBookIDs),
                        operation: "readingHistoryBackfill",
                        fields: ["readingStatus", "readingProgress"]
                    ),
                    affectedBookIDs: affectedBookIDs
                ) { writeContext in
                    for seed in seeds {
                        let bookID = seed.bookID
                        let matches = try writeContext.fetch(FetchDescriptor<Book>(
                            predicate: #Predicate { $0.uuid == bookID }
                        ))
                        guard let book = matches.first,
                              book.readingSessions.isEmpty else {
                            continue
                        }
                        let session = ReadingSession(
                            startedAt: seed.startedAt,
                            endedAt: seed.endedAt,
                            status: seed.status,
                            progress: seed.progress,
                            book: book
                        )
                        writeContext.insert(session)
                        inserted += 1
                    }
                }
            } catch {
                throw error
            }
        }
        return inserted
    }
}
