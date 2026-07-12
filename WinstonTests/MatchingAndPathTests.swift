import Testing
import Foundation
@testable import Winston

// MARK: - Title matching

struct TitleMatcherTests {

    @Test func nilCandidateNeverMatches() {
        #expect(!TitleMatcher.matches(nil, "Anything"))
    }

    @Test(arguments: [
        ("The Hobbit", "The Hobbit"),
        ("The Hobbit: There and Back Again", "The Hobbit"),
        ("the hobbit", "The Hobbit"),
        ("Válka a mír", "Valka a mir"),
        ("Gone Girl Story", "Gone Girl Tale"),
        ("Война и мир", "Война и мир"),
        ("Οδύσσεια", "Οδύσσεια"),
        ("吾輩は猫である", "吾輩は猫である"),
    ])
    func acceptsPlausibleMatches(_ a: String, _ b: String) {
        #expect(TitleMatcher.matches(a, b))
    }

    @Test(arguments: [
        ("Brave New World", "The Hobbit"),
        ("The Cat", "The Dog"),
        ("!!!", "A Real Title"),
    ])
    func rejectsDifferentTitles(_ a: String, _ b: String) {
        #expect(!TitleMatcher.matches(a, b))
    }

    @Test(arguments: zip(
        ["Héllo, World!", "  multiple   spaces  ", "ABC123", "The Lord of the Rings"],
        ["hello world", "multiple spaces", "abc123", "the lord of the rings"]
    ))
    func normalizeStripsDiacriticsPunctuationAndSpacing(_ input: String, _ expected: String) {
        #expect(TitleMatcher.normalize(input) == expected)
    }

    @Test func unicodeMatchKeysStayNonemptyAndDistinct() {
        let cyrillic = "Война и мир".normalizedMatchKey
        let greek = "Οδύσσεια".normalizedMatchKey
        let japanese = "吾輩は猫である".normalizedMatchKey
        #expect(!cyrillic.isEmpty)
        #expect(!greek.isEmpty)
        #expect(!japanese.isEmpty)
        #expect(Set([cyrillic, greek, japanese]).count == 3)
    }
}

// MARK: - EPUB href resolution

struct CoverPathTests {

    @Test(arguments: zip(
        [("cover.jpg", ""), ("cover.jpg", "."), ("cover.jpg", "OEBPS"),
         ("./cover.jpg", "OEBPS"), ("../images/cover.jpg", "OEBPS/text"),
         ("my%20cover.jpg", "OEBPS"), ("../../x.jpg", "a")],
        ["cover.jpg", "cover.jpg", "OEBPS/cover.jpg",
         "OEBPS/cover.jpg", "OEBPS/images/cover.jpg",
         "OEBPS/my cover.jpg", "x.jpg"]
    ))
    func resolvesRelativeHrefs(_ input: (href: String, dir: String), _ expected: String) {
        #expect(CoverExtractor.resolve(input.href, dir: input.dir) == expected)
    }
}

// MARK: - Managed file replacement

@MainActor
struct BookFileStoreTests {

    @Test func pathGettersDoNotCreateDirectories() async throws {
        let library = try await TestLibrary()
        let untouchedRoot = library.root.appending(path: "pure-paths", directoryHint: .isDirectory)
        AppPaths.rootDirectory = untouchedRoot

        _ = AppPaths.appSupportDirectory
        _ = AppPaths.booksDirectory
        _ = AppPaths.coversDirectory
        _ = AppPaths.pluginsDirectory
        _ = AppPaths.pluginDataDirectory(for: "cz.test")

        #expect(!FileManager.default.fileExists(atPath: untouchedRoot.path(percentEncoded: false)))

        try AppPaths.ensureRequiredDirectories()
        #expect(FileManager.default.fileExists(atPath: AppPaths.booksDirectory.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: AppPaths.coversDirectory.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: AppPaths.pluginsDirectory.path(percentEncoded: false)))
        _ = library
    }

    @Test func coverExistenceCheckDoesNotRequireDecodableJPEG() async throws {
        let library = try await TestLibrary()
        let uuid = UUID()
        let cover = AppPaths.coversDirectory.appending(path: "\(uuid.uuidString).jpg")
        try Data("not a jpeg".utf8).write(to: cover)

        #expect(CoverStore.exists(for: uuid))
        #expect(CoverStore.load(for: uuid) == nil)
        _ = library
    }

    @Test func failedReplacementPreservesExistingManagedFile() async throws {
        let library = try await TestLibrary()
        let uuid = UUID()
        let destination = BookFileStore.url(for: "\(uuid.uuidString).epub")
        try Data("original".utf8).write(to: destination)
        let missingSource = library.root.appending(path: "missing.epub")

        do {
            _ = try BookFileStore.importCopy(of: missingSource, uuid: uuid)
            Issue.record("replacement from a missing source should fail")
        } catch { }

        #expect(try Data(contentsOf: destination) == Data("original".utf8))
        _ = library
    }

    @Test func selectingManagedFileItselfIsANoOp() async throws {
        let library = try await TestLibrary()
        let uuid = UUID()
        let destination = BookFileStore.url(for: "\(uuid.uuidString).epub")
        try Data("kept".utf8).write(to: destination)

        let fileName = try BookFileStore.importCopy(of: destination, uuid: uuid)

        #expect(fileName == "\(uuid.uuidString).epub")
        #expect(try Data(contentsOf: destination) == Data("kept".utf8))
        _ = library
    }

    @Test func successfulReplacementPublishesTheCompleteNewFile() async throws {
        let library = try await TestLibrary()
        let uuid = UUID()
        let destination = BookFileStore.url(for: "\(uuid.uuidString).epub")
        let replacement = library.root.appending(path: "replacement.epub")
        try Data("old".utf8).write(to: destination)
        try Data("complete replacement".utf8).write(to: replacement)

        _ = try BookFileStore.importCopy(of: replacement, uuid: uuid)

        #expect(try Data(contentsOf: destination) == Data("complete replacement".utf8))
        #expect(try Data(contentsOf: replacement) == Data("complete replacement".utf8))
        _ = library
    }
}

// MARK: - Highlight matching

struct HighlightMatchingTests {
    private func clipping(title: String, text: String, location: String? = nil,
                          isNote: Bool = false, isBookmark: Bool = false) -> KindleClippings.Clipping {
        KindleClippings.Clipping(
            title: title, author: nil, isNote: isNote, isBookmark: isBookmark,
            location: location, addedDate: nil, text: text
        )
    }

    @Test func matchingNormalizesOnceAndFiltersExistingAndBatchDuplicates() async {
        let war = UUID()
        let hobbit = UUID()
        let snapshots = [
            HighlightsService.BookSnapshot(
                uuid: war,
                title: "Война и мир",
                existing: [.init(text: "existing", location: "1")]
            ),
            HighlightsService.BookSnapshot(uuid: hobbit, title: "The Hobbit", existing: [])
        ]
        let clips = [
            clipping(title: "Война и мир", text: "existing", location: "1"),
            clipping(title: "Война и мир", text: "new", location: "2"),
            clipping(title: "Война и мир", text: "new", location: "2"),
            clipping(title: "The Hobbit: An Unexpected Journey", text: "fuzzy"),
            clipping(title: "The Hobbit", text: "bookmark", isBookmark: true)
        ]

        let matches = await HighlightsService.match(clippings: clips, books: snapshots)

        #expect(matches.count == 2)
        #expect(matches[0].bookUUID == war)
        #expect(matches[0].text == "new")
        #expect(matches[1].bookUUID == hobbit)
        #expect(matches[1].text == "fuzzy")
    }
}

// MARK: - Watch folder stability

struct WatchFolderStabilityTests {
    @Test func fileMustRemainUnchangedAcrossTwoRealIntervals() async {
        let tracker = WatchFolderStabilityTracker(minimumInterval: 0.9)
        let url = URL(fileURLWithPath: "/tmp/growing.epub")
        let start = Date(timeIntervalSince1970: 1_000)
        let first = WatchFolderStabilityTracker.Fingerprint(size: 10, modificationDate: start)

        #expect(await tracker.observe([url: first], now: start).ready.isEmpty)
        #expect(await tracker.observe([url: first], now: start.addingTimeInterval(0.1)).ready.isEmpty)
        #expect(await tracker.observe([url: first], now: start.addingTimeInterval(1)).ready.isEmpty)

        let grown = WatchFolderStabilityTracker.Fingerprint(
            size: 20,
            modificationDate: start.addingTimeInterval(1.5)
        )
        #expect(await tracker.observe([url: grown], now: start.addingTimeInterval(2)).ready.isEmpty)
        #expect(await tracker.observe([url: grown], now: start.addingTimeInterval(3)).ready.isEmpty)

        let ready = await tracker.observe([url: grown], now: start.addingTimeInterval(4))
        #expect(ready.ready == [url])
        #expect(!ready.needsPolling)

        let repeated = await tracker.observe([url: grown], now: start.addingTimeInterval(5))
        #expect(repeated.ready.isEmpty)
        #expect(!repeated.needsPolling)
    }

    @Test func zeroLengthFileKeepsPollingAndNeverImports() async {
        let tracker = WatchFolderStabilityTracker(minimumInterval: 0)
        let url = URL(fileURLWithPath: "/tmp/empty.epub")
        let date = Date(timeIntervalSince1970: 2_000)
        let empty = WatchFolderStabilityTracker.Fingerprint(size: 0, modificationDate: date)

        _ = await tracker.observe([url: empty], now: date)
        _ = await tracker.observe([url: empty], now: date)
        let result = await tracker.observe([url: empty], now: date)

        #expect(result.ready.isEmpty)
        #expect(result.needsPolling)
    }
}

// MARK: - Kindle clipping dates

struct KindleClippingsDateTests {

    private func clipping(meta: String) -> String {
        """
        Some Book (An Author)
        \(meta)

        Highlighted text body.
        """
    }

    @Test(arguments: [
        "- Your Highlight | location 1-2 | Added on Monday, January 1, 2024 10:00:00 AM",
        "- Your Highlight | location 1-2 | Added on Monday, 1 January 2024 14:30:00",
        "- Your Highlight | location 1-2 | Added on Monday, January 1, 2024 10:00 AM",
    ])
    func parsesAllThreeDateFormats(_ meta: String) throws {
        let clips = KindleClippings.parse(clipping(meta: meta))
        let date = try #require(clips.first?.addedDate, "date should parse for: \(meta)")
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        #expect(parts.year == 2024)
        #expect(parts.month == 1)
        #expect(parts.day == 1)
    }

    @Test func missingDateIsNil() {
        let clips = KindleClippings.parse(clipping(meta: "- Your Highlight | location 1-2"))
        #expect(clips.first?.addedDate == nil)
    }
}
