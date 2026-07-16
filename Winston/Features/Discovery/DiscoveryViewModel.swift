import Foundation
import Observation

@MainActor
@Observable
final class DiscoveryViewModel {
    enum Phase: Equatable {
        case disabledOnline
        case disabledToken
        case loading
        case loaded
        case empty
        case failed
    }

    static let pageSize = 24

    private let settings: AppSettings
    private let service: any DiscoveryFetching

    private(set) var selectedGenre: DiscoveryGenre = .default
    private(set) var phase: Phase = .loading
    private(set) var visibleBooks: [DiscoveryBook] = []
    private(set) var hasMore = false
    private(set) var isRefreshing = false
    private(set) var refreshFailed = false

    private var allBooks: [DiscoveryBook] = []
    private var visibleCounts: [DiscoveryGenre: Int] = [:]
    private var loadGeneration = 0
    private var credentialReloadTask: Task<Void, Never>?

    init(settings: AppSettings, service: any DiscoveryFetching = DiscoveryService()) {
        self.settings = settings
        self.service = service
    }

    func select(_ genre: DiscoveryGenre) {
        guard genre != selectedGenre else { return }
        loadGeneration += 1
        selectedGenre = genre
        clearVisibleCatalog(phase: .loading)
    }

    func load() async {
        await requestCatalog(forceRefresh: false, preserveContent: false)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshFailed = false
        let preserveContent = phase == .loaded
        await requestCatalog(forceRefresh: true, preserveContent: preserveContent)
        isRefreshing = false
    }

    func retry() async {
        await requestCatalog(forceRefresh: true, preserveContent: false)
    }

    func loadNextPage() async {
        guard phase == .loaded, hasMore else { return }
        let genre = selectedGenre
        let previousCount = visibleBooks.count
        await Task.yield()
        guard !Task.isCancelled,
              genre == selectedGenre,
              previousCount == visibleBooks.count else { return }

        let nextCount = min(allBooks.count, previousCount + Self.pageSize)
        visibleCounts[genre] = nextCount
        visibleBooks = Array(allBooks.prefix(nextCount))
        hasMore = nextCount < allBooks.count
    }

    func hardcoverCredentialDidChange(delay: Duration = .milliseconds(500)) {
        invalidateLoads()
        credentialReloadTask?.cancel()
        credentialReloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.requestCatalog(forceRefresh: true, preserveContent: false)
        }
    }

    func onlineSettingDidChange() {
        invalidateLoads()
        credentialReloadTask?.cancel()
        Task { await requestCatalog(forceRefresh: false, preserveContent: false) }
    }

    func reset() {
        invalidateLoads()
        credentialReloadTask?.cancel()
        visibleCounts.removeAll()
        clearVisibleCatalog(phase: .loading)
    }

    private func requestCatalog(forceRefresh: Bool, preserveContent: Bool) async {
        guard settings.onlineMetadataEnabled else {
            clearVisibleCatalog(phase: .disabledOnline)
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        let genre = selectedGenre
        if !preserveContent { clearVisibleCatalog(phase: .loading) }

        let result = forceRefresh
            ? await service.refreshBooks(matching: genre.queryTerm, token: settings.hardcoverToken)
            : await service.books(matching: genre.queryTerm, token: settings.hardcoverToken)

        guard !Task.isCancelled,
              generation == loadGeneration,
              genre == selectedGenre else { return }

        switch result {
        case .needsToken:
            clearVisibleCatalog(phase: .disabledToken)
        case .failed:
            if preserveContent, !visibleBooks.isEmpty {
                refreshFailed = true
            } else {
                clearVisibleCatalog(phase: .failed)
            }
        case .books(let books):
            apply(books, to: genre)
        }
    }

    private func apply(_ books: [DiscoveryBook], to genre: DiscoveryGenre) {
        allBooks = books
        guard !books.isEmpty else {
            visibleBooks = []
            hasMore = false
            phase = .empty
            return
        }

        let preferredCount = max(Self.pageSize, visibleCounts[genre] ?? 0)
        let visibleCount = min(preferredCount, books.count)
        visibleCounts[genre] = visibleCount
        visibleBooks = Array(books.prefix(visibleCount))
        hasMore = visibleCount < books.count
        refreshFailed = false
        phase = .loaded
    }

    private func clearVisibleCatalog(phase: Phase) {
        allBooks = []
        visibleBooks = []
        hasMore = false
        refreshFailed = false
        self.phase = phase
    }

    private func invalidateLoads() {
        loadGeneration += 1
    }
}

#if DEBUG
extension DiscoveryViewModel {
    static func preview(_ phase: Phase, books: [DiscoveryBook] = []) -> DiscoveryViewModel {
        let viewModel = DiscoveryViewModel(settings: AppSettings())
        viewModel.phase = phase
        viewModel.allBooks = books
        viewModel.visibleBooks = Array(books.prefix(Self.pageSize))
        viewModel.hasMore = books.count > Self.pageSize
        return viewModel
    }
}
#endif
