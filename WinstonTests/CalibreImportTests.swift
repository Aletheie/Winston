import Testing
import Foundation
import SQLite3
@testable import Winston

// MARK: - Pure mapping helpers

struct CalibreMappingTests {

    @Test(arguments: zip(
        [0, 1, 2, 3, 7, 8, 9, 10],
        [nil, 1, 1, 2, 4, 4, 5, 5] as [Int?]
    ))
    func ratingMapsTenScaleToFiveStars(_ raw: Int, _ expected: Int?) {
        #expect(CalibreLibraryReader.winstonRating(raw) == expected)
    }

    @Test(arguments: zip(
        [1.0, 2.0, 2.5, 3.25, 0.0],
        ["1", "2", "2.5", "3.25", "0"]
    ))
    func seriesIndexDropsTrailingZero(_ value: Double, _ expected: String) {
        #expect(CalibreLibraryReader.formatSeriesIndex(value) == expected)
    }

    @Test(arguments: zip(
        ["1937-09-21 00:00:00+00:00", "2020-01-01", "0101-01-01 00:00:00+00:00", "0000-01-01", "abc", nil],
        ["1937", "2020", nil, nil, nil, nil] as [String?]
    ))
    func yearParsesPubdateAndRejectsSentinel(_ pubdate: String?, _ expected: String?) {
        #expect(CalibreLibraryReader.year(from: pubdate) == expected)
    }

    @Test func pickFormatHonoursPreferenceOrder() {
        let formats = [(format: "EPUB", name: "book"), (format: "AZW3", name: "book")]
        #expect(CalibreLibraryReader.pickFormat(formats, preference: ["azw3", "epub"])?.format == "AZW3")
        #expect(CalibreLibraryReader.pickFormat(formats, preference: ["epub", "azw3"])?.format == "EPUB")
    }

    @Test func pickFormatReturnsNilWhenNoneMatch() {
        let formats = [(format: "FB2", name: "book")]
        #expect(CalibreLibraryReader.pickFormat(formats, preference: CalibreImportService.kindlePreference) == nil)
    }

    @Test func dateParsesCalibreTimestampAsUTC() throws {
        let date = try #require(CalibreLibraryReader.date(from: "2024-01-15 10:30:00.000000+00:00"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let parts = cal.dateComponents([.year, .month, .day, .hour], from: date)
        #expect(parts.year == 2024 && parts.month == 1 && parts.day == 15 && parts.hour == 10)
    }

    @Test func displayedProgressIsOneBasedAndReachesTotal() {
        #expect(CalibreImportService.displayedPosition(for: 0) == 1)
        #expect(CalibreImportService.displayedPosition(for: 4) == 5)
    }
}

// MARK: - End-to-end read against a fixture metadata.db

struct CalibreLibraryReaderTests {

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CalibreFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bookDir = root.appending(path: "Tolkien/The Hobbit (1)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try Data("dummy".utf8).write(to: bookDir.appending(path: "book.azw3"))
        try Data("epub".utf8).write(to: bookDir.appending(path: "book.epub"))
        try Data("img".utf8).write(to: bookDir.appending(path: "cover.jpg"))

        var db: OpaquePointer?
        #expect(sqlite3_open(root.appending(path: "metadata.db").path(percentEncoded: false), &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, series_index REAL, path TEXT, pubdate TEXT, timestamp TEXT, author_sort TEXT);
        CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT, sort TEXT);
        CREATE TABLE books_authors_link (id INTEGER PRIMARY KEY, book INTEGER, author INTEGER);
        CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE books_tags_link (id INTEGER PRIMARY KEY, book INTEGER, tag INTEGER);
        CREATE TABLE series (id INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE books_series_link (id INTEGER PRIMARY KEY, book INTEGER, series INTEGER);
        CREATE TABLE publishers (id INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE books_publishers_link (id INTEGER PRIMARY KEY, book INTEGER, publisher INTEGER);
        CREATE TABLE ratings (id INTEGER PRIMARY KEY, rating INTEGER);
        CREATE TABLE books_ratings_link (id INTEGER PRIMARY KEY, book INTEGER, rating INTEGER);
        CREATE TABLE comments (id INTEGER PRIMARY KEY, book INTEGER, text TEXT);
        CREATE TABLE identifiers (id INTEGER PRIMARY KEY, book INTEGER, type TEXT, val TEXT);
        CREATE TABLE languages (id INTEGER PRIMARY KEY, lang_code TEXT);
        CREATE TABLE books_languages_link (id INTEGER PRIMARY KEY, book INTEGER, lang_code INTEGER, item_order INTEGER);
        CREATE TABLE data (id INTEGER PRIMARY KEY, book INTEGER, format TEXT, uncompressed_size INTEGER, name TEXT);
        INSERT INTO books VALUES (1,'The Hobbit',1.0,'Tolkien/The Hobbit (1)','1937-09-21 00:00:00+00:00','2024-01-15 10:30:00+00:00','Tolkien, J.R.R.');
        INSERT INTO authors VALUES (1,'J.R.R. Tolkien','Tolkien, J.R.R.');
        INSERT INTO books_authors_link VALUES (1,1,1);
        INSERT INTO tags VALUES (1,'Fantasy'),(2,'Classic');
        INSERT INTO books_tags_link VALUES (1,1,1),(2,1,2);
        INSERT INTO series VALUES (1,'Middle-earth');
        INSERT INTO books_series_link VALUES (1,1,1);
        INSERT INTO publishers VALUES (1,'Allen & Unwin');
        INSERT INTO books_publishers_link VALUES (1,1,1);
        INSERT INTO ratings VALUES (1,8);
        INSERT INTO books_ratings_link VALUES (1,1,1);
        INSERT INTO comments VALUES (1,1,'<p>A hobbit goes on an adventure.</p>');
        INSERT INTO identifiers VALUES (1,1,'isbn','9780261103344');
        INSERT INTO languages VALUES (1,'eng');
        INSERT INTO books_languages_link VALUES (1,1,1,0);
        INSERT INTO data VALUES (1,1,'EPUB',1000,'book'),(2,1,'AZW3',1000,'book');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return root
    }

    @Test func readsAllMetadataAndPicksPreferredFormat() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let books = try CalibreLibraryReader.read(libraryRoot: root,
                                                  formatPreference: CalibreImportService.kindlePreference)
        let book = try #require(books.first)
        #expect(books.count == 1)
        #expect(book.title == "The Hobbit")
        #expect(book.authors == ["J.R.R. Tolkien"])
        #expect(book.series == "Middle-earth")
        #expect(book.seriesIndex == "1")
        #expect(book.publisher == "Allen & Unwin")
        #expect(book.year == "1937")
        #expect(book.language == "eng")
        #expect(book.isbn == "9780261103344")
        #expect(book.tags == ["Classic", "Fantasy"])
        #expect(book.bookDescription == "<p>A hobbit goes on an adventure.</p>")
        #expect(book.rating == 4)
        #expect(book.dateAdded != nil)
        #expect(book.fileURL.lastPathComponent == "book.azw3")
        #expect(book.additionalFileURLs.map(\.lastPathComponent) == ["book.epub"])
        #expect(book.coverURL?.lastPathComponent == "cover.jpg")
    }

    @Test func missingDatabaseThrowsNoLibrary() {
        let empty = FileManager.default.temporaryDirectory.appending(path: "NotALibrary-\(UUID().uuidString)")
        #expect(throws: CalibreImportError.noLibrary) {
            try CalibreLibraryReader.read(libraryRoot: empty, formatPreference: CalibreImportService.kindlePreference)
        }
    }
}
