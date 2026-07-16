import Testing
import Foundation
import SwiftData
@testable import Winston

@MainActor
@Suite(.serialized)
struct DiscoveryTests {

    private let sample = DiscoveryBook(
        id: "1", title: "Sample", author: "Author",
        coverURL: nil,
        hardcoverURL: URL(string: "https://hardcover.app/books/sample")!,
        rating: 4.0
    )

    private func withOnlineEnabled(_ body: (AppSettings) async -> Void) async {
        let settings = AppSettings()
        let original = UserDefaults.standard.bool(forKey: "onlineMetadataEnabled")
        settings.onlineMetadataEnabled = true
        defer { UserDefaults.standard.set(original, forKey: "onlineMetadataEnabled") }
        await body(settings)
    }

    // MARK: - Gating

    @Test func offlineGateMakesNoServiceCall() async {
        let settings = AppSettings()
        let original = UserDefaults.standard.bool(forKey: "onlineMetadataEnabled")
        settings.onlineMetadataEnabled = false
        defer { UserDefaults.standard.set(original, forKey: "onlineMetadataEnabled") }

        let client = FakeDiscoveryClient(.books([sample]))
        let vm = DiscoveryViewModel(settings: settings, service: client)
        await vm.load()

        #expect(vm.phase == .disabledOnline)
        #expect(await client.calls == 0)
    }

    @Test func missingTokenSurfacesTokenPrompt() async {
        await withOnlineEnabled { settings in
            let vm = DiscoveryViewModel(settings: settings, service: FakeDiscoveryClient(.needsToken))
            await vm.load()
            #expect(vm.phase == .disabledToken)
        }
    }

    // MARK: - Result → phase

    @Test func booksProduceLoadedPhase() async {
        await withOnlineEnabled { settings in
            let vm = DiscoveryViewModel(settings: settings, service: FakeDiscoveryClient(.books([sample])))
            await vm.load()
            #expect(vm.phase == .loaded)
            #expect(vm.visibleBooks == [sample])
        }
    }

    @Test func noBooksProduceEmptyPhase() async {
        await withOnlineEnabled { settings in
            let vm = DiscoveryViewModel(settings: settings, service: FakeDiscoveryClient(.books([])))
            await vm.load()
            #expect(vm.phase == .empty)
        }
    }

    @Test func networkFailureProducesFailedPhase() async {
        await withOnlineEnabled { settings in
            let vm = DiscoveryViewModel(settings: settings, service: FakeDiscoveryClient(.failed))
            await vm.load()
            #expect(vm.phase == .failed)
        }
    }

    @Test func hardcoverAuthStatusesAreDistinguishedFromNetworkFailures() {
        #expect(DiscoveryService.disposition(for: 200) == .success)
        #expect(DiscoveryService.disposition(for: 401) == .unauthorized)
        #expect(DiscoveryService.disposition(for: 403) == .unauthorized)
        #expect(DiscoveryService.disposition(for: 500) == .failure)
    }

    @Test func rapidTokenEditsTriggerOneSettledReload() async {
        await withOnlineEnabled { settings in
            let oldToken = settings.hardcoverToken
            defer { settings.hardcoverToken = oldToken }
            let client = FakeDiscoveryClient(.books([sample]))
            let vm = DiscoveryViewModel(settings: settings, service: client)

            settings.hardcoverToken = "a"
            vm.hardcoverCredentialDidChange(delay: .milliseconds(80))
            settings.hardcoverToken = "ab"
            vm.hardcoverCredentialDidChange(delay: .milliseconds(80))
            settings.hardcoverToken = "abc"
            vm.hardcoverCredentialDidChange(delay: .milliseconds(80))

            let deadline = Date.now.addingTimeInterval(1)
            while Date.now < deadline {
                let calls = await client.calls
                if calls == 1, vm.phase == .loaded { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(await client.calls == 1)
            #expect(vm.phase == .loaded)
            #expect(vm.visibleBooks == [sample])
        }
    }

    // MARK: - Caching

    @Test func reloadingSameGenreDelegatesCachePolicyToService() async {
        await withOnlineEnabled { settings in
            let client = FakeDiscoveryClient(.books([sample]))
            let vm = DiscoveryViewModel(settings: settings, service: client)
            await vm.load()
            await vm.load()
            #expect(await client.calls == 2)
        }
    }

    @Test func returningToAGenreDelegatesCachePolicyToService() async {
        await withOnlineEnabled { settings in
            let client = FakeDiscoveryClient(.books([sample]))
            let vm = DiscoveryViewModel(settings: settings, service: client)
            await vm.load()
            vm.select(DiscoveryGenre.all[1])
            await vm.load()
            vm.select(DiscoveryGenre.default)
            await vm.load()
            #expect(await client.calls == 3)
        }
    }

    @Test func retryClearsCacheAndRefetches() async {
        await withOnlineEnabled { settings in
            let client = FakeDiscoveryClient(.books([sample]))
            let vm = DiscoveryViewModel(settings: settings, service: client)
            await vm.load()
            await vm.retry()
            #expect(await client.calls == 2)
        }
    }

    @Test func catalogIsRevealedInLocalPagesWithoutAnotherServiceCall() async {
        await withOnlineEnabled { settings in
            let books = (0..<55).map { index in
                DiscoveryBook(
                    id: String(index),
                    title: "Book \(index)",
                    author: nil,
                    coverURL: nil,
                    hardcoverURL: URL(string: "https://hardcover.app/books/\(index)")!,
                    rating: nil
                )
            }
            let client = FakeDiscoveryClient(.books(books))
            let viewModel = DiscoveryViewModel(settings: settings, service: client)

            await viewModel.load()
            #expect(viewModel.visibleBooks.count == DiscoveryViewModel.pageSize)
            #expect(viewModel.hasMore)

            await viewModel.loadNextPage()
            #expect(viewModel.visibleBooks.count == DiscoveryViewModel.pageSize * 2)
            await viewModel.loadNextPage()
            #expect(viewModel.visibleBooks == books)
            #expect(!viewModel.hasMore)
            #expect(await client.calls == 1)
        }
    }

    @Test func failedManualRefreshKeepsTheVisibleCatalog() async {
        await withOnlineEnabled { settings in
            let client = SequencedDiscoveryClient([.books([sample]), .failed])
            let viewModel = DiscoveryViewModel(settings: settings, service: client)

            await viewModel.load()
            await viewModel.refresh()

            #expect(viewModel.phase == .loaded)
            #expect(viewModel.visibleBooks == [sample])
            #expect(viewModel.refreshFailed)
            #expect(!viewModel.isRefreshing)
        }
    }

    // MARK: - Wire decoding

    @Test func parseBooksDecodesGraphQLReleaseDate() {
        let json = """
        { "data": { "books": [
            {
                "id": 7, "slug": "already-released", "title": "Already Released",
                "release_date": "2026-07-09", "release_year": 2026
            }
        ] } }
        """.data(using: .utf8)!

        let books = DiscoveryService.parseBooks(json)

        #expect(books?.count == 1)
        #expect(books?.first?.releaseDate == DiscoveryReleaseDate(year: 2026, month: 7, day: 9))
    }

    // MARK: - Release-date filter

    @Test func rankingKeepsCoveredReleasedBooksNewestFirst() {
        func book(
            _ id: String,
            year: Int? = nil,
            date: String? = nil,
            hasCover: Bool = true
        ) -> DiscoveryBook {
            DiscoveryBook(id: id, title: id, author: nil,
                          coverURL: hasCover ? URL(string: "https://img.hardcover.app/\(id).jpg") : nil,
                          hardcoverURL: URL(string: "https://hardcover.app/books/\(id)")!,
                          rating: nil, releaseYear: year,
                          releaseDate: date.flatMap { DiscoveryReleaseDate(iso8601: $0) })
        }
        let now = DateComponents(calendar: .current, year: 2025, month: 6, day: 1).date!
        let kept = DiscoveryService.rankedReleasedBooks(
            [book("pastDate", date: "2025-05-31"),
             book("today", date: "2025-06-01"),
             book("laterThisYear", date: "2025-12-01"),
             book("pastYearOnly", year: 2024),
             book("currentYearOnly", year: 2025),
             book("futureYear", year: 2027),
             book("unknown"),
             book("uncovered", date: "2025-06-01", hasCover: false)],
            now: now
        )
        #expect(kept.map(\.id) == ["today", "pastDate"])
    }

    @Test func newestReleaseQueryHasNoPopularityGateAndRequiresCovers() {
        let query = DiscoveryService.genreQuery
        #expect(!query.contains("users_count"))
        #expect(query.contains("release_date: { _lte: $today }"))
        #expect(query.contains("image_id: { _is_null: false }"))
        #expect(query.contains("release_date: desc_nulls_last"))
        #expect(query.contains("limit: 200"))
    }

    @Test func dailyCacheSurvivesServiceRecreationAndManualRefreshBypassesIt() async throws {
        DiscoveryURLProtocol.prepare()
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "WinstonDiscoveryCache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cacheURL = folder.appending(path: "catalog.json")
        let session = URLSession(configuration: DiscoveryURLProtocol.configuration)

        let first = DiscoveryService(session: session, cacheURL: cacheURL)
        let initial = await first.books(matching: "Science Fiction", token: "test-token")
        guard case .books(let books) = initial else {
            Issue.record("Expected a decoded discovery catalog")
            return
        }
        #expect(books.map(\.id) == ["42"])
        _ = await first.books(matching: "Science Fiction", token: "test-token")

        let relaunched = DiscoveryService(session: session, cacheURL: cacheURL)
        _ = await relaunched.books(matching: "Science Fiction", token: "test-token")
        #expect(DiscoveryURLProtocol.requestCount == 1)

        _ = await relaunched.refreshBooks(matching: "Science Fiction", token: "test-token")
        #expect(DiscoveryURLProtocol.requestCount == 2)
        let cacheText = try String(contentsOf: cacheURL, encoding: .utf8)
        #expect(!cacheText.contains("test-token"))
    }

    @Test func concurrentRefreshesForOneGenreShareARequest() async {
        DiscoveryURLProtocol.prepare(responseDelay: 0.1)
        let cacheURL = FileManager.default.temporaryDirectory
            .appending(path: "WinstonDiscoveryCache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let service = DiscoveryService(
            session: URLSession(configuration: DiscoveryURLProtocol.configuration),
            cacheURL: cacheURL
        )

        async let first = service.refreshBooks(matching: "Fantasy", token: "test-token")
        async let second = service.refreshBooks(matching: "Fantasy", token: "test-token")
        _ = await (first, second)

        #expect(DiscoveryURLProtocol.requestCount == 1)
    }

    @Test func releaseDateRejectsInvalidCalendarDays() {
        #expect(DiscoveryReleaseDate(iso8601: "2025-02-30") == nil)
    }
}

private actor FakeDiscoveryClient: DiscoveryFetching {
    private let result: DiscoveryResult
    private(set) var calls = 0

    init(_ result: DiscoveryResult) { self.result = result }

    func books(matching queryTerm: String, token: String) async -> DiscoveryResult {
        calls += 1
        return result
    }
}

private actor SequencedDiscoveryClient: DiscoveryFetching {
    private var results: [DiscoveryResult]

    init(_ results: [DiscoveryResult]) {
        self.results = results
    }

    func books(matching queryTerm: String, token: String) async -> DiscoveryResult {
        guard !results.isEmpty else { return .failed }
        return results.removeFirst()
    }
}

private final class DiscoveryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedRequestCount = 0
    nonisolated(unsafe) private static var responseDelay: TimeInterval = 0

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocol.self]
        return configuration
    }

    static var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    static func prepare(responseDelay: TimeInterval = 0) {
        lock.withLock {
            storedRequestCount = 0
            self.responseDelay = responseDelay
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let delay = Self.lock.withLock { () -> TimeInterval in
            Self.storedRequestCount += 1
            return Self.responseDelay
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let body = """
        { "data": { "books": [{
          "id": 42,
          "slug": "a-new-release",
          "title": "A New Release",
          "release_date": "2026-07-01",
          "release_year": 2026,
          "image": { "url": "https://img.hardcover.app/42.jpg" },
          "contributions": [{ "author": { "name": "New Author" } }]
        }] } }
        """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - External book website

@Suite
struct ExternalBookSearchURLTests {
    @Test func baseWebsiteURLUsesTheExactRequiredSearchFormat() {
        let url = ExternalBookSearchURL.make(
            websiteURL: "https://catalog.example",
            title: "Krutý princ",
            author: "Holly Black"
        )

        #expect(url?.absoluteString == "https://catalog.example/search?index=&page=1&sort=&display=&q=Krut%C3%BD+princ+Holly+Black")
    }

    @Test func configuredQueryAndFragmentAreReplacedByTheFixedFormat() {
        let url = ExternalBookSearchURL.make(
            websiteURL: "https://catalog.example/search?foo=bar&page=99#books",
            title: "Shatter Me",
            author: "Tahereh Mafi"
        )

        #expect(url?.absoluteString == "https://catalog.example/search?index=&page=1&sort=&display=&q=Shatter+Me+Tahereh+Mafi")
    }

    @Test func existingSampleURLDoesNotDuplicateTheSearchPath() {
        let url = ExternalBookSearchURL.make(
            websiteURL: "https://catalog.example/search?index=&page=1&sort=&display=&q=starside+alex",
            title: "Stephanie Garber",
            author: nil
        )

        #expect(url?.absoluteString == "https://catalog.example/search?index=&page=1&sort=&display=&q=Stephanie+Garber")
    }

    @Test func reservedCharactersCannotEscapeTheQueryValue() {
        let url = ExternalBookSearchURL.make(
            websiteURL: "https://catalog.example",
            title: "A&B + C",
            author: nil
        )

        #expect(url?.absoluteString == "https://catalog.example/search?index=&page=1&sort=&display=&q=A%26B+%2B+C")
    }

    @Test func invalidOrNonWebWebsiteURLsAreRejected() {
        #expect(ExternalBookSearchURL.make(
            websiteURL: "search",
            title: "Book",
            author: nil
        ) == nil)
        #expect(ExternalBookSearchURL.make(
            websiteURL: "file:///tmp",
            title: "Book",
            author: nil
        ) == nil)
    }
}

// MARK: - Wishlist

@MainActor
@Suite
struct WishlistTests {
    private func discoveryBook(
        id: String = "42",
        title: String = "The Fifth Season",
        author: String? = "N. K. Jemisin"
    ) -> DiscoveryBook {
        DiscoveryBook(
            id: id,
            title: title,
            author: author,
            coverURL: URL(string: "https://img.hardcover.app/42.jpg"),
            hardcoverURL: URL(string: "https://hardcover.app/books/the-fifth-season")!,
            rating: 4.3
        )
    }

    @Test func addPersistsItemAndCreatesSystemSmartCollection() throws {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let wishlist = WishlistService(modelContext: context, toasts: ToastCenter())

        #expect(wishlist.add(discoveryBook()))
        #expect(wishlist.count == 1)

        let storedItems = try context.fetch(FetchDescriptor<WishlistItem>())
        let collections = try context.fetch(FetchDescriptor<BookCollection>())
        #expect(storedItems.count == 1)
        #expect(storedItems.first?.title == "The Fifth Season")
        #expect(collections.filter(\.isWishlist).count == 1)
        #expect(collections.first(where: \.isWishlist)?.isSmart == true)
    }

    @Test func normalizedIdentityPreventsDuplicateCatalogEntries() {
        let container = PersistenceController.inMemory()
        let wishlist = WishlistService(
            modelContext: container.mainContext,
            toasts: ToastCenter()
        )

        #expect(wishlist.add(discoveryBook(
            id: "1",
            title: "Válka s Mloky",
            author: "Karel Čapek"
        )))
        #expect(!wishlist.add(discoveryBook(
            id: "2",
            title: "Valka s mloky",
            author: "Karel Capek"
        )))
        #expect(wishlist.count == 1)
    }

    @Test func importedExactTitleAndAuthorFulfilsWishlist() {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let toasts = ToastCenter()
        let wishlist = WishlistService(modelContext: context, toasts: toasts)
        wishlist.add(discoveryBook())

        let imported = Book(fileName: "book.epub", originalFileName: "book.epub")
        imported.title = "The Fifth Season"
        imported.author = "N. K. Jemisin"
        context.insert(imported)

        #expect(wishlist.fulfil(with: [imported]) == 1)
        #expect(wishlist.items.isEmpty)
        #expect(toasts.messages.last?.style == .success)
        #expect(toasts.messages.last?.text == String(
            localized: "A book from your Wishlist is now in your library."
        ))
    }

    @Test func sameTitleByDifferentAuthorDoesNotFulfilWishlist() {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let wishlist = WishlistService(modelContext: context, toasts: ToastCenter())
        wishlist.add(discoveryBook(title: "Home", author: "Toni Morrison"))

        let imported = Book(fileName: "home.epub", originalFileName: "home.epub")
        imported.title = "Home"
        imported.author = "Harlan Coben"
        context.insert(imported)

        #expect(wishlist.fulfil(with: [imported]) == 0)
        #expect(wishlist.count == 1)
    }

    @Test func alreadyOwnedBookCannotBeAdded() {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let local = Book(fileName: "owned.epub", originalFileName: "owned.epub")
        local.title = "The Fifth Season"
        local.author = "N. K. Jemisin"
        context.insert(local)

        let wishlist = WishlistService(modelContext: context, toasts: ToastCenter())
        #expect(!wishlist.add(discoveryBook()))
        #expect(wishlist.items.isEmpty)
    }

    @Test func regularImportPipelineFulfilsWishlistAfterMetadataExtraction() async throws {
        let library = try await TestLibrary()
        let toasts = ToastCenter()
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: toasts,
            online: WishlistOfflineMetadataClient()
        )
        viewModel.wishlist.add(discoveryBook(
            id: "epub-1",
            title: "Import Match",
            author: "Exact Author"
        ))

        let source = try EPUBFixture.make(title: "Import Match", author: "Exact Author")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        viewModel.addBooks(from: [source])

        for _ in 0..<200 where viewModel.wishlist.count > 0 {
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(viewModel.wishlist.items.isEmpty)
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 1)
        #expect(toasts.messages.contains { $0.style == .success })
    }
}

private actor WishlistOfflineMetadataClient: OnlineMetadataFetching {
    func fetch(
        isbn: String?,
        title: String,
        author: String?,
        language: MetadataLanguage,
        hardcoverToken: String?
    ) async -> OnlineMetadataFetchResult {
        OnlineMetadataFetchResult(metadata: nil, reachedNetwork: false)
    }

    func downloadCover(_ url: URL) async -> Data? { nil }
}

// MARK: - Series completion

@Suite(.serialized)
struct SeriesCompletionTests {
    private let response = """
    {
      "data": {
        "series": [
          {
            "id": 10,
            "name": "The Expanse",
            "slug": "the-expanse-wrong",
            "primary_books_count": 2,
            "author": { "name": "Someone Else" },
            "book_series": [
              {
                "position": 1,
                "details": null,
                "book": {
                  "id": 101,
                  "title": "A Different Book",
                  "slug": "a-different-book",
                  "users_read_count": 5,
                  "contributions": [{ "author": { "name": "Someone Else" } }]
                }
              }
            ]
          },
          {
            "id": 20,
            "name": "The Expanse",
            "slug": "the-expanse",
            "primary_books_count": 3,
            "author": { "name": "James S. A. Corey" },
            "book_series": [
              {
                "position": 1,
                "details": "1",
                "book": {
                  "id": 201,
                  "title": "Leviathan Wakes",
                  "slug": "leviathan-wakes",
                  "users_read_count": 900,
                  "release_date": "2011-06-02",
                  "image": { "url": "https://img.hardcover.app/leviathan-wakes.jpg" },
                  "contributions": [{ "author": { "name": "James S. A. Corey" } }]
                }
              },
              {
                "position": 2,
                "details": "2",
                "book": {
                  "id": 202,
                  "title": "Caliban's War: A Novel",
                  "slug": "calibans-war-a-novel",
                  "users_read_count": 10,
                  "contributions": [{ "author": { "name": "James S. A. Corey" } }]
                }
              },
              {
                "position": 2,
                "details": "2",
                "book": {
                  "id": 203,
                  "title": "Caliban's War",
                  "slug": "calibans-war",
                  "users_read_count": 800,
                  "contributions": [{ "author": { "name": "James S. A. Corey" } }]
                }
              },
              {
                "position": 3,
                "details": "3",
                "book": {
                  "id": 204,
                  "title": "Abaddon's Gate",
                  "slug": "abaddons-gate",
                  "users_read_count": 700,
                  "contributions": [{ "author": { "name": "James S. A. Corey" } }]
                }
              }
            ]
          }
        ]
      }
    }
    """

    private var lookup: SeriesLookup {
        SeriesLookup(
            name: "The Expanse",
            authors: ["James S. A. Corey"],
            books: [
                SeriesLocalBookSnapshot(
                    id: UUID(), title: "Leviathan Wakes",
                    author: "James S. A. Corey", position: 1
                ),
                SeriesLocalBookSnapshot(
                    id: UUID(), title: "Caliban's War",
                    author: "James S. A. Corey", position: 2
                ),
            ]
        )
    }

    @Test func decoderSelectsAuthorMatchAndDeduplicatesPosition() throws {
        let catalogs = try HardcoverSeriesService.decodeCatalogs(
            Data(response.utf8),
            matching: [lookup]
        )
        let catalog = try #require(catalogs[lookup.id])

        #expect(catalog.id == 20)
        #expect(catalog.totalBookCount == 3)
        #expect(catalog.books.map(\.title) == [
            "Leviathan Wakes", "Caliban's War", "Abaddon's Gate",
        ])
        #expect(catalog.books.first?.releaseDate == DiscoveryReleaseDate(year: 2011, month: 6, day: 2))
        #expect(catalog.books.first?.coverURL == URL(string: "https://img.hardcover.app/leviathan-wakes.jpg"))
        #expect(catalog.books.last?.releaseDate == nil)
        #expect(catalog.books.last?.coverURL == nil)
        #expect(catalog.hardcoverURL == URL(string: "https://hardcover.app/series/the-expanse"))
    }

    @Test func calculatorReportsOwnedAndNamedMissingBooks() throws {
        let catalog = try #require(
            HardcoverSeriesService.decodeCatalogs(
                Data(response.utf8), matching: [lookup]
            )[lookup.id]
        )
        let completion = SeriesCompletionCalculator.make(catalog: catalog, lookup: lookup)

        #expect(completion.ownedCount == 2)
        #expect(completion.missingCount == 1)
        #expect(completion.missingBooks.map(\.title) == ["Abaddon's Gate"])
        #expect(completion.unidentifiedMissingCount == 0)
    }

    @Test func numericSeriesPositionMatchesTranslatedLocalTitle() throws {
        let translated = SeriesLookup(
            name: "The Expanse",
            authors: ["James S. A. Corey"],
            books: [
                SeriesLocalBookSnapshot(
                    id: UUID(), title: "Procitnutí Leviatana",
                    author: "James S. A. Corey", position: 1
                ),
            ]
        )
        let catalog = try #require(
            HardcoverSeriesService.decodeCatalogs(
                Data(response.utf8), matching: [translated]
            )[translated.id]
        )
        let completion = SeriesCompletionCalculator.make(catalog: catalog, lookup: translated)

        #expect(completion.ownedCount == 1)
        #expect(completion.missingBooks.map(\.title) == ["Caliban's War", "Abaddon's Gate"])
    }

    @Test func negativeCatalogResultIsCachedWithoutAnotherRequest() async throws {
        SeriesCacheURLProtocol.prepare()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeriesCacheURLProtocol.self]
        let service = HardcoverSeriesService(session: URLSession(configuration: configuration))

        _ = try await service.catalogs(matching: [lookup], token: "test-token")
        _ = try await service.catalogs(matching: [lookup], token: "test-token")

        #expect(SeriesCacheURLProtocol.requestCount == 1)
    }

    @Test func refreshingCatalogsBypassesCachedResults() async throws {
        SeriesCacheURLProtocol.prepare()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeriesCacheURLProtocol.self]
        let service = HardcoverSeriesService(session: URLSession(configuration: configuration))

        _ = try await service.catalogs(matching: [lookup], token: "test-token")
        _ = try await service.catalogs(matching: [lookup], token: "test-token")
        #expect(SeriesCacheURLProtocol.requestCount == 1)

        _ = try await service.refreshCatalogs(matching: [lookup], token: "test-token")

        #expect(SeriesCacheURLProtocol.requestCount == 2)
    }

    @Test func concurrentCatalogRequestsForTheSameSeriesAreCoalesced() async throws {
        SeriesCacheURLProtocol.prepare(responseDelay: 0.15)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeriesCacheURLProtocol.self]
        let service = HardcoverSeriesService(session: URLSession(configuration: configuration))

        async let first = service.catalogs(matching: [lookup], token: "test-token")
        async let second = service.catalogs(matching: [lookup], token: "test-token")
        _ = try await (first, second)

        #expect(SeriesCacheURLProtocol.requestCount == 1)
    }
}

private final class SeriesCacheURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedRequestCount = 0
    nonisolated(unsafe) private static var responseDelay: TimeInterval = 0

    static var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    static func prepare(responseDelay: TimeInterval = 0) {
        lock.withLock {
            storedRequestCount = 0
            self.responseDelay = responseDelay
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let delay = Self.lock.withLock { () -> TimeInterval in
            Self.storedRequestCount += 1
            return Self.responseDelay
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":{"series":[]}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
