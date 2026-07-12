import Testing
import Foundation
@testable import Winston

// MARK: - Filename cleaning

private let messyNames: [String] = [
    "",
    "   ",
    "\t\n  ",
    "2021",
    "1999 2008 2015",
    "dracula",
    "DRACULA",
    "The Lost City",
    "war_and_peace",
    "a-b-c-d",
    "Matilda 4dc9d7f7b09df1246375300fef5fd094 2019",
    "Warrior_Princess-Assassin -- Anna's Archive",
    "libgen z library annas archive",
    "\u{1F4DA} Emoji Title \u{1F4DA}",
    "Ünîcödé Áccénts",
    String(repeating: "word ", count: 400),
    "   leading and trailing   ",
    "MiXeD CaSe StAyS",
]

struct FilenameCleaningTests {

    @Test(arguments: messyNames)
    func neverReturnsEmpty(_ input: String) {
        #expect(!Book.cleanFilename(input).isEmpty)
    }

    @Test(arguments: messyNames)
    func stripsUnderscores(_ input: String) {
        #expect(!Book.cleanFilename(input).contains("_"))
    }

    @Test(arguments: messyNames)
    func collapsesWhitespace(_ input: String) {
        #expect(!Book.cleanFilename(input).contains("  "))
    }

    @Test(arguments: messyNames)
    func hasNoLeadingOrTrailingWhitespace(_ input: String) {
        let result = Book.cleanFilename(input)
        #expect(result == result.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test(arguments: messyNames)
    func isIdempotent(_ input: String) {
        let once = Book.cleanFilename(input)
        #expect(Book.cleanFilename(once) == once)
    }

    @Test(arguments: ["", "   ", "\t", "\n", "2021", "2008", "libgen z library"])
    func purelyNoiseFallsBackToUnknown(_ input: String) {
        #expect(Book.cleanFilename(input) == "Unknown")
    }

    @Test
    func stripsLongHexHashes() {
        let cleaned = Book.cleanFilename("Title 4dc9d7f7b09df1246375300fef5fd094 More")
        #expect(!cleaned.lowercased().contains("4dc9d7f7"))
        #expect(cleaned.contains("Title"))
    }

    @Test(arguments: ["anna's archive", "annas archive", "libgen", "z library", "z lib"])
    func stripsKnownNoiseTokens(_ token: String) {
        let cleaned = Book.cleanFilename("Real Title \(token)")
        #expect(!cleaned.localizedCaseInsensitiveContains(token))
    }
}

// MARK: - Book model

struct BookModelTests {

    private func makeBook(original: String) -> Book {
        Book(fileName: "abc.epub", originalFileName: original)
    }

    @Test(arguments: ["", "   ", "\t\n"])
    func blankTitleFallsBackToFilename(_ blank: String) {
        let book = makeBook(original: "the_secret_garden.epub")
        book.title = blank
        #expect(book.displayTitle == "The Secret Garden")
    }

    @Test(arguments: ["Real Title", "A", "Война и мир"])
    func presentTitleWins(_ title: String) {
        let book = makeBook(original: "whatever.epub")
        book.title = title
        #expect(book.displayTitle == title)
    }

    @Test(arguments: ["", "   ", "\t"])
    func blankAuthorIsNil(_ blank: String) {
        let book = makeBook(original: "x.epub")
        book.author = blank
        #expect(book.displayAuthor == nil)
    }

    @Test(arguments: [" Ursula K. Le Guin ", "Asimov", "  trailing  "])
    func presentAuthorIsTrimmed(_ author: String) {
        let book = makeBook(original: "x.epub")
        book.author = author
        #expect(book.displayAuthor == author.trimmingCharacters(in: .whitespaces))
    }

    @Test(arguments: zip(
        ["book.epub", "thing.AZW3", "no-extension", "a.b.pdf"],
        ["EPUB", "AZW3", "", "PDF"]
    ))
    func formatComesFromStoredFileName(_ fileName: String, _ expected: String) {
        let book = Book(fileName: fileName, originalFileName: "x")
        #expect(book.format == expected)
    }

    @Test(arguments: zip([0 as Int64, 1024, 1_500_000], [true, true, true]))
    func fileSizeDisplayReflectsCachedBytes(_ bytes: Int64, _ hasValue: Bool) {
        let book = Book(fileName: "x.epub", originalFileName: "x.epub")
        book.fileSizeBytes = bytes
        if bytes == 0 {
            #expect(book.fileSizeDisplay == "\u{2014}")
        } else {
            #expect(book.fileSizeDisplay != "\u{2014}")
        }
    }

    @Test
    func deviceMatchKeyIsExtensionInsensitive() {
        let book = Book(fileName: "u.azw3", originalFileName: "My Book.epub")
        #expect(book.deviceMatchKey == "my book")
    }
}

// MARK: - Device book

struct DeviceBookTests {

    @Test
    func identityDistinguishesTransports() {
        let mtp = DeviceBook(mtpItemID: 42, path: nil, fileName: "a.epub", sizeBytes: 1)
        let fs = DeviceBook(mtpItemID: nil, path: "/Volumes/Kindle/documents/a.epub", fileName: "a.epub", sizeBytes: 1)
        #expect(mtp.id != fs.id)
    }

    @Test(arguments: zip(
        ["war_and_peace.azw3", "the-hobbit.mobi", "plain.pdf"],
        ["War And Peace", "The Hobbit", "Plain"]
    ))
    func displayNameIsCleaned(_ fileName: String, _ expected: String) {
        let book = DeviceBook(mtpItemID: 1, path: nil, fileName: fileName, sizeBytes: 1)
        #expect(book.displayName == expected)
    }

    @Test(arguments: zip(
        ["book.epub", "x.AZW3", "y.pdf"],
        ["EPUB", "AZW3", "PDF"]
    ))
    func formatIsUppercased(_ fileName: String, _ expected: String) {
        let book = DeviceBook(mtpItemID: 1, path: nil, fileName: fileName, sizeBytes: 1)
        #expect(book.format == expected)
    }
}

// MARK: - Device table query

struct DeviceTableQueryTests {

    private func row(_ fileName: String, author: String? = nil, daysAgo: Double? = nil) -> DeviceBookRow {
        DeviceBookRow(
            book: DeviceBook(
                mtpItemID: nil,
                path: "/Volumes/Kindle/documents/\(fileName)",
                fileName: fileName,
                sizeBytes: 1,
                modifiedDate: daysAgo.map { Date(timeIntervalSinceNow: -$0 * 86_400) }
            ),
            author: author
        )
    }

    @Test
    func defaultOrderIsRecentFirstWithUndatedLast() {
        let rows = [
            row("old.mobi", daysAgo: 30),
            row("undated.mobi"),
            row("new.mobi", daysAgo: 1),
        ]
        let sorted = DeviceTableQuery.apply(to: rows, searchText: "", author: nil, sort: DeviceTableQuery.recentFirst)
        #expect(sorted.map(\.book.fileName) == ["new.mobi", "old.mobi", "undated.mobi"])
    }

    @Test
    func searchMatchesTitleAuthorAndFileName() {
        let rows = [
            row("dune.mobi", author: "Frank Herbert"),
            row("hobbit.mobi", author: "J. R. R. Tolkien"),
        ]
        func matches(_ query: String) -> [String] {
            DeviceTableQuery.apply(to: rows, searchText: query, author: nil, sort: [])
                .map(\.book.fileName)
        }
        #expect(matches("dune") == ["dune.mobi"])
        #expect(matches("tolkien") == ["hobbit.mobi"])
        #expect(matches("hobbit.mobi") == ["hobbit.mobi"])
        #expect(matches("  ") == ["dune.mobi", "hobbit.mobi"])
    }

    @Test
    func authorFilterKeepsOnlyThatAuthor() {
        let rows = [
            row("a.mobi", author: "Frank Herbert"),
            row("b.mobi", author: "Ursula K. Le Guin"),
            row("c.mobi"),
        ]
        let filtered = DeviceTableQuery.apply(to: rows, searchText: "", author: "Frank Herbert", sort: [])
        #expect(filtered.map(\.book.fileName) == ["a.mobi"])
    }

    @Test
    func authorsAreDistinctAndSorted() {
        let rows = [
            row("a.mobi", author: "Ursula K. Le Guin"),
            row("b.mobi", author: "Frank Herbert"),
            row("c.mobi", author: "Frank Herbert"),
            row("d.mobi"),
        ]
        #expect(DeviceTableQuery.authors(in: rows) == ["Frank Herbert", "Ursula K. Le Guin"])
    }

    @Test
    func rowsMatchLibraryAuthorsByMatchKey() {
        let books = [
            DeviceBook(mtpItemID: nil, path: nil, fileName: "My Book.azw3", sizeBytes: 1),
            DeviceBook(mtpItemID: nil, path: nil, fileName: "unknown.mobi", sizeBytes: 1),
        ]
        let rows = DeviceTableQuery.rows(books: books, authorByMatchKey: ["my book": "Frank Herbert"])
        #expect(rows.map(\.author) == ["Frank Herbert", nil])
    }
}

// MARK: - Mass storage sidecar cleanup

struct SidecarCleanupTests {

    private func createFile(at url: URL) {
        let fd = open(url.path(percentEncoded: false), O_CREAT | O_WRONLY, 0o644)
        #expect(fd >= 0)
        _ = "x".withCString { write(fd, $0, 1) }
        close(fd)
    }

    private func exists(_ url: URL) -> Bool {
        access(url.path(percentEncoded: false), F_OK) == 0
    }

    @Test
    func removesOnlyAppleDoubleFiles() async throws {
        let volume = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let documents = volume.appending(path: "documents")
        let nested = documents.appending(path: "Author, Some")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: volume) }

        let keep = documents.appending(path: "book.mobi")
        let sidecarTop = documents.appending(path: "._book.mobi")
        let sidecarNested = nested.appending(path: "._other.azw3")
        let sidecarFolder = documents.appending(path: "._Author, Some")
        for url in [keep, sidecarTop, sidecarNested, sidecarFolder] {
            createFile(at: url)
        }

        let connection = MassStorageDeviceConnection(volumeURL: volume)
        let removed = try await connection.removeAppleDoubleSidecars()

        #expect(removed == 3)
        #expect(exists(keep))
        for gone in [sidecarTop, sidecarNested, sidecarFolder] {
            #expect(!exists(gone))
        }
    }
}

// MARK: - Converter format policy

struct ConverterPolicyTests {

    @Test(arguments: ["azw", "azw3", "AZW3", "mobi", "MOBI", "pdf", "txt", "kfx"])
    func kindleNativeFormatsAreNotConverted(_ format: String) {
        #expect(!EbookConverter.needsConversion(format: format))
    }

    @Test(arguments: ["epub", "EPUB", "fb2", "cbz", "docx", "rtf", ""])
    func nonNativeFormatsNeedConversion(_ format: String) {
        #expect(EbookConverter.needsConversion(format: format))
    }
}

// MARK: - Binary readers

struct BinaryReadingTests {

    @Test
    func readsBigEndianValues() {
        let data = Data([0x00, 0x01, 0x01, 0x00, 0xFF, 0xFF])
        #expect(data.readUInt16BE(at: 0) == 1)
        #expect(data.readUInt32BE(at: 0) == 0x00010100)
        #expect(data.readUInt16BE(at: 4) == 0xFFFF)
    }

    @Test(arguments: [2, 3, 5, 100])
    func outOfBoundsOffsetsReturnZero(_ offset: Int) {
        let data = Data([0x01, 0x02])
        #expect(data.readUInt16BE(at: offset) == 0)
        #expect(data.readUInt32BE(at: offset) == 0)
    }

    @Test
    func shortBufferNeverTraps() {
        let data = Data([0xAB])
        #expect(data.readUInt16BE(at: 0) == 0)
        #expect(data.readUInt32BE(at: 0) == 0)
        #expect(data.readUInt32BE(at: 10) == 0)
    }
}

// MARK: - MOBI identifiers

struct KindleClippingsTests {

    private let sample = """
    Queens of the Crusades (Alison Weir)
    - Your Highlight on page 12 | location 123-125 | Added on Monday, January 1, 2024 10:00:00 AM

    Eleanor of Aquitaine was remarkable.
    ==========
    Queens of the Crusades (Alison Weir)
    - Your Note on page 12 | location 130 | Added on Monday, January 1, 2024 10:01:00 AM

    Remember this passage.
    ==========
    Some Other Book (Jane Doe)
    - Your Bookmark on page 5 | location 50 | Added on Monday, January 1, 2024 10:02:00 AM

    ==========
    """

    @Test func parsesAllEntries() {
        #expect(KindleClippings.parse(sample).count == 3)
    }

    @Test func splitsTitleAndAuthor() {
        let first = KindleClippings.parse(sample)[0]
        #expect(first.title == "Queens of the Crusades")
        #expect(first.author == "Alison Weir")
        #expect(first.text == "Eleanor of Aquitaine was remarkable.")
    }

    @Test func distinguishesHighlightNoteBookmark() {
        let clips = KindleClippings.parse(sample)
        #expect(clips[0].isNote == false && clips[0].isBookmark == false)
        #expect(clips[1].isNote == true)
        #expect(clips[2].isBookmark == true)
    }

    @Test func extractsLocation() {
        #expect(KindleClippings.parse(sample)[0].location == "123-125")
    }

    @Test func emptyInputYieldsNothing() {
        #expect(KindleClippings.parse("").isEmpty)
        #expect(KindleClippings.parse("\n\n").isEmpty)
    }
}

struct MOBIIdentifierTests {

    private func writeTemp(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    @Test
    func emptyFileYieldsNoIdentifiers() throws {
        let url = try writeTemp([])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MOBIIdentifiers.read(from: url) == MOBIIdentifiers.Identifiers())
    }

    @Test
    func nonMobiGarbageYieldsNoIdentifiers() throws {
        let url = try writeTemp(Array(repeating: 0x7F, count: 512))
        defer { try? FileManager.default.removeItem(at: url) }
        let ids = MOBIIdentifiers.read(from: url)
        #expect(ids.asin == nil)
        #expect(ids.cdeType == nil)
    }

    @Test
    func missingFileYieldsNoIdentifiers() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).azw3")
        #expect(MOBIIdentifiers.read(from: url) == MOBIIdentifiers.Identifiers())
    }
}

// MARK: - HTML description cleanup

struct HTMLTextTests {

    @Test func decodesNamedEntities() {
        #expect("she&rsquo;s home".strippedHTML == "she\u{2019}s home")
        #expect("A &amp; B".strippedHTML == "A & B")
        #expect("1855&mdash;cold".strippedHTML == "1855\u{2014}cold")
    }

    @Test func decodesNumericAndHexEntities() {
        #expect("don&#39;t".strippedHTML == "don't")
        #expect("it&#8217;s".strippedHTML == "it\u{2019}s")
        #expect("it&#x2019;s".strippedHTML == "it\u{2019}s")
    }

    @Test func stripsTagsAndKeepsParagraphBreaks() {
        #expect("<b>Bold</b> and <i>italic</i>".strippedHTML == "Bold and italic")
        #expect("<p>One</p><p>Two</p>".strippedHTML == "One\n\nTwo")
    }

    @Test func doesNotDoubleDecode() {
        #expect("&amp;lt;".strippedHTML == "&lt;")
    }

    @Test func leavesPlainTextAndStrayAmpersandsAlone() {
        #expect("Fish & chips for 5".strippedHTML == "Fish & chips for 5")
        #expect("plain description".strippedHTML == "plain description")
    }
}
