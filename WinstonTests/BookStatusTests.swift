import Testing
import Foundation
@testable import Winston

@MainActor
struct BookStatusTests {

    private func makeBook() -> Book {
        Book(fileName: "u.epub", originalFileName: "u.epub")
    }

    @Test func finishingStampsDateFinished() {
        let book = makeBook()
        #expect(book.dateFinished == nil)
        book.setStatus(.finished)
        #expect(book.readingStatus == .finished)
        #expect(book.dateFinished != nil)
    }

    @Test func refinishingKeepsTheOriginalDate() {
        let book = makeBook()
        book.setStatus(.finished)
        let first = book.dateFinished
        book.setStatus(.finished)
        #expect(book.dateFinished == first)
    }

    @Test(arguments: [ReadingStatus.unread, ReadingStatus.reading])
    func leavingFinishedClearsDate(_ status: ReadingStatus) {
        let book = makeBook()
        book.setStatus(.finished)
        book.setStatus(status)
        #expect(book.dateFinished == nil)
        #expect(book.readingStatus == status)
    }

    // MARK: - dateStarted

    @Test func startingReadingStampsDateStarted() {
        let book = makeBook()
        #expect(book.dateStarted == nil)
        book.setStatus(.reading)
        #expect(book.dateStarted != nil)
    }

    @Test func restartingKeepsTheOriginalStartDate() {
        let book = makeBook()
        book.setStatus(.reading)
        let first = book.dateStarted
        book.setStatus(.reading)
        #expect(book.dateStarted == first)
    }

    @Test func finishingKeepsTheStartDate() {
        let book = makeBook()
        book.setStatus(.reading)
        let started = book.dateStarted
        book.setStatus(.finished)
        #expect(book.dateStarted == started)
        #expect(book.dateFinished != nil)
    }

    @Test func markingUnreadClearsBothDates() {
        let book = makeBook()
        book.setStatus(.reading)
        book.setStatus(.finished)
        book.setStatus(.unread)
        #expect(book.dateStarted == nil)
        #expect(book.dateFinished == nil)
    }
}

// MARK: - Grid zoom

@MainActor
struct GridZoomTests {

    @Test func adjustClampsToBounds() {
        let settings = AppSettings()
        settings.gridZoom = 1.0
        settings.adjustGridZoom(by: AppSettings.gridZoomStep)
        #expect(settings.gridZoom == 1.0)
        settings.gridZoom = 0.0
        settings.adjustGridZoom(by: -AppSettings.gridZoomStep)
        #expect(settings.gridZoom == 0.0)
        settings.adjustGridZoom(by: AppSettings.gridZoomStep)
        #expect(settings.gridZoom == AppSettings.gridZoomStep)
        settings.gridZoom = AppSettings.defaultGridZoom
    }
}

// MARK: - Duplicate key

@MainActor
struct DuplicateKeyTests {

    private func book(title: String, author: String?) -> Book {
        let book = Book(fileName: "x.epub", originalFileName: "x.epub")
        book.title = title
        book.author = author
        return book
    }

    @Test func reversedAuthorFormsProduceTheSameKey() {
        let stored = book(title: "The Hobbit", author: "Tolkien, J. R. R.")
        let natural = book(title: "The Hobbit", author: "J. R. R. Tolkien")
        #expect(LibraryHealthService.duplicateKey(stored) == LibraryHealthService.duplicateKey(natural))
    }

    @Test func differentAuthorsProduceDifferentKeys() {
        let one = book(title: "Dune", author: "Frank Herbert")
        let other = book(title: "Dune", author: "Brian Herbert")
        #expect(LibraryHealthService.duplicateKey(one) != LibraryHealthService.duplicateKey(other))
    }
}

// MARK: - Library statistics

@MainActor
struct LibraryStatsTests {

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func aggregatesTimelineAndDistributions() {
        let now = date(2026, 6, 15)

        let reading = Book(fileName: "a.epub", originalFileName: "a.epub")
        reading.title = "A"
        reading.author = "X"
        reading.fileSizeBytes = 100
        reading.readingStatus = .reading
        reading.dateStarted = date(2026, 6, 1)

        let finished = Book(fileName: "b.epub", originalFileName: "b.epub")
        finished.title = "B"
        finished.author = "Y"
        finished.fileSizeBytes = 300
        finished.readingStatus = .finished
        finished.dateStarted = date(2026, 3, 1)
        finished.dateFinished = date(2026, 3, 11)

        let stats = LibraryStats(books: [reading, finished], calendar: .current, now: now)

        #expect(stats.bookCount == 2)
        #expect(stats.readingCount == 1)
        #expect(stats.finishedCount == 1)
        #expect(stats.finishedThisYear == 1)
        #expect(stats.uniqueAuthors == 2)
        #expect(stats.averageDaysToFinish == 10)
        #expect(stats.largestFinished?.title == "B")
        #expect(stats.monthly[2].started == 1)
        #expect(stats.monthly[2].finished == 1)
        #expect(stats.monthly[5].started == 1)
        #expect(stats.monthly[5].finished == 0)
    }
}
