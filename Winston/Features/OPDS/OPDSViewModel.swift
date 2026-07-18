import Foundation
import Observation

@MainActor
@Observable
final class OPDSViewModel {
    enum Phase: Equatable {
        case home
        case disabledOnline
        case loading
        case loaded
        case empty
        case failed(OPDSFailure)
    }

    enum OPDSFailure: Equatable {
        case authenticationRequired
        case network
        case invalidFeed
        case feedTooLarge
        case server(Int)

        var message: String {
            switch self {
            case .authenticationRequired:
                String(localized: "This catalog currently requires feed access from its provider.")
            case .network:
                String(localized: "The catalog couldn’t be reached. Check your connection and try again.")
            case .invalidFeed:
                String(localized: "This address didn’t return a supported OPDS catalog.")
            case .feedTooLarge:
                String(localized: "The catalog response is too large to open safely.")
            case .server(let status):
                String(localized: "The catalog server returned error \(status).")
            }
        }
    }

    private struct Location {
        let url: URL
        var feed: OPDSFeed
    }

    let catalogs = OPDSCatalog.builtIn

    private let settings: AppSettings
    private let service: any OPDSFetching
    private let toasts: ToastCenter

    private(set) var phase: Phase = .home
    private(set) var selectedCatalog: OPDSCatalog?
    private(set) var isRefreshing = false
    private(set) var isLoadingNextPage = false
    private(set) var refreshFailure: OPDSFailure?
    private(set) var downloadingPublicationIDs: Set<String> = []
    private(set) var downloadedPublicationIDs: Set<String> = []

    private var history: [Location] = []
    private var requestedURL: URL?
    private var failedURL: URL?
    private var loadGeneration = 0

    init(
        settings: AppSettings,
        toasts: ToastCenter,
        service: any OPDSFetching = OPDSService()
    ) {
        self.settings = settings
        self.toasts = toasts
        self.service = service
    }

    var feed: OPDSFeed? { history.last?.feed }
    var canGoBack: Bool { selectedCatalog != nil }
    var canRefresh: Bool {
        settings.onlineMetadataEnabled
            && !isRefreshing
            && (phase == .loaded || phase == .empty)
    }
    var canLoadNextPage: Bool {
        settings.onlineMetadataEnabled
            && !isLoadingNextPage
            && feed?.nextURL != nil
            && (phase == .loaded || phase == .empty)
    }
    var supportsRemoteSearch: Bool {
        guard selectedCatalog != nil else { return false }
        return feed?.searchTemplate != nil || selectedCatalog?.searchTemplate != nil
    }

    func open(_ catalog: OPDSCatalog) async {
        invalidateLoads()
        selectedCatalog = catalog
        history = []
        requestedURL = catalog.rootURL
        failedURL = nil
        refreshFailure = nil
        guard settings.onlineMetadataEnabled else {
            phase = .disabledOnline
            return
        }
        await load(catalog.rootURL, appendToHistory: true, includeRootShortcuts: true)
    }

    func open(_ item: OPDSNavigationItem) async {
        guard settings.onlineMetadataEnabled else {
            phase = .disabledOnline
            return
        }
        await load(item.url, appendToHistory: true, includeRootShortcuts: false)
    }

    func search(_ query: String) async {
        guard settings.onlineMetadataEnabled,
              let template = feed?.searchTemplate ?? selectedCatalog?.searchTemplate,
              let url = OPDSService.expandedSearchURL(template: template, query: query) else { return }
        await load(url, appendToHistory: true, includeRootShortcuts: false)
    }

    func retry() async {
        guard settings.onlineMetadataEnabled,
              let url = failedURL ?? requestedURL ?? history.last?.url ?? selectedCatalog?.rootURL else {
            phase = .disabledOnline
            return
        }
        await load(
            url,
            appendToHistory: failedURL != nil || history.isEmpty,
            includeRootShortcuts: history.isEmpty && url == selectedCatalog?.rootURL
        )
    }

    func refresh() async {
        guard canRefresh, let location = history.last else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        refreshFailure = nil
        loadGeneration += 1
        let generation = loadGeneration
        do {
            var fresh = try await service.feed(at: location.url)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            if history.count == 1, location.url == selectedCatalog?.rootURL,
               let selectedCatalog {
                fresh = fresh.prependingNavigation(selectedCatalog.rootShortcuts)
            }
            history[history.count - 1].feed = fresh
            phase = fresh.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            refreshFailure = Self.failure(from: error)
        }
    }

    func loadNextPage() async {
        guard canLoadNextPage,
              let nextURL = feed?.nextURL,
              let currentURL = history.last?.url else { return }
        isLoadingNextPage = true
        defer { isLoadingNextPage = false }
        refreshFailure = nil
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let page = try await service.feed(at: nextURL)
            guard !Task.isCancelled,
                  generation == loadGeneration,
                  history.last?.url == currentURL,
                  let current = history.last?.feed else { return }
            history[history.count - 1].feed = current.appending(page)
            phase = history.last?.feed.isEmpty == true ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            refreshFailure = Self.failure(from: error)
        }
    }

    func goBack() {
        invalidateLoads()
        refreshFailure = nil
        failedURL = nil
        requestedURL = nil
        if case .failed = phase, !history.isEmpty {
            restoreCurrentPhase()
            return
        }
        if history.count > 1 {
            history.removeLast()
            restoreCurrentPhase()
        } else {
            returnHome()
        }
    }

    func returnHome() {
        invalidateLoads()
        selectedCatalog = nil
        history = []
        requestedURL = nil
        failedURL = nil
        refreshFailure = nil
        isRefreshing = false
        isLoadingNextPage = false
        phase = .home
    }

    func onlineSettingDidChange() {
        invalidateLoads()
        guard selectedCatalog != nil else { return }
        guard settings.onlineMetadataEnabled else {
            phase = .disabledOnline
            return
        }
        if let feed {
            phase = feed.isEmpty ? .empty : .loaded
        } else {
            Task { await retry() }
        }
    }

    func isDownloading(_ publication: OPDSPublication) -> Bool {
        downloadingPublicationIDs.contains(publication.id)
    }

    func isDownloaded(_ publication: OPDSPublication) -> Bool {
        downloadedPublicationIDs.contains(publication.id)
    }

    func addToLibrary(
        _ publication: OPDSPublication,
        acquisition: OPDSAcquisition,
        library: LibraryViewModel
    ) {
        guard settings.onlineMetadataEnabled else {
            toasts.error(String(localized: "Turn on online metadata to download catalog books."))
            return
        }
        guard downloadingPublicationIDs.insert(publication.id).inserted else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let downloadedURL = try await service.download(acquisition, title: publication.title)
                guard !Task.isCancelled else {
                    Self.removeTemporaryDownload(downloadedURL)
                    downloadingPublicationIDs.remove(publication.id)
                    return
                }
                library.addBooks(from: [downloadedURL]) { [weak self] imported in
                    Self.removeTemporaryDownload(downloadedURL)
                    guard let self else { return }
                    self.downloadingPublicationIDs.remove(publication.id)
                    guard !imported.isEmpty else {
                        self.toasts.error(String(localized: "Couldn’t add “\(publication.title)” to the library."))
                        return
                    }
                    self.downloadedPublicationIDs.insert(publication.id)
                    library.convertBooks(imported)
                    self.toasts.success(String(localized: "Added “\(publication.title)” to your library."))
                }
            } catch is CancellationError {
                downloadingPublicationIDs.remove(publication.id)
            } catch {
                downloadingPublicationIDs.remove(publication.id)
                toasts.error(Self.downloadErrorMessage(error))
            }
        }
    }

    private func load(
        _ url: URL,
        appendToHistory: Bool,
        includeRootShortcuts: Bool
    ) async {
        guard settings.onlineMetadataEnabled else {
            requestedURL = url
            phase = .disabledOnline
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        requestedURL = url
        failedURL = nil
        refreshFailure = nil
        phase = .loading
        do {
            var result = try await service.feed(at: url)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            if includeRootShortcuts, let selectedCatalog {
                result = result.prependingNavigation(selectedCatalog.rootShortcuts)
            }
            let location = Location(url: url, feed: result)
            if appendToHistory {
                history.append(location)
            } else if history.isEmpty {
                history = [location]
            } else {
                history[history.count - 1] = location
            }
            requestedURL = nil
            phase = result.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            failedURL = url
            phase = .failed(Self.failure(from: error))
        }
    }

    private func invalidateLoads() {
        loadGeneration += 1
    }

    private func restoreCurrentPhase() {
        guard settings.onlineMetadataEnabled else {
            phase = .disabledOnline
            return
        }
        phase = history.last?.feed.isEmpty == true ? .empty : .loaded
    }

    private static func failure(from error: any Error) -> OPDSFailure {
        guard let error = error as? OPDSServiceError else { return .network }
        switch error {
        case .authenticationRequired: return .authenticationRequired
        case .feedTooLarge: return .feedTooLarge
        case .invalidFeed, .invalidURL, .invalidDownload, .downloadTooLarge: return .invalidFeed
        case .server(let status): return .server(status)
        case .network: return .network
        }
    }

    private static func downloadErrorMessage(_ error: any Error) -> String {
        guard let error = error as? OPDSServiceError else {
            return String(localized: "The book couldn’t be downloaded.")
        }
        switch error {
        case .authenticationRequired:
            return String(localized: "This catalog requires download access from its provider.")
        case .downloadTooLarge:
            return String(localized: "This book is too large to download safely.")
        case .invalidDownload:
            return String(localized: "The catalog returned an invalid book file.")
        default:
            return String(localized: "The book couldn’t be downloaded.")
        }
    }

    nonisolated private static func removeTemporaryDownload(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
