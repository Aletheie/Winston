import Foundation
import SwiftData
import Testing
@testable import Winston

@MainActor
@Suite(.serialized)
struct NoticeServiceTests {
    @Test func firstCheckCreatesSilentBaselineThenOnlyNewMissingBooksBecomeNotices() async throws {
        let harness = makeHarness(catalog: catalog(books: [
            remoteBook(id: 1, title: "Owned", position: 1),
            remoteBook(id: 2, title: "Already Known", position: 2),
        ]))
        defer { harness.defaults.restore(on: harness.settings) }
        insertBook(title: "Owned", series: "Saga", position: "1", into: harness.context)

        await harness.service.checkForNewReleases()
        #expect(harness.service.notices.isEmpty)

        await harness.catalogService.replace(with: catalog(books: [
            remoteBook(id: 1, title: "Owned", position: 1),
            remoteBook(id: 2, title: "Already Known", position: 2),
            remoteBook(id: 3, title: "Brand New", position: 3, releaseDate: "2026-07-01"),
        ]))
        await harness.service.checkForNewReleases()

        let notice = try #require(harness.service.notices.first)
        #expect(harness.service.notices.count == 1)
        #expect(notice.kind == .newRelease)
        #expect(notice.hardcoverBookID == "3")
        #expect(notice.bookTitle == "Brand New")

        harness.service.delete(notice)
        await harness.service.checkForNewReleases()
        #expect(harness.service.notices.isEmpty)

        let snapshot = try #require(try harness.context.fetch(FetchDescriptor<SeriesCatalogSnapshot>()).first)
        #expect(snapshot.knownBookIDs == [1, 2, 3])
    }

    @Test func releaseCheckSkipsOwnedAndOldBooksButAcceptsUnknownReleaseDate() async {
        let harness = makeHarness(catalog: catalog(books: [
            remoteBook(id: 1, title: "Owned One", position: 1),
        ]))
        defer { harness.defaults.restore(on: harness.settings) }
        insertBook(title: "Owned One", series: "Saga", position: "1", into: harness.context)
        insertBook(title: "Owned Four", series: "Saga", position: "4", into: harness.context)

        await harness.service.checkForNewReleases()
        await harness.catalogService.replace(with: catalog(books: [
            remoteBook(id: 1, title: "Owned One", position: 1),
            remoteBook(id: 2, title: "Too Old", position: 2, releaseDate: "2024-01-01"),
            remoteBook(id: 3, title: "Unknown Date", position: 3),
            remoteBook(id: 4, title: "Owned Four", position: 4, releaseDate: "2026-07-01"),
        ]))
        await harness.service.checkForNewReleases()

        #expect(harness.service.notices.map(\.bookTitle) == ["Unknown Date"])
    }

    @Test func finishingBooksCreatesRatingPromptOnceAndLimitsBulkFanout() {
        let harness = makeHarness()
        defer { harness.defaults.restore(on: harness.settings) }

        let unrated = insertBook(title: "Unrated", into: harness.context)
        harness.service.booksDidFinish([unrated])
        harness.service.booksDidFinish([unrated])
        #expect(harness.service.notices.count == 1)
        #expect(harness.service.notices.first?.kind == .ratingPrompt)

        let rated = insertBook(title: "Rated", rating: 4, into: harness.context)
        harness.service.booksDidFinish([rated])
        #expect(harness.service.notices.count == 1)

        let bulk = (1...4).map { insertBook(title: "Bulk \($0)", into: harness.context) }
        harness.service.booksDidFinish(bulk)
        #expect(harness.service.notices.count == 1)
    }

    @Test func nextInSeriesSkipsFinishedBooksAndTargetsTheNextUnreadOwnedBook() throws {
        let harness = makeHarness()
        defer { harness.defaults.restore(on: harness.settings) }

        let first = insertBook(
            title: "First", series: "Trilogy", position: "1", rating: 5, into: harness.context
        )
        let second = insertBook(
            title: "Second", series: "Trilogy", position: "2", rating: 5, into: harness.context
        )
        second.setStatus(.finished)
        let third = insertBook(
            title: "Third", series: "Trilogy", position: "3", rating: 5, into: harness.context
        )
        harness.context.saveQuietly()

        harness.service.booksDidFinish([first])

        let notice = try #require(harness.service.notices.first)
        #expect(notice.kind == .nextInSeries)
        #expect(notice.bookUUID == third.uuid)
        #expect(harness.service.book(for: notice)?.uuid == third.uuid)

        let noSeries = insertBook(title: "Standalone", rating: 5, into: harness.context)
        let noPosition = insertBook(title: "Appendix", series: "Trilogy", rating: 5, into: harness.context)
        harness.service.booksDidFinish([noSeries, noPosition])
        #expect(harness.service.notices.count == 1)
    }

    @Test func releaseNoticeCanAddItsBookToWishlist() throws {
        let harness = makeHarness()
        defer { harness.defaults.restore(on: harness.settings) }
        let notice = LibraryNotice(
            dedupeKey: "release:77",
            kind: .newRelease,
            bookTitle: "Wish"
        )
        notice.author = "Author"
        notice.hardcoverBookID = "77"
        notice.hardcoverURLString = "https://hardcover.app/books/wish"
        notice.coverURLString = "https://img.hardcover.app/wish.jpg"
        harness.context.insert(notice)

        harness.service.toggleWishlist(from: notice)

        let item = try #require(try harness.context.fetch(FetchDescriptor<WishlistItem>()).first)
        #expect(item.hardcoverID == "77")
        #expect(item.title == "Wish")
        #expect(notice.readAt != nil)
    }

    @Test func readStateAndPruningStayInSyncWithPersistedNotices() async throws {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let linkedBook = insertBook(title: "Linked", into: context)
        let first = LibraryNotice(dedupeKey: "rate:1", kind: .ratingPrompt, bookTitle: "First")
        first.bookUUID = linkedBook.uuid
        let second = LibraryNotice(dedupeKey: "rate:2", kind: .ratingPrompt, bookTitle: "Second")
        context.insert(first)
        context.insert(second)
        try context.save()

        let (settings, defaults) = configuredSettings()
        defer { defaults.restore(on: settings) }
        let wishlist = WishlistService(modelContext: context, toasts: ToastCenter())
        let service = NoticeService(
            modelContext: context,
            settings: settings,
            toasts: ToastCenter(),
            wishlist: wishlist,
            catalogService: FakeSeriesCatalogService()
        )

        #expect(service.unreadCount == 2)
        service.markRead(first)
        #expect(service.unreadCount == 1)
        service.markAllRead()
        #expect(service.unreadCount == 0)
        service.markUnread(first)
        #expect(service.unreadCount == 1)

        context.delete(linkedBook)
        context.saveQuietly()
        await service.checkForNewReleases()
        #expect(service.notices.map(\.id) == [second.id])
    }

    @Test func dailyGateUsesTwentyFourHourInterval() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(NoticeService.isDue(last: nil, now: now))
        #expect(!NoticeService.isDue(last: now.addingTimeInterval(-23 * 3600), now: now))
        #expect(NoticeService.isDue(last: now.addingTimeInterval(-25 * 3600), now: now))
    }

    @Test func eachReleaseCheckRequestsFreshCatalogs() async {
        let harness = makeHarness(catalog: catalog(books: [
            remoteBook(id: 1, title: "Owned", position: 1),
        ]))
        defer { harness.defaults.restore(on: harness.settings) }
        insertBook(title: "Owned", series: "Saga", position: "1", into: harness.context)

        await harness.service.checkForNewReleases()
        await harness.service.checkForNewReleases()

        let refreshCalls = await harness.catalogService.refreshCalls
        #expect(refreshCalls == 2)
    }

    private func makeHarness(catalog: HardcoverSeriesCatalog? = nil) -> NoticeHarness {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let (settings, defaults) = configuredSettings()
        let toasts = ToastCenter()
        let wishlist = WishlistService(modelContext: context, toasts: toasts)
        let catalogService = FakeSeriesCatalogService(catalog: catalog)
        let service = NoticeService(
            modelContext: context,
            settings: settings,
            toasts: toasts,
            wishlist: wishlist,
            catalogService: catalogService
        )
        return NoticeHarness(
            container: container,
            context: context,
            settings: settings,
            defaults: defaults,
            wishlist: wishlist,
            catalogService: catalogService,
            service: service
        )
    }

    private func configuredSettings() -> (AppSettings, NoticeDefaultsSnapshot) {
        let settings = AppSettings()
        let defaults = NoticeDefaultsSnapshot(settings: settings)
        settings.onlineMetadataEnabled = true
        settings.hardcoverToken = "test-token"
        settings.releaseCheckEnabled = true
        settings.lastReleaseCheckAt = nil
        return (settings, defaults)
    }

    @discardableResult
    private func insertBook(
        title: String,
        series: String? = nil,
        position: String? = nil,
        rating: Int? = nil,
        into context: ModelContext
    ) -> Book {
        let book = Book(
            fileName: "\(UUID().uuidString).epub",
            originalFileName: "\(title).epub"
        )
        book.title = title
        book.author = "Author"
        book.series = series
        book.seriesIndex = position
        book.rating = rating
        context.insert(book)
        context.saveQuietly()
        return book
    }

    private func catalog(books: [HardcoverSeriesBook]) -> HardcoverSeriesCatalog {
        HardcoverSeriesCatalog(
            id: 10,
            name: "Saga",
            author: "Author",
            totalBookCount: books.count,
            hardcoverURL: URL(string: "https://hardcover.app/series/saga")!,
            books: books
        )
    }

    private func remoteBook(
        id: Int,
        title: String,
        position: Double,
        releaseDate: String? = nil
    ) -> HardcoverSeriesBook {
        HardcoverSeriesBook(
            id: id,
            title: title,
            position: position,
            positionText: String(Int(position)),
            authors: ["Author"],
            hardcoverURL: URL(string: "https://hardcover.app/books/\(id)")!,
            releaseDate: releaseDate.flatMap(DiscoveryReleaseDate.init(iso8601:)),
            coverURL: URL(string: "https://img.hardcover.app/\(id).jpg")
        )
    }
}

@MainActor
private struct NoticeHarness {
    let container: ModelContainer
    let context: ModelContext
    let settings: AppSettings
    let defaults: NoticeDefaultsSnapshot
    let wishlist: WishlistService
    let catalogService: FakeSeriesCatalogService
    let service: NoticeService
}

@MainActor
private struct NoticeDefaultsSnapshot {
    let onlineMetadataEnabled: Bool
    let hardcoverToken: String
    let releaseCheckEnabled: Bool
    let lastReleaseCheckAt: Date?

    init(settings: AppSettings) {
        onlineMetadataEnabled = settings.onlineMetadataEnabled
        hardcoverToken = settings.hardcoverToken
        releaseCheckEnabled = settings.releaseCheckEnabled
        lastReleaseCheckAt = settings.lastReleaseCheckAt
    }

    func restore(on settings: AppSettings) {
        settings.onlineMetadataEnabled = onlineMetadataEnabled
        settings.hardcoverToken = hardcoverToken
        settings.releaseCheckEnabled = releaseCheckEnabled
        settings.lastReleaseCheckAt = lastReleaseCheckAt
    }
}

private actor FakeSeriesCatalogService: SeriesCatalogFetching {
    private var catalog: HardcoverSeriesCatalog?
    private(set) var calls = 0
    private(set) var refreshCalls = 0

    init(catalog: HardcoverSeriesCatalog? = nil) {
        self.catalog = catalog
    }

    func replace(with catalog: HardcoverSeriesCatalog?) {
        self.catalog = catalog
    }

    func catalogs(
        matching lookups: [SeriesLookup],
        token: String
    ) async throws -> [String: HardcoverSeriesCatalog] {
        calls += 1
        guard let catalog else { return [:] }
        return Dictionary(uniqueKeysWithValues: lookups.map { ($0.id, catalog) })
    }

    func refreshCatalogs(
        matching lookups: [SeriesLookup],
        token: String
    ) async throws -> [String: HardcoverSeriesCatalog] {
        refreshCalls += 1
        return try await catalogs(matching: lookups, token: token)
    }
}
