import Foundation
import SwiftData
import Testing
@testable import Winston

@Suite("Reading history")
@MainActor
struct ReadingHistoryTests {
    private func date(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }

    @Test func rereadPreservesTheFirstFinishedCycle() throws {
        let book = Book(fileName: "book.epub", originalFileName: "Book.epub")
        let firstStart = date(100)
        let firstFinish = date(200)
        let secondStart = date(300)

        book.setStatus(.reading, at: firstStart)
        book.updateReadingProgress(0.45)
        book.setStatus(.finished, at: firstFinish)
        book.setStatus(.reading, at: secondStart)

        #expect(book.readingSessionsChronological.count == 2)
        let first = try #require(book.readingSessionsChronological.first)
        #expect(first.startedAt == firstStart)
        #expect(first.endedAt == firstFinish)
        #expect(first.status == .finished)
        #expect(first.progress == 1)

        let current = try #require(book.activeReadingSession)
        #expect(current.startedAt == secondStart)
        #expect(current.status == .reading)
        #expect(book.readingStatus == .reading)
        #expect(book.dateStarted == secondStart)
        #expect(book.dateFinished == nil)
    }

    @Test func pauseAndResumeKeepTheSameCycleAndProgress() throws {
        let book = Book(fileName: "book.epub", originalFileName: "Book.epub")
        book.setStatus(.reading, at: date(100))
        book.updateReadingProgress(0.3)
        let uuid = try #require(book.activeReadingSession?.uuid)

        book.setStatus(.paused, at: date(150))
        #expect(book.readingStatus == .paused)
        #expect(book.activeReadingSession?.status == .paused)
        #expect(book.activeReadingSession?.endedAt == nil)

        book.setStatus(.reading, at: date(200))
        #expect(book.activeReadingSession?.uuid == uuid)
        #expect(book.activeReadingSession?.progress == 0.3)
        #expect(book.readingSessions.count == 1)
    }

    @Test func dnfEndsTheCurrentCycleWithoutLosingProgress() throws {
        let book = Book(fileName: "book.epub", originalFileName: "Book.epub")
        book.setStatus(.reading, at: date(100))
        book.updateReadingProgress(0.62)
        book.setStatus(.didNotFinish, at: date(200))

        let cycle = try #require(book.readingSessions.first)
        #expect(cycle.status == .didNotFinish)
        #expect(cycle.endedAt == date(200))
        #expect(cycle.progress == 0.62)
        #expect(book.activeReadingSession == nil)
        #expect(book.readingStatus == .didNotFinish)
        #expect(book.dateFinished == nil)
    }

    @Test func progressIsClampedToAValidPercentage() {
        let book = Book(fileName: "book.epub", originalFileName: "Book.epub")
        book.setStatus(.reading)
        book.updateReadingProgress(1.5)
        #expect(book.activeReadingSession?.progress == 1)
        book.updateReadingProgress(-0.5)
        #expect(book.activeReadingSession?.progress == 0)
    }

    @Test func correctingATerminalStatusDoesNotCreateADuplicateCycle() throws {
        let book = Book(fileName: "book.epub", originalFileName: "Book.epub")
        book.setStatus(.reading, at: date(100))
        book.setStatus(.didNotFinish, at: date(200))
        let uuid = try #require(book.readingSessions.first?.uuid)

        book.setStatus(.finished, at: date(300))

        #expect(book.readingSessions.count == 1)
        #expect(book.readingSessions.first?.uuid == uuid)
        #expect(book.readingSessions.first?.status == .finished)
        #expect(book.readingSessions.first?.endedAt == date(200))
        #expect(book.readingSessions.first?.progress == 1)
    }

    @Test func markingUnreadClosesButPreservesTheActiveCycle() throws {
        let book = Book(fileName: "book.epub", originalFileName: "Book.epub")
        book.setStatus(.reading, at: date(100))
        book.updateReadingProgress(0.2)
        book.setStatus(.unread, at: date(200))

        let cycle = try #require(book.readingSessions.first)
        #expect(cycle.status == .didNotFinish)
        #expect(cycle.endedAt == date(200))
        #expect(cycle.progress == 0.2)
        #expect(book.readingStatus == .unread)
        #expect(book.dateStarted == nil)
        #expect(book.dateFinished == nil)
    }

    @Test func sessionsRoundTripAndCascadeWithTheirBook() throws {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let book = Book(fileName: "book.epub", originalFileName: "Book.epub")
        context.insert(book)
        book.setStatus(.reading, at: date(100))
        book.setStatus(.finished, at: date(200))
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<ReadingSession>()) == 1)
        let cycle = try #require(try context.fetch(FetchDescriptor<ReadingSession>()).first)
        #expect(cycle.book?.uuid == book.uuid)

        context.delete(book)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ReadingSession>()) == 0)
    }

    @Test func legacyDatesBackfillOnce() throws {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let book = Book(fileName: "book.epub", originalFileName: "Book.epub")
        book.readingStatus = .finished
        book.dateStarted = date(100)
        book.dateFinished = date(200)
        context.insert(book)
        try context.save()

        #expect(ReadingHistoryBackfill.run(context: context) == 1)
        #expect(ReadingHistoryBackfill.run(context: context) == 0)
        let cycle = try #require(book.readingSessions.first)
        #expect(cycle.status == .finished)
        #expect(cycle.startedAt == date(100))
        #expect(cycle.endedAt == date(200))
        #expect(cycle.progress == 1)
    }

    @Test func finishingALegacyRowPreservesItsOriginalDates() throws {
        let book = Book(fileName: "book.epub", originalFileName: "Book.epub")
        book.readingStatus = .finished
        book.dateStarted = date(100)
        book.dateFinished = date(200)

        book.setStatus(.finished, at: date(300))

        let cycle = try #require(book.readingSessions.first)
        #expect(cycle.startedAt == date(100))
        #expect(cycle.endedAt == date(200))
        #expect(book.dateFinished == date(200))
    }
}
