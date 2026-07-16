import Foundation
import SwiftData
import Testing
@testable import Winston

@Suite("Reading history import")
struct ReadingHistoryImportParserTests {
    @Test func parsesGoodreadsQuotedFieldsAndNormalizesISBN() throws {
        let csv = #"""
        Book Id,Title,Author,ISBN13,My Rating,Date Read,Exclusive Shelf,Read Count,My Review
        1,"The Book, Again",Ada Reader,"=""9781234567890""",4,2024/02/03,read,2,"First line
        second line"
        """#

        let document = try ReadingHistoryExportParser.parse(
            data: Data(csv.utf8),
            fileName: "goodreads_library_export.csv"
        )
        let record = try #require(document.records.first)

        #expect(document.source == .goodreads)
        #expect(record.title == "The Book, Again")
        #expect(record.author == "Ada Reader")
        #expect(record.isbn == "9781234567890")
        #expect(record.status == .finished)
        #expect(record.rating == 4)
        #expect(record.readCount == 2)
        #expect(record.cycles.count == 1)
        #expect(record.cycles.first?.status == .finished)
    }

    @Test func parsesStoryGraphRereadDatesAndFractionalRating() throws {
        let csv = #"""
        Title,Authors,ISBN/UID,Read Status,Star Rating,Last Date Read,Dates Read,Read Count
        Reread Me,Story Author,9781111111111,read,4.5,2024-03-04,"2022/01/02, 2024/03/04",2
        """#

        let document = try ReadingHistoryExportParser.parse(
            data: Data(csv.utf8),
            fileName: "storygraph-export.csv"
        )
        let record = try #require(document.records.first)

        #expect(document.source == .storyGraph)
        #expect(record.cycles.count == 2)
        #expect(record.cycles.allSatisfy { $0.status == .finished })
        #expect(record.winstonRating == 5)
        #expect(record.readCount == 2)
    }

    @Test func recognizesHardcoverColumnAliases() throws {
        let csv = #"""
        Title,Author,ISBN,Status,Rating,Date Started,Date Finished
        Offline Book,Local Author,9782222222222,Currently Reading,3,2026-07-01,
        """#

        let document = try ReadingHistoryExportParser.parse(
            data: Data(csv.utf8),
            fileName: "hardcover-export.csv"
        )
        let record = try #require(document.records.first)

        #expect(document.source == .hardcover)
        #expect(record.status == .reading)
        #expect(record.startedAt != nil)
        #expect(record.cycles.first?.status == .reading)
        #expect(record.cycles.first?.endedAt == nil)
    }

    @Test func decodesWindowsExportAndSemicolonDelimiter() throws {
        let csv = "Book Id;Title;Author;My Rating;Date Read;Exclusive Shelf\n1;Café Society;Daniel Keyes;4,5;2024/02/03;read\n"
        let data = try #require(csv.data(using: .windowsCP1252))

        let document = try ReadingHistoryExportParser.parse(
            data: data,
            fileName: "goodreads_library_export.csv"
        )
        let record = try #require(document.records.first)

        #expect(record.title == "Café Society")
        #expect(record.rating == 4.5)
        #expect(record.winstonRating == 5)
    }

    @Test func rejectsUnterminatedQuotedField() {
        let csv = "Book Id,Title,Author,Exclusive Shelf\n1,\"Broken title,Author,read\n"

        #expect(throws: ReadingHistoryImportError.invalidCSV) {
            try ReadingHistoryExportParser.parse(
                data: Data(csv.utf8),
                fileName: "goodreads_library_export.csv"
            )
        }
    }

    @Test func parsesAFileURLThroughTheSameEntryPointAsTheOpenPanel() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-history-\(UUID().uuidString).csv")
        let csv = "Book Id,Title,Author,Exclusive Shelf\n1,Local File,Ada Reader,read\n"
        try Data(csv.utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try ReadingHistoryExportParser.parse(url: url)

        #expect(document.source == .goodreads)
        #expect(document.fileName == url.lastPathComponent)
        #expect(document.records.first?.title == "Local File")
    }

    @Test func rejectsUnknownCSVInsteadOfGuessing() {
        let csv = "Title,Author,Score\nBook,Author,5\n"

        #expect(throws: ReadingHistoryImportError.unknownSource) {
            try ReadingHistoryExportParser.parse(data: Data(csv.utf8), fileName: "spreadsheet.csv")
        }
    }
}

@Suite("Reading history matching and application")
@MainActor
struct ReadingHistoryImportApplicationTests {
    @Test func matcherPrefersISBNAndLeavesTitleOnlyMatchForReview() throws {
        let isbnBook = Book(fileName: "one.epub", originalFileName: "One.epub")
        isbnBook.title = "Different Export Title"
        isbnBook.author = "Ada Reader"
        isbnBook.isbn = "978-1-234-56789-0"
        let titleBook = Book(fileName: "two.epub", originalFileName: "Two.epub")
        titleBook.title = "Title Only"
        titleBook.author = "Someone"

        let exact = record(
            id: "exact",
            title: "Changed Title",
            author: "Other Author",
            isbn: "9781234567890",
            status: .finished
        )
        let uncertain = record(id: "uncertain", title: "Title Only", status: .finished)
        let rows = ReadingHistoryImportMatcher.match(records: [exact, uncertain], books: [isbnBook, titleBook])

        #expect(rows[0].matchKind == .isbn)
        #expect(rows[0].matchedBookID == isbnBook.uuid)
        #expect(rows[0].isIncluded)
        #expect(rows[1].matchKind == .titleOnly)
        #expect(rows[1].matchedBookID == titleBook.uuid)
        #expect(!rows[1].isIncluded)
    }

    @Test func ambiguousMatchesAreNotImportedUntilChosen() {
        let first = Book(fileName: "one.epub", originalFileName: "One.epub")
        first.title = "Shared"
        first.author = "Same Author"
        let second = Book(fileName: "two.epub", originalFileName: "Two.epub")
        second.title = "Shared"
        second.author = "Same Author"

        let rows = ReadingHistoryImportMatcher.match(
            records: [record(id: "shared", title: "Shared", author: "Same Author", status: .finished)],
            books: [first, second]
        )

        #expect(rows.first?.matchKind == .ambiguous)
        #expect(rows.first?.matchedBookID == nil)
        #expect(rows.first?.candidates.count == 2)
        #expect(rows.first?.isIncluded == false)
    }

    @Test func importAddsOnlyMissingCycleAndPreservesExistingHistory() throws {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let book = Book(fileName: "history.epub", originalFileName: "History.epub")
        book.title = "History"
        book.author = "Ada Reader"
        let oldSession = ReadingSession(
            startedAt: day(2020, 1, 1),
            endedAt: day(2020, 1, 2),
            status: .finished,
            progress: 1,
            book: book
        )
        context.insert(book)
        context.insert(oldSession)
        try context.save()

        let imported = record(
            id: "history",
            title: "History",
            author: "Ada Reader",
            status: .finished,
            rating: 4,
            cycles: [
                ReadingHistoryImportCycle(
                    startedAt: day(2024, 2, 1),
                    endedAt: day(2024, 2, 4),
                    status: .finished,
                    progress: 1
                ),
            ]
        )
        let rows = ReadingHistoryImportMatcher.match(records: [imported], books: [book])
        let result = try ReadingHistoryImporter(modelContext: context).apply(rows)

        #expect(result.bookCount == 1)
        #expect(result.cycleCount == 1)
        #expect(result.ratingCount == 1)
        #expect(book.rating == 4)
        #expect(book.readingSessions.count == 2)
        #expect(book.readingSessions.contains { $0.uuid == oldSession.uuid })
        #expect(book.dateFinished == day(2024, 2, 4))
    }

    @Test func importingTheSameExportTwiceIsIdempotent() throws {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let book = Book(fileName: "again.epub", originalFileName: "Again.epub")
        book.title = "Again"
        context.insert(book)
        try context.save()

        let imported = record(
            id: "again",
            title: "Again",
            status: .finished,
            rating: 5,
            cycles: [
                ReadingHistoryImportCycle(
                    startedAt: nil,
                    endedAt: day(2025, 5, 5),
                    status: .finished,
                    progress: 1
                ),
            ]
        )
        var rows = ReadingHistoryImportMatcher.match(records: [imported], books: [book])
        rows[0].isIncluded = true
        _ = try ReadingHistoryImporter(modelContext: context).apply(rows)
        let second = try ReadingHistoryImporter(modelContext: context).apply(rows)

        #expect(book.readingSessions.count == 1)
        #expect(second == ReadingHistoryImportResult(bookCount: 0, cycleCount: 0, statusCount: 0, ratingCount: 0))
    }

    @Test func failedSaveRollsBackEveryImportedChange() throws {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let book = Book(fileName: "rollback.epub", originalFileName: "Rollback.epub")
        book.title = "Rollback"
        context.insert(book)
        try context.save()

        let imported = record(
            id: "rollback",
            title: "Rollback",
            status: .finished,
            rating: 5,
            cycles: [
                ReadingHistoryImportCycle(
                    startedAt: nil,
                    endedAt: day(2026, 6, 6),
                    status: .finished,
                    progress: 1
                ),
            ]
        )
        var rows = ReadingHistoryImportMatcher.match(records: [imported], books: [book])
        rows[0].isIncluded = true
        let importer = ReadingHistoryImporter(modelContext: context, save: { throw TestImportError.expected })

        #expect(throws: TestImportError.expected) {
            try importer.apply(rows)
        }
        #expect(book.rating == nil)
        #expect(book.readingSessions.isEmpty)
        #expect(book.readingStatus == .unread)
    }

    private func record(
        id: String,
        title: String,
        author: String? = nil,
        isbn: String? = nil,
        status: ReadingStatus? = nil,
        rating: Double? = nil,
        cycles: [ReadingHistoryImportCycle] = []
    ) -> ReadingHistoryImportRecord {
        ReadingHistoryImportRecord(
            id: id,
            source: .goodreads,
            rowNumber: 2,
            title: title,
            author: author,
            isbn: isbn,
            status: status,
            rating: rating,
            startedAt: cycles.first?.startedAt,
            finishedAt: cycles.last?.endedAt,
            readCount: cycles.count,
            cycles: cycles
        )
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}

private enum TestImportError: Error {
    case expected
}
