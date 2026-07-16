import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class NoticeService {
    private let modelContext: ModelContext
    private let settings: AppSettings
    private let toasts: ToastCenter
    private let wishlist: WishlistService
    private let catalogService: any SeriesCatalogFetching

    private(set) var notices: [LibraryNotice]
    private(set) var isChecking = false
    private(set) var lastCheckFailed = false

    nonisolated private static let finishFanoutLimit = 3
    nonisolated private static let releaseWindowMonths = 12

    init(
        modelContext: ModelContext,
        settings: AppSettings,
        toasts: ToastCenter,
        wishlist: WishlistService,
        catalogService: any SeriesCatalogFetching = HardcoverSeriesService.shared
    ) {
        self.modelContext = modelContext
        self.settings = settings
        self.toasts = toasts
        self.wishlist = wishlist
        self.catalogService = catalogService
        let descriptor = FetchDescriptor<LibraryNotice>(
            sortBy: [SortDescriptor(\LibraryNotice.dateCreated, order: .reverse)]
        )
        self.notices = (try? modelContext.fetch(descriptor)) ?? []
    }

    var unreadCount: Int { notices.count { $0.readAt == nil } }

    var releaseCheckAvailable: Bool {
        settings.onlineMetadataEnabled
            && settings.releaseCheckEnabled
            && !settings.hardcoverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - New-release check

    nonisolated static func isDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) > 24 * 3600
    }

    func checkForNewReleasesIfDue() async {
        guard releaseCheckAvailable, Self.isDue(last: settings.lastReleaseCheckAt, now: .now) else { return }
        await performReleaseCheck(announce: false)
    }

    func checkForNewReleases() async {
        await performReleaseCheck(announce: true)
    }

    private func performReleaseCheck(announce: Bool) async {
        guard releaseCheckAvailable, !isChecking else { return }
        let token = settings.hardcoverToken
        let books = modelContext.allBooks()
        prune(existingBookUUIDs: Set(books.map(\.uuid)))
        let lookups = SeriesLookupBuilder.groups(from: books).map(\.lookup)
        guard !lookups.isEmpty else {
            settings.lastReleaseCheckAt = .now
            lastCheckFailed = false
            if announce { toasts.info(String(localized: "No series to check yet.")) }
            return
        }

        isChecking = true
        defer { isChecking = false }
        do {
            let catalogs = try await catalogService.refreshCatalogs(matching: lookups, token: token)
            let inserted = applyCatalogs(catalogs, lookups: lookups)
            modelContext.saveQuietly()
            reload()
            settings.lastReleaseCheckAt = .now
            lastCheckFailed = false
            if announce {
                if inserted > 0 {
                    toasts.success(String(localized: "Found \(inserted) new releases."))
                } else {
                    toasts.info(String(localized: "No new releases found."))
                }
            }
        } catch {
            lastCheckFailed = true
            if announce { toasts.error(String(localized: "Checking for new releases failed.")) }
        }
    }

    private func applyCatalogs(
        _ catalogs: [String: HardcoverSeriesCatalog],
        lookups: [SeriesLookup]
    ) -> Int {
        var inserted = 0
        let cutoff = Self.releaseWindowCutoff()
        for lookup in lookups {
            guard let catalog = catalogs[lookup.id] else { continue }
            let currentIDs = Set(catalog.books.map(\.id))
            guard let snapshot = snapshot(forSeriesKey: lookup.id) else {
                modelContext.insert(SeriesCatalogSnapshot(seriesKey: lookup.id, knownBookIDs: currentIDs))
                continue
            }
            let newIDs = currentIDs.subtracting(snapshot.knownBookIDs)
            if !newIDs.isEmpty {
                let completion = SeriesCompletionCalculator.make(catalog: catalog, lookup: lookup)
                for book in completion.missingBooks where newIDs.contains(book.id) {
                    guard Self.isWithinReleaseWindow(book.releaseDate, cutoff: cutoff) else { continue }
                    let key = "release:\(book.id)"
                    guard !noticeExists(dedupeKey: key) else { continue }
                    insertReleaseNotice(for: book, in: catalog, dedupeKey: key)
                    inserted += 1
                }
            }
            snapshot.knownBookIDs = snapshot.knownBookIDs.union(currentIDs)
            snapshot.lastCheckedAt = .now
        }
        return inserted
    }

    private nonisolated static func releaseWindowCutoff(now: Date = .now) -> DiscoveryReleaseDate? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(byAdding: .month, value: -releaseWindowMonths, to: now) else {
            return nil
        }
        return DiscoveryReleaseDate(date: date, calendar: calendar)
    }

    private nonisolated static func isWithinReleaseWindow(
        _ releaseDate: DiscoveryReleaseDate?,
        cutoff: DiscoveryReleaseDate?
    ) -> Bool {
        guard let releaseDate, let cutoff else { return true }
        return releaseDate >= cutoff
    }

    private func insertReleaseNotice(
        for book: HardcoverSeriesBook,
        in catalog: HardcoverSeriesCatalog,
        dedupeKey: String
    ) {
        let notice = LibraryNotice(dedupeKey: dedupeKey, kind: .newRelease, bookTitle: book.title)
        notice.seriesName = catalog.name
        notice.author = book.authors.first ?? catalog.author
        notice.positionText = book.positionText ?? book.position.map(Self.formatPosition)
        notice.hardcoverBookID = String(book.id)
        notice.hardcoverURLString = book.hardcoverURL.absoluteString
        notice.coverURLString = book.coverURL?.absoluteString
        notice.releaseDateRaw = book.releaseDate?.iso8601
        modelContext.insert(notice)
    }

    private nonisolated static func formatPosition(_ position: Double) -> String {
        position == position.rounded() ? String(Int(position)) : String(position)
    }

    // MARK: - Finished books

    func booksDidFinish(_ books: [Book]) {
        guard !books.isEmpty, books.count <= Self.finishFanoutLimit else { return }
        var changed = false
        for book in books {
            if book.rating == nil, insertRatingPrompt(for: book) { changed = true }
            if let next = nextUnreadInOwnedSeries(after: book),
               insertNextInSeries(after: book, next: next) {
                changed = true
            }
        }
        guard changed else { return }
        modelContext.saveQuietly()
        reload()
    }

    private func insertRatingPrompt(for book: Book) -> Bool {
        let key = "rate:\(book.uuid.uuidString)"
        guard !noticeExists(dedupeKey: key) else { return false }
        let notice = LibraryNotice(dedupeKey: key, kind: .ratingPrompt, bookTitle: book.displayTitle)
        notice.author = book.displayAuthor
        notice.seriesName = book.series
        notice.bookUUID = book.uuid
        modelContext.insert(notice)
        return true
    }

    private func insertNextInSeries(after finished: Book, next: Book) -> Bool {
        let key = "next:\(next.uuid.uuidString)"
        guard !noticeExists(dedupeKey: key) else { return false }
        let notice = LibraryNotice(dedupeKey: key, kind: .nextInSeries, bookTitle: next.displayTitle)
        notice.author = next.displayAuthor
        notice.seriesName = next.series ?? finished.series
        notice.positionText = next.seriesIndex
        notice.bookUUID = next.uuid
        modelContext.insert(notice)
        return true
    }

    private func nextUnreadInOwnedSeries(after book: Book) -> Book? {
        guard let series = book.series, !series.isEmpty,
              let index = book.seriesIndex.flatMap(Double.init) else { return nil }
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.series == series })
        let candidates = ((try? modelContext.fetch(descriptor)) ?? [])
            .compactMap { candidate -> (book: Book, position: Double)? in
                guard candidate.uuid != book.uuid,
                      let position = candidate.seriesIndex.flatMap(Double.init),
                      position > index,
                      candidate.readingStatus != .finished else { return nil }
                return (candidate, position)
            }
            .min { $0.position < $1.position }
        return candidates?.book
    }

    // MARK: - Row actions

    func book(for notice: LibraryNotice) -> Book? {
        guard let uuid = notice.bookUUID else { return nil }
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetch(descriptor)) ?? []).first
    }

    func isWishlisted(_ notice: LibraryNotice) -> Bool {
        guard let book = discoveryBook(from: notice) else { return false }
        return wishlist.contains(book)
    }

    func toggleWishlist(from notice: LibraryNotice) {
        guard let book = discoveryBook(from: notice) else { return }
        wishlist.toggle(book)
        markRead(notice)
    }

    private func discoveryBook(from notice: LibraryNotice) -> DiscoveryBook? {
        guard let hardcoverID = notice.hardcoverBookID, let hardcoverURL = notice.hardcoverURL else {
            return nil
        }
        return DiscoveryBook(
            id: hardcoverID,
            title: notice.bookTitle,
            author: notice.author,
            coverURL: notice.coverURL,
            hardcoverURL: hardcoverURL,
            rating: nil,
            releaseDate: notice.releaseDateRaw.flatMap(DiscoveryReleaseDate.init(iso8601:))
        )
    }

    func markRead(_ notice: LibraryNotice) {
        guard notice.readAt == nil else { return }
        notice.readAt = .now
        modelContext.saveQuietly()
    }

    func markUnread(_ notice: LibraryNotice) {
        guard notice.readAt != nil else { return }
        notice.readAt = nil
        modelContext.saveQuietly()
    }

    func markAllRead() {
        let unread = notices.filter { $0.readAt == nil }
        guard !unread.isEmpty else { return }
        for notice in unread { notice.readAt = .now }
        modelContext.saveQuietly()
    }

    func delete(_ notice: LibraryNotice) {
        notices.removeAll { $0.id == notice.id }
        modelContext.delete(notice)
        modelContext.saveQuietly()
    }

    // MARK: - Support

    private func snapshot(forSeriesKey key: String) -> SeriesCatalogSnapshot? {
        var descriptor = FetchDescriptor<SeriesCatalogSnapshot>(
            predicate: #Predicate { $0.seriesKey == key }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetch(descriptor)) ?? []).first
    }

    private func noticeExists(dedupeKey key: String) -> Bool {
        let descriptor = FetchDescriptor<LibraryNotice>(
            predicate: #Predicate { $0.dedupeKey == key }
        )
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    private func prune(existingBookUUIDs: Set<UUID>) {
        let stale = notices.filter { notice in
            guard let bookUUID = notice.bookUUID else { return false }
            return !existingBookUUIDs.contains(bookUUID)
        }
        guard !stale.isEmpty else { return }
        for notice in stale { modelContext.delete(notice) }
        modelContext.saveQuietly()
        reload()
    }

    private func reload() {
        let descriptor = FetchDescriptor<LibraryNotice>(
            sortBy: [SortDescriptor(\LibraryNotice.dateCreated, order: .reverse)]
        )
        notices = (try? modelContext.fetch(descriptor)) ?? []
    }
}
