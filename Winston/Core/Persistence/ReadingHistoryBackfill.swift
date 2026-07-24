import Foundation
import SwiftData

enum ReadingHistoryBackfill {
    @discardableResult
    static func run(context: ModelContext) -> Int {
        var inserted = 0
        var affectedBookIDs: Set<UUID> = []
        var descriptor = FetchDescriptor<Book>()
        descriptor.relationshipKeyPathsForPrefetching = [\.readingSessions]

        for book in ((try? context.fetch(descriptor)) ?? []) where book.readingSessions.isEmpty {
            let status = book.readingStatus
            let startedAt = book.dateStarted ?? book.dateFinished ?? book.dateAdded
            let sessionStatus: ReadingSessionStatus
            let endedAt: Date?
            let progress: Double

            switch status {
            case .unread:
                continue
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

            let session = ReadingSession(
                startedAt: startedAt,
                endedAt: endedAt,
                status: sessionStatus,
                progress: progress,
                book: book
            )
            context.insert(session)
            inserted += 1
            affectedBookIDs.insert(book.uuid)
        }

        if inserted > 0 {
            context.saveQuietly(
                affectedBookIDs: affectedBookIDs,
                fields: [.readingState]
            )
        }
        return inserted
    }
}
