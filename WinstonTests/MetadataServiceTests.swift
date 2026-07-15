import Testing
import Foundation
import SwiftData
@testable import Winston

@MainActor
@Suite(.serialized)
struct MetadataServiceTests {

    private func makeService(in lib: TestLibrary, online: any OnlineMetadataFetching) -> MetadataService {
        MetadataService(modelContext: lib.context, settings: AppSettings(), online: online)
    }

    @Test func enrichFillsOnlyEmptyFieldsAndMarksLookup() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "a.epub", originalFileName: "Some Novel.epub")
        book.title = "User Title"
        lib.context.insert(book)
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.title = "Online Title"
        fetched.authors = ["Jane Doe"]
        fetched.bookDescription = "An online description."
        fetched.ratingsAverage = 4.2
        fetched.ratingsCount = 12
        fetched.ratingsSource = "Google Books"

        let service = makeService(in: lib, online: FakeOnlineClient(result: fetched))
        let matched = await service.performEnrich(book, replaceCover: false)

        #expect(matched)
        #expect(book.title == "User Title")
        #expect(book.author == "Jane Doe")
        #expect(book.bookDescription == "An online description.")
        #expect(book.communityRating == 4.2)
        #expect(book.communityRatingSource == "Google Books")
        #expect(book.onlineLookupAt != nil)
        #expect(book.onlineLookupConfiguration != nil)
    }

    @Test func noMatchOverNetworkMarksLookupSoBackfillStopsRetrying() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "a.epub", originalFileName: "Obscure.epub")
        lib.context.insert(book)
        try lib.context.save()

        let service = makeService(in: lib, online: FakeOnlineClient(result: nil, reachedNetwork: true))
        let matched = await service.performEnrich(book, replaceCover: false)

        #expect(!matched)
        #expect(book.onlineLookupAt != nil)
        #expect(book.onlineLookupConfiguration != nil)
    }

    @Test func enrichFillsWorkCatalogIdentifiersWithoutOverwriting() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "a.epub", originalFileName: "Book.epub")
        let work = Work(title: "Book")
        lib.context.insert(book)
        lib.context.insert(work)
        book.work = work
        try lib.context.save()
        var fetched = FetchedMetadata()
        fetched.title = "Book"
        fetched.openLibraryWorkKey = "/works/OL1W"
        fetched.hardcoverBookID = "12345"
        let service = makeService(in: lib, online: FakeOnlineClient(result: fetched))

        #expect(await service.performEnrich(book, replaceCover: false))
        #expect(work.openLibraryWorkKey == "/works/OL1W")
        #expect(work.hardcoverBookID == "12345")

        work.openLibraryWorkKey = "/works/KEEP"
        fetched.openLibraryWorkKey = "/works/REPLACE"
        _ = await makeService(in: lib, online: FakeOnlineClient(result: fetched))
            .performEnrich(book, replaceCover: false)
        #expect(work.openLibraryWorkKey == "/works/KEEP")
    }

    @Test func offlineLookupLeavesBookUnmarkedForRetry() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "a.epub", originalFileName: "Obscure.epub")
        lib.context.insert(book)
        try lib.context.save()

        let service = makeService(in: lib, online: FakeOnlineClient(result: nil, reachedNetwork: false))
        let matched = await service.performEnrich(book, replaceCover: false)

        #expect(!matched)
        #expect(book.onlineLookupAt == nil)
        #expect(book.onlineLookupConfiguration == nil)
    }

    @Test func enrichDownloadsCoverWhenMissing() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "a.epub", originalFileName: "Covered.epub")
        lib.context.insert(book)
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.title = "Covered"
        fetched.coverURL = URL(string: "https://example.invalid/cover.jpg")
        let online = FakeOnlineClient(result: fetched, coverData: EPUBFixture.jpegData())

        let service = makeService(in: lib, online: online)
        let matched = await service.performEnrich(book, replaceCover: false)

        #expect(matched)
        #expect(CoverStore.load(for: book.uuid) != nil)
        #expect(book.coverVersion == 1)
    }

    @Test func renameTagRewritesEveryBookAndDeduplicates() async throws {
        let lib = try await TestLibrary()
        let a = Book(fileName: "a.epub", originalFileName: "A.epub")
        a.tags = ["scifi", "space"]
        let b = Book(fileName: "b.epub", originalFileName: "B.epub")
        b.tags = ["scifi", "sci-fi"]
        let c = Book(fileName: "c.epub", originalFileName: "C.epub")
        c.tags = ["romance"]
        for book in [a, b, c] { lib.context.insert(book) }
        try lib.context.save()

        let service = makeService(in: lib, online: FakeOnlineClient())
        service.renameTag("scifi", to: "sci-fi")

        #expect(a.tags.sorted() == ["sci-fi", "space"])
        #expect(b.tags == ["sci-fi"])
        #expect(c.tags == ["romance"])
    }

    @Test func renameSeriesAndAuthorTouchOnlyMatchingBooks() async throws {
        let lib = try await TestLibrary()
        let a = Book(fileName: "a.epub", originalFileName: "A.epub")
        a.series = "Old Series"
        a.author = "Old Author"
        let b = Book(fileName: "b.epub", originalFileName: "B.epub")
        b.series = "Other Series"
        b.author = "Other Author"
        for book in [a, b] { lib.context.insert(book) }
        try lib.context.save()

        let service = makeService(in: lib, online: FakeOnlineClient())
        service.renameSeries("Old Series", to: "New Series")
        service.renameAuthor("Old Author", to: "New Author")

        #expect(a.series == "New Series")
        #expect(a.author == "New Author")
        #expect(b.series == "Other Series")
        #expect(b.author == "Other Author")
    }

    @Test func `Applying metadata fixes batches every rename into one save`() async throws {
        let lib = try await TestLibrary()
        let a = Book(fileName: "a.epub", originalFileName: "A.epub")
        a.author = "Herbert, Frank"
        a.series = "Zaklinac"
        let b = Book(fileName: "b.epub", originalFileName: "B.epub")
        b.author = "Herbert, Frank"
        b.series = "Zaklínač"
        let c = Book(fileName: "c.epub", originalFileName: "Orel a lev 02 - Dvoji trun.epub")
        c.title = "Dvojí trůn"
        for book in [a, b, c] { lib.context.insert(book) }
        try lib.context.save()

        let service = makeService(in: lib, online: FakeOnlineClient())
        let revision = LibraryMutationLog.shared.revision
        service.applyMetadataFixes([
            MetadataFix(
                kind: .author,
                original: "Herbert, Frank",
                suggestion: "Frank Herbert",
                bookCount: 2
            ),
            MetadataFix(
                kind: .series,
                original: "Zaklinac",
                suggestion: "Zaklínač",
                bookCount: 1
            ),
            MetadataFix(
                kind: .seriesAssignment,
                original: "Dvojí trůn",
                suggestion: "Orel a lev",
                bookCount: 1,
                bookID: c.uuid,
                seriesIndex: "2"
            ),
        ])

        #expect(LibraryMutationLog.shared.revision == revision + 1)
        #expect(a.author == "Frank Herbert")
        #expect(b.author == "Frank Herbert")
        #expect(a.series == "Zaklínač")
        #expect(b.series == "Zaklínač")
        #expect(c.series == "Orel a lev")
        #expect(c.seriesIndex == "2")
    }

    @Test func deleteTagRemovesItEverywhere() async throws {
        let lib = try await TestLibrary()
        let a = Book(fileName: "a.epub", originalFileName: "A.epub")
        a.tags = ["drop", "keep"]
        lib.context.insert(a)
        try lib.context.save()

        let service = makeService(in: lib, online: FakeOnlineClient())
        service.deleteTag("drop")

        #expect(a.tags == ["keep"])
    }

    @Test func concurrentLookupsKeepNetworkReachabilityWithTheirOwnRequest() async throws {
        let lib = try await TestLibrary()
        let offline = Book(fileName: "offline.epub", originalFileName: "Offline.epub")
        let online = Book(fileName: "online.epub", originalFileName: "Online.epub")
        lib.context.insert(offline)
        lib.context.insert(online)
        try lib.context.save()

        let service = makeService(in: lib, online: ReentrantOnlineClient())
        let offlineTask = Task { @MainActor in
            await service.performEnrich(offline, replaceCover: false)
        }
        let onlineTask = Task { @MainActor in
            await service.performEnrich(online, replaceCover: false)
        }
        _ = await (offlineTask.value, onlineTask.value)

        #expect(offline.onlineLookupAt == nil)
        #expect(online.onlineLookupAt != nil)
    }

    @Test func addingHardcoverTokenBackfillsPreviouslyQueriedMissingRatingOnce() async throws {
        let lib = try await TestLibrary()
        let settings = AppSettings()
        let oldEnabled = settings.onlineMetadataEnabled
        let oldToken = settings.hardcoverToken
        defer {
            settings.onlineMetadataEnabled = oldEnabled
            settings.hardcoverToken = oldToken
        }
        settings.onlineMetadataEnabled = true
        settings.hardcoverToken = "test-token"

        let book = Book(fileName: "rated.epub", originalFileName: "Rated.epub")
        book.bookDescription = "Already present"
        book.onlineLookupAt = .distantPast
        lib.context.insert(book)
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.ratingsAverage = 4.7
        fetched.ratingsCount = 42
        fetched.ratingsSource = "Hardcover"
        let online = FakeOnlineClient(result: fetched)
        let service = MetadataService(modelContext: lib.context, settings: settings, online: online)

        service.backfillMissingOnlineMetadata()
        let deadline = Date.now.addingTimeInterval(2)
        while book.communityRating == nil, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(book.communityRating == 4.7)
        #expect(book.onlineLookupConfiguration?.contains("hardcover:none") == false)
        let callsAfterFirstBackfill = await online.fetchCalls
        service.backfillMissingOnlineMetadata()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await online.fetchCalls == callsAfterFirstBackfill)
    }

    @Test func deletingBookDuringMetadataFetchDiscardsLateResult() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "late.epub", originalFileName: "Late.epub")
        lib.context.insert(book)
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.title = "Should Not Be Applied"
        let online = FetchGateOnlineClient(result: fetched)
        let service = makeService(in: lib, online: online)
        let task = Task { @MainActor in
            await service.performEnrich(book, replaceCover: false)
        }

        await online.waitUntilStarted()
        lib.context.delete(book)
        lib.context.saveQuietly()
        await online.resume()

        #expect(await task.value == false)
        #expect(lib.context.allBooks().isEmpty)
        #expect(service.enrichingUUIDs.isEmpty)
    }

    @Test func deletingBookDuringCoverDownloadLeavesNoLateCover() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "cover.epub", originalFileName: "Cover.epub")
        let uuid = book.uuid
        lib.context.insert(book)
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.title = "Covered"
        fetched.coverURL = URL(string: "https://example.invalid/cover.jpg")
        let online = CoverGateOnlineClient(result: fetched, data: EPUBFixture.jpegData())
        let service = makeService(in: lib, online: online)
        let task = Task { @MainActor in
            await service.performEnrich(book, replaceCover: true)
        }

        await online.waitUntilDownloadStarted()
        lib.context.delete(book)
        lib.context.saveQuietly()
        await online.resumeDownload()

        #expect(await task.value == false)
        #expect(!CoverStore.exists(for: uuid))
        #expect(service.enrichingUUIDs.isEmpty)
    }

    @Test func deletingBookDuringImportAnalysisDiscardsLateMetadata() async throws {
        let lib = try await TestLibrary()
        let settings = AppSettings()
        let oldOnline = settings.onlineMetadataEnabled
        settings.onlineMetadataEnabled = false
        defer { settings.onlineMetadataEnabled = oldOnline }

        let source = lib.root.appending(path: "incoming.epub")
        try Data("partial fixture".utf8).write(to: source)
        let metadata = MetadataService(modelContext: lib.context, settings: settings,
                                       online: FakeOnlineClient())
        let wishlist = WishlistService(modelContext: lib.context, toasts: ToastCenter())
        let gate = ImportAnalysisGate()
        let importer = ImportService(
            modelContext: lib.context,
            settings: settings,
            metadata: metadata,
            wishlist: wishlist,
            toasts: ToastCenter(),
            analyzeBook: { url in await gate.analyze(url) }
        )

        importer.addBooks(from: [source])
        await gate.waitUntilStarted()
        let imported = try #require(lib.context.allBooks().first)
        let fileName = imported.fileName
        let uuid = imported.uuid
        BookFileStore.delete(fileName: fileName)
        CoverStore.delete(for: uuid)
        importer.cancelPending(uuid)
        lib.context.delete(imported)
        lib.context.saveQuietly()
        await gate.resume()

        let deadline = Date.now.addingTimeInterval(1)
        while importer.pendingMetadataUUIDs.contains(uuid), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(lib.context.allBooks().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: BookFileStore.url(for: fileName).path(percentEncoded: false)
        ))
        #expect(!importer.pendingMetadataUUIDs.contains(uuid))
    }

    @Test func importRefreshesWorkIdentityAfterOnlineEnrichment() async throws {
        let lib = try await TestLibrary()
        let settings = AppSettings()
        let oldOnline = settings.onlineMetadataEnabled
        settings.onlineMetadataEnabled = true
        defer { settings.onlineMetadataEnabled = oldOnline }
        let source = lib.root.appending(path: "metadata-less.pdf")
        try Data("pdf placeholder".utf8).write(to: source)
        var fetched = FetchedMetadata()
        fetched.title = "Online Canonical Title"
        fetched.authors = ["Online Author"]
        let metadata = MetadataService(
            modelContext: lib.context,
            settings: settings,
            online: FakeOnlineClient(result: fetched)
        )
        let importer = ImportService(
            modelContext: lib.context,
            settings: settings,
            metadata: metadata,
            wishlist: WishlistService(modelContext: lib.context, toasts: ToastCenter()),
            toasts: ToastCenter(),
            analyzeBook: { _ in ImportBookAnalysis(metadata: BookMetadata(), drmProtected: false) }
        )

        importer.addBooks(from: [source])
        let deadline = Date.now.addingTimeInterval(2)
        while (lib.context.allBooks().isEmpty || importer.isExtracting), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let book = try #require(lib.context.allBooks().first)

        #expect(book.title == "Online Canonical Title")
        #expect(book.work?.title == "Online Canonical Title")
        #expect(book.work?.author == "Online Author")
    }
}

private actor FakeOnlineClient: OnlineMetadataFetching {
    private let result: FetchedMetadata?
    private let reachedNetwork: Bool
    private let coverData: Data?
    private(set) var fetchCalls = 0

    init(result: FetchedMetadata? = nil, reachedNetwork: Bool = true, coverData: Data? = nil) {
        self.result = result
        self.reachedNetwork = reachedNetwork
        self.coverData = coverData
    }

    func fetch(isbn: String?, title: String, author: String?, language: MetadataLanguage,
               hardcoverToken: String?) async -> OnlineMetadataFetchResult {
        fetchCalls += 1
        return OnlineMetadataFetchResult(metadata: result, reachedNetwork: reachedNetwork)
    }

    func downloadCover(_ url: URL) async -> Data? { coverData }
}

private actor ReentrantOnlineClient: OnlineMetadataFetching {
    func fetch(isbn: String?, title: String, author: String?, language: MetadataLanguage,
               hardcoverToken: String?) async -> OnlineMetadataFetchResult {
        if title == "Offline" {
            try? await Task.sleep(for: .milliseconds(80))
            return OnlineMetadataFetchResult(metadata: nil, reachedNetwork: false)
        }
        try? await Task.sleep(for: .milliseconds(10))
        return OnlineMetadataFetchResult(metadata: nil, reachedNetwork: true)
    }

    func downloadCover(_ url: URL) async -> Data? { nil }
}

private actor FetchGateOnlineClient: OnlineMetadataFetching {
    private let outcome: OnlineMetadataFetchResult
    private var continuation: CheckedContinuation<OnlineMetadataFetchResult, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(result: FetchedMetadata?) {
        outcome = OnlineMetadataFetchResult(metadata: result, reachedNetwork: true)
    }

    func fetch(isbn: String?, title: String, author: String?, language: MetadataLanguage,
               hardcoverToken: String?) async -> OnlineMetadataFetchResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func downloadCover(_ url: URL) async -> Data? { nil }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

private actor CoverGateOnlineClient: OnlineMetadataFetching {
    private let result: FetchedMetadata
    private let data: Data
    private var continuation: CheckedContinuation<Data?, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(result: FetchedMetadata, data: Data) {
        self.result = result
        self.data = data
    }

    func fetch(isbn: String?, title: String, author: String?, language: MetadataLanguage,
               hardcoverToken: String?) async -> OnlineMetadataFetchResult {
        OnlineMetadataFetchResult(metadata: result, reachedNetwork: true)
    }

    func downloadCover(_ url: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitUntilDownloadStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resumeDownload() {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

private actor ImportAnalysisGate {
    private var continuation: CheckedContinuation<ImportBookAnalysis, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func analyze(_ url: URL) async -> ImportBookAnalysis {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        var metadata = BookMetadata()
        metadata.title = "Late Metadata"
        continuation?.resume(returning: ImportBookAnalysis(metadata: metadata, drmProtected: false))
        continuation = nil
    }
}
