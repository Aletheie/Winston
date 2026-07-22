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

// MARK: - Calibre path boundary

struct CalibrePathResolverTests {

    private func makeSandbox() throws -> (base: URL, root: URL) {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "CalibrePathResolver-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (base, root)
    }

    @Test func resolvesRegularUnicodeFileAndNormalizesFormatCase() throws {
        let fixture = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let directory = fixture.root.appending(
            path: "Čapek/Žluťoučký kůň",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expected = directory.appending(path: "Příběh.epub")
        try Data("book".utf8).write(to: expected)

        let resolver = try CalibrePathResolver(
            libraryRoot: fixture.root,
            supportedFormats: ["epub"]
        )
        let source = try resolver.resolve(
            rawRelativeBookPath: "Čapek/Žluťoučký kůň",
            rawFileName: "Příběh",
            declaredFormat: "EPUB"
        )

        #expect(source.url == expected.standardizedFileURL.resolvingSymlinksInPath())
        #expect(try source.revalidatedURL() == source.url)
    }

    @Test func rejectsTraversalAndAbsoluteBookPaths() throws {
        let fixture = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let outside = fixture.base.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appending(path: "book.epub"))
        let resolver = try CalibrePathResolver(
            libraryRoot: fixture.root,
            supportedFormats: ["epub"]
        )

        #expect(throws: CalibrePathError.traversalComponent) {
            try resolver.resolve(
                rawRelativeBookPath: "Žluťoučký/../Outside",
                rawFileName: "book",
                declaredFormat: "epub"
            )
        }
        #expect(throws: CalibrePathError.absoluteBookPath) {
            try resolver.resolve(
                rawRelativeBookPath: outside.path(percentEncoded: false),
                rawFileName: "book",
                declaredFormat: "epub"
            )
        }
    }

    @Test func rejectsSymlinkedParentEvenWhenTargetExists() throws {
        let fixture = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let outside = fixture.base.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appending(path: "book.epub"))
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appending(path: "Linked", directoryHint: .isDirectory),
            withDestinationURL: outside
        )
        let resolver = try CalibrePathResolver(
            libraryRoot: fixture.root,
            supportedFormats: ["epub"]
        )

        #expect(throws: CalibrePathError.symbolicLink) {
            try resolver.resolve(
                rawRelativeBookPath: "Linked",
                rawFileName: "book",
                declaredFormat: "epub"
            )
        }
    }

    @Test func rejectsSymlinkedFileAndNonRegularFile() throws {
        let fixture = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let bookDirectory = fixture.root.appending(path: "Book", directoryHint: .isDirectory)
        let outside = fixture.base.appending(path: "outside.epub")
        try FileManager.default.createDirectory(at: bookDirectory, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: bookDirectory.appending(path: "linked.epub"),
            withDestinationURL: outside
        )
        try FileManager.default.createDirectory(
            at: bookDirectory.appending(path: "directory.epub", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )
        let resolver = try CalibrePathResolver(
            libraryRoot: fixture.root,
            supportedFormats: ["epub"]
        )

        #expect(throws: CalibrePathError.symbolicLink) {
            try resolver.resolve(
                rawRelativeBookPath: "Book",
                rawFileName: "linked",
                declaredFormat: "epub"
            )
        }
        #expect(throws: CalibrePathError.notRegularFile) {
            try resolver.resolve(
                rawRelativeBookPath: "Book",
                rawFileName: "directory",
                declaredFormat: "epub"
            )
        }
    }

    @Test func revalidationRejectsFileReplacedBySymlink() throws {
        let fixture = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let bookDirectory = fixture.root.appending(path: "Book", directoryHint: .isDirectory)
        let bookURL = bookDirectory.appending(path: "book.epub")
        let outside = fixture.base.appending(path: "outside.epub")
        try FileManager.default.createDirectory(at: bookDirectory, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: bookURL)
        try Data("outside".utf8).write(to: outside)
        let resolver = try CalibrePathResolver(
            libraryRoot: fixture.root,
            supportedFormats: ["epub"]
        )
        let source = try resolver.resolve(
            rawRelativeBookPath: "Book",
            rawFileName: "book",
            declaredFormat: "epub"
        )

        try FileManager.default.removeItem(at: bookURL)
        try FileManager.default.createSymbolicLink(at: bookURL, withDestinationURL: outside)

        #expect(throws: CalibrePathError.symbolicLink) {
            try source.revalidatedURL()
        }
    }

    @Test func rejectsPathSeparatorsInFileNameAndUnsupportedFormat() throws {
        let fixture = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let directory = fixture.root.appending(path: "Book", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolver = try CalibrePathResolver(
            libraryRoot: fixture.root,
            supportedFormats: ["epub"]
        )

        #expect(throws: CalibrePathError.invalidFileName) {
            try resolver.resolve(
                rawRelativeBookPath: "Book",
                rawFileName: "../outside",
                declaredFormat: "epub"
            )
        }
        #expect(throws: CalibrePathError.unsupportedFormat) {
            try resolver.resolve(
                rawRelativeBookPath: "Book",
                rawFileName: "book",
                declaredFormat: "exe"
            )
        }
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

    private func execute(_ sql: String, in root: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(
            root.appending(path: "metadata.db").path(percentEncoded: false),
            &db
        ) == SQLITE_OK, let db else {
            throw CalibreImportError.cannotOpen
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CalibreImportError.stepFailed(
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    @Test func readsAllMetadataAndPicksPreferredFormat() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let readResult = try await CalibreLibraryReader.read(
            libraryRoot: root,
            formatPreference: CalibreImportService.kindlePreference
        )
        let books = readResult.books
        let book = try #require(books.first)
        #expect(books.count == 1)
        #expect(readResult.rejectedSources.isEmpty)
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

    @Test func missingDatabaseThrowsNoLibrary() async {
        let empty = FileManager.default.temporaryDirectory.appending(path: "NotALibrary-\(UUID().uuidString)")
        await #expect(throws: CalibreImportError.noLibrary) {
            try await CalibreLibraryReader.read(
                libraryRoot: empty,
                formatPreference: CalibreImportService.kindlePreference
            )
        }
    }

    @Test func symlinkedMetadataDatabaseIsRejected() async throws {
        let sourceLibrary = try makeFixture()
        let selectedRoot = FileManager.default.temporaryDirectory.appending(
            path: "CalibreLinkedDB-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: sourceLibrary)
            try? FileManager.default.removeItem(at: selectedRoot)
        }
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: selectedRoot.appending(path: "metadata.db"),
            withDestinationURL: sourceLibrary.appending(path: "metadata.db")
        )

        await #expect(throws: CalibreImportError.unsafeLibraryPath(.symbolicLink)) {
            try await CalibreLibraryReader.read(
                libraryRoot: selectedRoot,
                formatPreference: CalibreImportService.kindlePreference
            )
        }
    }

    @Test func traversalFromDatabaseIsExplicitlyRejectedAndNeverReturned() async throws {
        let root = try makeFixture()
        let outside = root.deletingLastPathComponent().appending(
            path: "CalibreOutside-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appending(path: "book.azw3"))
        try Data("outside".utf8).write(to: outside.appending(path: "book.epub"))
        try execute(
            "UPDATE books SET path = '../\(outside.lastPathComponent)' WHERE id = 1",
            in: root
        )

        let result = try await CalibreLibraryReader.read(
            libraryRoot: root,
            formatPreference: CalibreImportService.kindlePreference
        )

        #expect(result.books.isEmpty)
        #expect(!result.rejectedSources.isEmpty)
        #expect(result.rejectedSources.allSatisfy { $0.reason == .traversalComponent })
        #expect(result.unsafeRejectionCount == result.rejectedSources.count)
    }

    @Test func symlinkedAdditionalFormatIsRejectedWhileSafePrimaryRemains() async throws {
        let root = try makeFixture()
        let outside = root.deletingLastPathComponent().appending(
            path: "CalibreOutside-\(UUID().uuidString).epub"
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("outside".utf8).write(to: outside)
        let linkedFormat = root.appending(path: "Tolkien/The Hobbit (1)/book.epub")
        try FileManager.default.removeItem(at: linkedFormat)
        try FileManager.default.createSymbolicLink(at: linkedFormat, withDestinationURL: outside)

        let result = try await CalibreLibraryReader.read(
            libraryRoot: root,
            formatPreference: CalibreImportService.kindlePreference
        )
        let book = try #require(result.books.first)

        #expect(book.fileURL.lastPathComponent == "book.azw3")
        #expect(book.additionalSourceFiles.isEmpty)
        #expect(result.rejectedSources.contains {
            $0.role == .bookFormat("epub") && $0.reason == .symbolicLink
        })
    }

    @Test func missingSchemaIsReportedInsteadOfLookingLikeEmptyImport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CalibreMissingSchema-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appending(path: "metadata.db").path(percentEncoded: false), &db) == SQLITE_OK)
        sqlite3_close(db)

        do {
            _ = try await CalibreLibraryReader.read(
                libraryRoot: root,
                formatPreference: CalibreImportService.kindlePreference
            )
            Issue.record("missing Calibre schema should throw")
        } catch let error as CalibreImportError {
            guard case .missingSchema = error else {
                Issue.record("expected missingSchema, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func sqlitePrepareFailureIsReported() throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
        let connection = try #require(db)
        defer { sqlite3_close(connection) }

        do {
            try CalibreLibraryReader.eachRow(connection, "SELECT FROM") { _ in }
            Issue.record("invalid SQL should fail during prepare")
        } catch let error as CalibreImportError {
            guard case .prepareFailed = error else {
                Issue.record("expected prepareFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func sqliteStepFailureIsReported() throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
        let connection = try #require(db)
        defer { sqlite3_close(connection) }

        do {
            try CalibreLibraryReader.eachRow(
                connection,
                "SELECT abs(-9223372036854775808)"
            ) { _ in }
            Issue.record("integer overflow should fail during step")
        } catch let error as CalibreImportError {
            guard case .stepFailed = error else {
                Issue.record("expected stepFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func corruptDatabaseIsAnExplicitDatabaseFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CalibreCorruptDB-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: root.appending(path: "metadata.db"))

        do {
            _ = try await CalibreLibraryReader.read(
                libraryRoot: root,
                formatPreference: CalibreImportService.kindlePreference
            )
            Issue.record("corrupt database should throw")
        } catch let error as CalibreImportError {
            switch error {
            case .prepareFailed, .stepFailed:
                break
            default:
                Issue.record("expected a typed database failure, got \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

// MARK: - Reconciliation policy

struct CalibreImportReconcilerTests {
    private let existingBookID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let existingWorkID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!

    @Test func onlyAnExactContentHashCanSkipAnItem() {
        let reconciler = CalibreImportReconciler(books: [existing(hash: "same", isbn: "111")])

        #expect(reconciler.decision(for: candidate(hash: "same", isbn: "999"))
            == .skipExact(existingBookID: existingBookID))
        #expect(reconciler.decision(for: candidate(hash: "different", isbn: "111"))
            == .merge(existingBookID: existingBookID, workID: existingWorkID))
    }

    @Test func titleAndAuthorNeverSilentlySkipAnotherEdition() {
        let reconciler = CalibreImportReconciler(books: [existing(hash: "old", isbn: "111")])

        #expect(reconciler.decision(for: candidate(hash: "new", isbn: "222"))
            == .addEdition(workID: existingWorkID))
    }

    @Test func weakTitleAuthorIdentityRequiresReviewInsteadOfSkipping() {
        let reconciler = CalibreImportReconciler(books: [existing(hash: "old", isbn: nil)])

        #expect(reconciler.decision(for: candidate(hash: "new", isbn: nil))
            == .needsReview(candidateWorkIDs: [existingWorkID]))
    }

    @Test(arguments: [1_000, 10_000])
    func indexedReconciliationBenchmark(_ count: Int) {
        let catalog = (0..<count).map { index in
            CalibreImportCatalogBook(
                bookID: UUID(),
                workID: UUID(),
                title: "Book \(index)",
                author: "Author \(index)",
                isbn: "978\(index)",
                language: "eng",
                publisher: "Press",
                year: "2024",
                contentHashes: ["hash-\(index)"],
                formats: ["epub"]
            )
        }
        let candidates = catalog.map { book in
            CalibreImportCandidate(
                bookID: UUID(),
                workID: UUID(),
                title: book.title,
                author: book.author,
                isbn: book.isbn,
                language: book.language,
                publisher: book.publisher,
                year: book.year,
                contentHashes: book.contentHashes,
                formats: ["pdf"]
            )
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let reconciler = CalibreImportReconciler(books: catalog)
        let exactMatches = candidates.count {
            if case .skipExact = reconciler.decision(for: $0) { return true }
            return false
        }
        let elapsed = startedAt.duration(to: clock.now)

        print("Calibre reconciliation benchmark (\(count) books): \(elapsed)")
        #expect(exactMatches == count)
        #expect(elapsed < .seconds(5))
    }

    private func existing(hash: String, isbn: String?) -> CalibreImportCatalogBook {
        CalibreImportCatalogBook(
            bookID: existingBookID,
            workID: existingWorkID,
            title: "The Book",
            author: "Ada Author",
            isbn: isbn,
            language: "eng",
            publisher: "Press",
            year: "2024",
            contentHashes: [hash],
            formats: ["epub"]
        )
    }

    private func candidate(hash: String, isbn: String?) -> CalibreImportCandidate {
        CalibreImportCandidate(
            bookID: UUID(),
            workID: UUID(),
            title: "The Book",
            author: "Ada Author",
            isbn: isbn,
            language: "eng",
            publisher: "Press",
            year: "2024",
            contentHashes: [hash],
            formats: ["pdf"]
        )
    }
}

// MARK: - Durable session state machine

@Suite("Calibre import manifest", .serialized)
struct CalibreImportManifestTests {
    private actor InvocationCounter {
        private var value = 0

        func increment() -> Int {
            value += 1
            return value
        }

        func current() -> Int { value }
    }

    @Test func cancellationPersistsAndTheSameSessionResumesIdempotently() async throws {
        let fixture = try CalibreSessionFixture.make(bookCount: 2)
        let sessions = fixture.root.appending(path: "Sessions", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let read = try await CalibreLibraryReader.read(
            libraryRoot: fixture.root,
            formatPreference: CalibreImportService.kindlePreference
        )
        let session = try await CalibreImportSession.create(
            libraryRoot: fixture.root,
            books: read.books,
            unsafeRejectedSources: 0,
            collectionName: "Test Import",
            directory: sessions
        )
        let counter = InvocationCounter()

        let cancelled = await session.run(
            chunkSize: 1,
            progressHandler: { _ in },
            processor: { items in
                _ = await counter.increment()
                let item = items[0]
                await session.requestCancellation()
                return CalibreImportChunkResult(outcomes: [CalibreImportOutcome(
                    calibreID: item.calibreID,
                    category: .imported,
                    bookID: item.bookID,
                    message: nil
                )])
            }
        )

        #expect(cancelled.phase == .cancelled)
        #expect(cancelled.imported == 1)
        #expect(cancelled.pending == 1)

        let resumed = try #require(try await CalibreImportSession.resumable(
            for: fixture.root,
            directory: sessions
        ))
        try await resumed.reconcileForResume(durableOutcomes: [])
        let completed = await resumed.run(
            chunkSize: 1,
            progressHandler: { _ in },
            processor: { items in
                _ = await counter.increment()
                return CalibreImportChunkResult(outcomes: items.map {
                    CalibreImportOutcome(
                        calibreID: $0.calibreID,
                        category: .imported,
                        bookID: $0.bookID,
                        message: nil
                    )
                })
            }
        )

        #expect(completed.phase == .completed)
        #expect(completed.imported == 2)
        #expect(completed.pending == 0)
        let callsBeforeReplay = await counter.current()
        _ = await resumed.run(
            chunkSize: 1,
            progressHandler: { _ in },
            processor: { _ in
                _ = await counter.increment()
                return CalibreImportChunkResult()
            }
        )
        #expect(await counter.current() == callsBeforeReplay)
        #expect(try await CalibreImportSession.resumable(
            for: fixture.root,
            directory: sessions
        ) == nil)
    }

    @Test func resumeDoesNotDoubleCountRejectedSources() async throws {
        let fixture = try CalibreSessionFixture.make(bookCount: 1)
        let sessions = fixture.root.appending(path: "Sessions", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let read = try await CalibreLibraryReader.read(
            libraryRoot: fixture.root,
            formatPreference: CalibreImportService.kindlePreference
        )
        let session = try await CalibreImportSession.create(
            libraryRoot: fixture.root,
            books: read.books,
            unsafeRejectedSources: 0,
            collectionName: "Test Import",
            directory: sessions
        )

        let failed = await session.run(
            chunkSize: 1,
            progressHandler: { _ in },
            processor: { items in
                CalibreImportChunkResult(
                    unsafeRejectedSourcesByItem: [items[0].calibreID: 1],
                    failure: CalibreImportChunkFailure(
                        calibreID: items[0].calibreID,
                        message: "Injected failure",
                        isCancellation: false,
                        preservePreparedItems: false
                    )
                )
            }
        )
        #expect(failed.unsafeRejectedSources == 1)

        let resumed = try #require(try await CalibreImportSession.resumable(
            for: fixture.root,
            directory: sessions
        ))
        try await resumed.reconcileForResume(durableOutcomes: [])
        let completed = await resumed.run(
            chunkSize: 1,
            progressHandler: { _ in },
            processor: { items in
                CalibreImportChunkResult(
                    outcomes: [CalibreImportOutcome(
                        calibreID: items[0].calibreID,
                        category: .imported,
                        bookID: items[0].bookID,
                        message: nil
                    )],
                    unsafeRejectedSourcesByItem: [items[0].calibreID: 1]
                )
            }
        )

        #expect(completed.phase == .completed)
        #expect(completed.unsafeRejectedSources == 1)
    }
}

// MARK: - End-to-end failure, recovery, and repeatability

@Suite("Calibre import transactional session", .serialized)
@MainActor
struct CalibreImportSessionIntegrationTests {
    private struct InjectedSaveFailure: Error {}

    @Test(arguments: [1, 2, 3])
    func saveFailureAtEveryChunkStopsThenResumeCompletesWithoutDuplicates(
        _ failingChunk: Int
    ) async throws {
        let library = try await TestLibrary()
        let fixture = try CalibreSessionFixture.make(bookCount: 3)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessionDirectory = library.root.appending(path: "CalibreSessions", directoryHint: .isDirectory)
        let managedFiles = ManagedFileCoordinator()
        var saveCount = 0
        let failingAdapter = CatalogSaveAdapter { context in
            saveCount += 1
            if saveCount == failingChunk { throw InjectedSaveFailure() }
            try context.save()
        }
        let first = makeService(
            library: library,
            saveAdapter: failingAdapter,
            managedFiles: managedFiles,
            sessionDirectory: sessionDirectory
        )

        first.importLibrary(at: fixture.root)
        await first.waitForCurrentImport()

        let stopped = try #require(first.result)
        #expect(stopped.phase == .failed)
        #expect(stopped.imported == failingChunk - 1)
        #expect(stopped.failed == 1)
        #expect(library.context.allBooks().count == failingChunk - 1)
        #expect(!library.context.hasChanges)

        let resumed = makeService(
            library: library,
            saveAdapter: .live,
            managedFiles: managedFiles,
            sessionDirectory: sessionDirectory
        )
        resumed.importLibrary(at: fixture.root)
        await resumed.waitForCurrentImport()

        let completed = try #require(resumed.result)
        #expect(completed.phase == .completed)
        #expect(completed.imported == 3)
        #expect(completed.failed == 0)
        #expect(library.context.allBooks().count == 3)
        #expect(library.context.allBooks().allSatisfy { $0.primaryFileURL != nil })
        #expect(library.context.allBooks().allSatisfy { $0.coverVersion == 0 })

        resumed.importLibrary(at: fixture.root)
        await resumed.waitForCurrentImport()

        let repeated = try #require(resumed.result)
        #expect(repeated.phase == .completed)
        #expect(repeated.imported == 0)
        #expect(repeated.skippedExact == 3)
        #expect(library.context.allBooks().count == 3)
    }

    @Test func publicationFailureAfterCatalogSaveResumesTheCommittedItem() async throws {
        let library = try await TestLibrary()
        let fixture = try CalibreSessionFixture.make(bookCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessionDirectory = library.root.appending(path: "CalibreSessions", directoryHint: .isDirectory)
        let failingCoordinator = ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory,
            faultInjector: { point in
                if case .duringPublish = point {
                    throw ManagedFileCoordinatorError.injectedFailure(point)
                }
            }
        )
        let first = makeService(
            library: library,
            saveAdapter: .live,
            managedFiles: failingCoordinator,
            sessionDirectory: sessionDirectory
        )

        first.importLibrary(at: fixture.root)
        await first.waitForCurrentImport()

        let stopped = try #require(first.result)
        #expect(stopped.phase == .failed)
        #expect(stopped.failed == 1)
        #expect(library.context.allBooks().count == 1)
        #expect(await failingCoordinator.pendingTransactions().count == 1)

        let recoveringCoordinator = ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory
        )
        let resumed = makeService(
            library: library,
            saveAdapter: .live,
            managedFiles: recoveringCoordinator,
            sessionDirectory: sessionDirectory
        )
        resumed.importLibrary(at: fixture.root)
        await resumed.waitForCurrentImport()

        let completed = try #require(resumed.result)
        #expect(completed.phase == .completed)
        #expect(completed.imported == 1)
        #expect(completed.failed == 0)
        #expect(library.context.allBooks().count == 1)
        #expect(library.context.allBooks().first?.primaryFileURL != nil)
        #expect(await recoveringCoordinator.pendingTransactions().isEmpty)
    }

    @Test func diskFullBeforeCatalogCommitLeavesNoDirtyModelsAndCanBeRetried() async throws {
        let library = try await TestLibrary()
        let fixture = try CalibreSessionFixture.make(bookCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessionDirectory = library.root.appending(path: "CalibreSessions", directoryHint: .isDirectory)
        let failingCoordinator = ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory,
            faultInjector: { point in
                if point == .afterStaging {
                    throw POSIXError(.ENOSPC)
                }
            }
        )
        let first = makeService(
            library: library,
            saveAdapter: .live,
            managedFiles: failingCoordinator,
            sessionDirectory: sessionDirectory
        )

        first.importLibrary(at: fixture.root)
        await first.waitForCurrentImport()

        #expect(first.result?.phase == .failed)
        #expect(library.context.allBooks().isEmpty)
        #expect(!library.context.hasChanges)
        #expect(await failingCoordinator.pendingTransactions().count == 1)

        let recoveringCoordinator = ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory
        )
        let resumed = makeService(
            library: library,
            saveAdapter: .live,
            managedFiles: recoveringCoordinator,
            sessionDirectory: sessionDirectory
        )
        resumed.importLibrary(at: fixture.root)
        await resumed.waitForCurrentImport()

        #expect(resumed.result?.phase == .completed)
        #expect(resumed.result?.imported == 1)
        #expect(library.context.allBooks().count == 1)
        #expect(await recoveringCoordinator.pendingTransactions().isEmpty)
    }

    @Test func invalidCoverDoesNotCreateAPartialFileTransaction() async throws {
        let library = try await TestLibrary()
        let fixture = try CalibreSessionFixture.make(bookCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessionDirectory = library.root.appending(path: "CalibreSessions", directoryHint: .isDirectory)
        let managedFiles = ManagedFileCoordinator()
        let service = makeService(
            library: library,
            saveAdapter: .live,
            managedFiles: managedFiles,
            sessionDirectory: sessionDirectory
        )

        service.importLibrary(at: fixture.root)
        await service.waitForCurrentImport()

        let summary = try #require(service.result)
        let book = try #require(library.context.allBooks().first)
        #expect(summary.phase == .completed)
        #expect(summary.imported == 1)
        #expect(book.coverVersion == 0)
        #expect(!CoverStore.exists(for: book.uuid))
        #expect(book.primaryFileURL != nil)
        #expect(await managedFiles.pendingTransactions().isEmpty)
    }

    @Test func anotherFormatOfTheSameEditionIsMergedInsteadOfSkipped() async throws {
        let library = try await TestLibrary()
        let fixture = try CalibreSessionFixture.make(bookCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessionDirectory = library.root.appending(path: "CalibreSessions", directoryHint: .isDirectory)
        let managedFiles = ManagedFileCoordinator()
        let service = makeService(
            library: library,
            saveAdapter: .live,
            managedFiles: managedFiles,
            sessionDirectory: sessionDirectory
        )

        service.importLibrary(at: fixture.root)
        await service.waitForCurrentImport()
        #expect(service.result?.imported == 1)

        let bookDirectory = fixture.root.appending(
            path: "Author/Book 1",
            directoryHint: .isDirectory
        )
        try Data("pdf-content".utf8).write(to: bookDirectory.appending(path: "book-pdf.pdf"))
        try CalibreSessionFixture.execute(
            "INSERT INTO data VALUES (100,1,'PDF',11,'book-pdf');",
            in: fixture.database
        )

        service.importLibrary(at: fixture.root)
        await service.waitForCurrentImport()

        let summary = try #require(service.result)
        let book = try #require(library.context.allBooks().first)
        #expect(summary.phase == .completed)
        #expect(summary.imported == 0)
        #expect(summary.merged == 1)
        #expect(summary.skippedExact == 0)
        #expect(library.context.allBooks().count == 1)
        #expect(Set(book.assets.map(\.format)) == ["EPUB", "PDF"])
    }

    @Test func sameTitleAndAuthorWithAnotherISBNCreatesAnotherEdition() async throws {
        let library = try await TestLibrary()
        let fixture = try CalibreSessionFixture.make(bookCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessionDirectory = library.root.appending(path: "CalibreSessions", directoryHint: .isDirectory)
        let managedFiles = ManagedFileCoordinator()
        let service = makeService(
            library: library,
            saveAdapter: .live,
            managedFiles: managedFiles,
            sessionDirectory: sessionDirectory
        )

        service.importLibrary(at: fixture.root)
        await service.waitForCurrentImport()
        #expect(service.result?.imported == 1)

        let source = fixture.root.appending(path: "Author/Book 1/book.epub")
        try Data("another-edition".utf8).write(to: source, options: .atomic)
        try CalibreSessionFixture.execute(
            "UPDATE identifiers SET val='9789999999999' WHERE book=1 AND type='isbn';",
            in: fixture.database
        )

        service.importLibrary(at: fixture.root)
        await service.waitForCurrentImport()

        let summary = try #require(service.result)
        let books = library.context.allBooks()
        #expect(summary.phase == .completed)
        #expect(summary.imported == 1)
        #expect(summary.merged == 0)
        #expect(summary.skippedExact == 0)
        #expect(books.count == 2)
        #expect(Set(books.compactMap { $0.work?.uuid }).count == 1)
        #expect(Set(books.compactMap(\.isbn)).count == 2)
    }

    private func makeService(
        library: TestLibrary,
        saveAdapter: CatalogSaveAdapter,
        managedFiles: ManagedFileCoordinator,
        sessionDirectory: URL
    ) -> CalibreImportService {
        let settings = AppSettings(secretStore: VolatileSecretStore())
        let toasts = ToastCenter()
        let mutations = CatalogMutationService(
            modelContext: library.context,
            saveAdapter: saveAdapter,
            managedFiles: managedFiles
        )
        let metadata = MetadataService(
            modelContext: library.context,
            settings: settings,
            mutations: mutations
        )
        let wishlist = WishlistService(modelContext: library.context, toasts: toasts)
        return CalibreImportService(
            modelContext: library.context,
            settings: settings,
            metadata: metadata,
            wishlist: wishlist,
            toasts: toasts,
            mutations: mutations,
            managedFiles: managedFiles,
            sessionDirectory: sessionDirectory,
            chunkSize: 1,
            maximumConcurrentInspections: 2
        )
    }
}

private enum CalibreSessionFixture {
    static func execute(_ statement: String, in database: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(database.path(percentEncoded: false), &db) == SQLITE_OK,
              let db else { throw CalibreImportError.cannotOpen }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw CalibreImportError.stepFailed(
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    static func make(bookCount: Int) throws -> (root: URL, database: URL) {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "CalibreSessionFixture-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appending(path: "metadata.db")
        var db: OpaquePointer?
        guard sqlite3_open(database.path(percentEncoded: false), &db) == SQLITE_OK,
              let db else { throw CalibreImportError.cannotOpen }
        defer { sqlite3_close(db) }

        let schema = """
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
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw CalibreImportError.stepFailed(
                code: sqlite3_errcode(db),
                message: String(cString: sqlite3_errmsg(db))
            )
        }

        for index in 1...bookCount {
            let directoryName = "Author/Book \(index)"
            let directory = root.appending(path: directoryName, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("book-content-\(index)".utf8).write(to: directory.appending(path: "book.epub"))
            // Deliberately invalid cover data verifies that a cover decode failure
            // never leaves a half-committed catalog mutation.
            try Data("not-an-image".utf8).write(to: directory.appending(path: "cover.jpg"))
            let statements = """
            INSERT INTO books VALUES (\(index),'Book \(index)',1.0,'\(directoryName)','2024-01-01','2024-01-01 00:00:00+00:00','Author, Ada');
            INSERT INTO authors VALUES (\(index),'Ada Author','Author, Ada');
            INSERT INTO books_authors_link VALUES (\(index),\(index),\(index));
            INSERT INTO identifiers VALUES (\(index),\(index),'isbn','978000000000\(index)');
            INSERT INTO data VALUES (\(index),\(index),'EPUB',16,'book');
            """
            guard sqlite3_exec(db, statements, nil, nil, nil) == SQLITE_OK else {
                throw CalibreImportError.stepFailed(
                    code: sqlite3_errcode(db),
                    message: String(cString: sqlite3_errmsg(db))
                )
            }
        }
        return (root, database)
    }
}
