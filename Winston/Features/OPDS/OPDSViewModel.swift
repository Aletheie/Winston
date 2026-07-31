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
        case unsupportedAuthentication
        case insecureTransport
        case insecureRedirect
        case network
        case invalidFeed
        case feedTooLarge
        case server(Int)

        var message: String {
            switch self {
            case .authenticationRequired:
                String(localized: "This catalog requires valid credentials.")
            case .unsupportedAuthentication:
                String(
                    localized: "The linked server requires a separate sign-in that Winston cannot forward safely."
                )
            case .insecureTransport:
                String(
                    localized: "This HTTP catalog has not been explicitly allowed."
                )
            case .insecureRedirect:
                String(
                    localized: "Winston blocked a redirect from HTTPS to insecure HTTP."
                )
            case .network:
                String(
                    localized: "The catalog couldn’t be reached. Check your connection and try again."
                )
            case .invalidFeed:
                String(
                    localized: "This address didn’t return a supported OPDS catalog."
                )
            case .feedTooLarge:
                String(
                    localized: "The catalog response is too large to open safely."
                )
            case .server(let status):
                String(
                    localized: "The catalog server returned error \(status)."
                )
            }
        }
    }

    private struct Location {
        let url: URL
        var feed: OPDSFeed
    }

    private let settings: AppSettings
    private let service: any OPDSFetching
    private let searchService: OPDSCatalogSearchService
    private let toasts: ToastCenter

    private(set) var phase: Phase = .home
    private(set) var selectedCatalog: OPDSCatalogConfiguration?
    private(set) var isRefreshing = false
    private(set) var isLoadingNextPage = false
    private(set) var refreshFailure: OPDSFailure?
    private(set) var downloadingPublicationIDs: Set<String> = []
    private(set) var downloadedPublicationIDs: Set<String> = []

    private(set) var searchQuery = ""
    private(set) var searchStates: [String: OPDSCatalogSearchState] = [:]
    private(set) var searchGroups: [OPDSSearchResultGroup] = []
    private(set) var isSearching = false
    private(set) var searchWasCancelled = false
    private(set) var activeSearchSeed: CatalogSearchSeed?

    private var history: [Location] = []
    private var requestedURL: URL?
    private var failedURL: URL?
    private var loadGeneration = 0
    private var searchGeneration = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var ownershipIndex = OPDSLocalOwnershipIndex(
        records: []
    )

    init(
        settings: AppSettings,
        toasts: ToastCenter,
        service: any OPDSFetching = OPDSService(),
        searchService: OPDSCatalogSearchService? = nil
    ) {
        self.settings = settings
        self.toasts = toasts
        self.service = service
        self.searchService = searchService
            ?? OPDSCatalogSearchService(client: service)
    }

    var catalogs: [OPDSCatalogConfiguration] {
        settings.catalogConfigurations
    }

    var enabledCatalogs: [OPDSCatalogConfiguration] {
        catalogs.filter(\.isEnabled)
    }

    var feed: OPDSFeed? {
        history.last?.feed
    }

    var canGoBack: Bool {
        selectedCatalog != nil
    }

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
        selectedCatalog != nil && feed?.searchLink != nil
    }

    var searchCompletedCount: Int {
        searchStates.values.filter {
            $0 != .disabled && $0.isComplete
        }.count
    }

    var searchRequestedCount: Int {
        searchStates.values.filter { $0 != .disabled }.count
    }

    var hasPartialSearchFailure: Bool {
        searchStates.values.contains {
            if case .failed = $0 { return true }
            return false
        } && !searchGroups.isEmpty
    }

    func open(_ catalog: OPDSCatalogConfiguration) async {
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
        guard catalog.isEnabled else {
            phase = .failed(.invalidFeed)
            return
        }
        await load(
            catalog.rootURL,
            appendToHistory: true,
            includeRootShortcuts: true
        )
    }

    func open(_ item: OPDSNavigationItem) async {
        guard settings.onlineMetadataEnabled else {
            phase = .disabledOnline
            return
        }
        await load(
            item.url,
            appendToHistory: true,
            includeRootShortcuts: false
        )
    }

    func searchCurrentCatalog(_ query: String) async {
        guard settings.onlineMetadataEnabled,
              let catalog = selectedCatalog,
              let searchLink = feed?.searchLink else {
            return
        }
        do {
            let access = settings.catalogAccess(for: catalog)
            guard let template = try await service.resolvedSearchTemplate(
                for: searchLink,
                access: access
            ),
            let url = OPDSService.expandedSearchURL(
                template: template,
                query: query
            ) else {
                return
            }
            await load(
                url,
                appendToHistory: true,
                includeRootShortcuts: false
            )
        } catch is CancellationError {
            return
        } catch {
            refreshFailure = Self.failure(from: error)
        }
    }

    func retry() async {
        guard settings.onlineMetadataEnabled,
              let url = failedURL
                ?? requestedURL
                ?? history.last?.url
                ?? selectedCatalog?.rootURL else {
            phase = .disabledOnline
            return
        }
        await load(
            url,
            appendToHistory: failedURL != nil || history.isEmpty,
            includeRootShortcuts:
                history.isEmpty && url == selectedCatalog?.rootURL
        )
    }

    func refresh() async {
        guard canRefresh,
              let location = history.last,
              let access = selectedAccess else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        refreshFailure = nil
        loadGeneration += 1
        let generation = loadGeneration
        do {
            var fresh = try await service.feed(
                at: location.url,
                access: access
            )
            guard !Task.isCancelled,
                  generation == loadGeneration else {
                return
            }
            if history.count == 1,
               location.url == selectedCatalog?.rootURL,
               let selectedCatalog {
                fresh = fresh.prependingNavigation(
                    selectedCatalog.presentationShortcuts
                )
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
              let currentURL = history.last?.url,
              let access = selectedAccess else {
            return
        }
        isLoadingNextPage = true
        defer { isLoadingNextPage = false }
        refreshFailure = nil
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let page = try await service.feed(
                at: nextURL,
                access: access
            )
            guard !Task.isCancelled,
                  generation == loadGeneration,
                  history.last?.url == currentURL,
                  let current = history.last?.feed else {
                return
            }
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
        if !settings.onlineMetadataEnabled {
            cancelSearch()
            for task in downloadTasks.values {
                task.cancel()
            }
            guard selectedCatalog != nil else { return }
            phase = .disabledOnline
            return
        }
        guard selectedCatalog != nil else { return }
        if let feed {
            phase = feed.isEmpty ? .empty : .loaded
        } else {
            Task { await retry() }
        }
    }

    func receiveSearchSeed(_ seed: CatalogSearchSeed) {
        activeSearchSeed = seed
        searchQuery = seed.query
        returnHome()
    }

    func performUnifiedSearch(
        _ rawQuery: String,
        ownershipRecords: [LibraryBookRecord]
    ) {
        let query = rawQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return }
        cancelSearch(markCancelled: false)
        searchQuery = query
        activeSearchSeed = nil
        searchWasCancelled = false
        searchGroups = []
        ownershipIndex = OPDSLocalOwnershipIndex(records: ownershipRecords)

        guard settings.onlineMetadataEnabled else {
            searchStates = Dictionary(uniqueKeysWithValues: catalogs.map {
                ($0.id, $0.isEnabled ? .cancelled : .disabled)
            })
            isSearching = false
            return
        }

        let accesses = catalogs.map(settings.catalogAccess)
        searchStates = Dictionary(uniqueKeysWithValues: catalogs.map {
            ($0.id, $0.isEnabled ? .loading : .disabled)
        })
        isSearching = accesses.contains {
            $0.configuration.isEnabled
        }
        searchGeneration += 1
        let generation = searchGeneration
        let stream = searchService.updates(
            accesses: accesses,
            query: query
        )
        searchTask = Task { [weak self] in
            for await update in stream {
                guard let self,
                      !Task.isCancelled,
                      generation == self.searchGeneration else {
                    return
                }
                self.searchStates[update.catalogID] = update.state
                self.rebuildSearchGroups()
            }
            guard let self,
                  generation == self.searchGeneration else {
                return
            }
            self.isSearching = false
        }
    }

    func retrySearch(
        catalogID: String,
        ownershipRecords: [LibraryBookRecord]
    ) {
        guard settings.onlineMetadataEnabled,
              !searchQuery.isEmpty,
              let catalog = catalogs.first(where: {
                  $0.id == catalogID && $0.isEnabled
              }) else {
            return
        }
        ownershipIndex = OPDSLocalOwnershipIndex(records: ownershipRecords)
        searchStates[catalogID] = .loading
        isSearching = true
        let generation = searchGeneration
        let stream = searchService.updates(
            accesses: [settings.catalogAccess(for: catalog)],
            query: searchQuery
        )
        Task { [weak self] in
            for await update in stream {
                guard let self,
                      generation == self.searchGeneration else {
                    return
                }
                self.searchStates[update.catalogID] = update.state
                self.rebuildSearchGroups()
            }
            self?.isSearching = self?.searchStates.values.contains {
                $0 == .loading
            } == true
        }
    }

    func cancelSearch(markCancelled: Bool = true) {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration += 1
        for (catalogID, state) in searchStates where state == .loading {
            searchStates[catalogID] = .cancelled
        }
        isSearching = false
        searchWasCancelled = markCancelled && !searchStates.isEmpty
    }

    func clearSearch() {
        cancelSearch(markCancelled: false)
        searchQuery = ""
        searchStates = [:]
        searchGroups = []
        searchWasCancelled = false
        activeSearchSeed = nil
    }

    func catalogConfiguration(
        id: String
    ) -> OPDSCatalogConfiguration? {
        catalogs.first { $0.id == id }
    }

    func catalogConfigurationDidChange(id: String) {
        Task { await searchService.invalidate(catalogID: id) }
        if selectedCatalog?.id == id {
            returnHome()
        }
        searchStates[id] = nil
        rebuildSearchGroups()
    }

    func catalogConfigurationsWereReset() {
        Task { await searchService.clearCache() }
        returnHome()
        clearSearch()
    }

    func isDownloading(
        _ publication: OPDSPublication,
        catalogID: String? = nil
    ) -> Bool {
        downloadingPublicationIDs.contains(
            downloadID(publication, catalogID: catalogID)
        )
    }

    func isDownloaded(
        _ publication: OPDSPublication,
        catalogID: String? = nil
    ) -> Bool {
        downloadedPublicationIDs.contains(
            downloadID(publication, catalogID: catalogID)
        )
    }

    func cancelDownload(
        _ publication: OPDSPublication,
        catalogID: String? = nil
    ) {
        let id = downloadID(publication, catalogID: catalogID)
        downloadTasks[id]?.cancel()
        downloadTasks[id] = nil
        downloadingPublicationIDs.remove(id)
    }

    func addToLibrary(
        _ publication: OPDSPublication,
        acquisition: OPDSAcquisition,
        catalogID: String? = nil,
        library: LibraryViewModel,
        onSuccessfulImport: (@MainActor ([Book]) -> Void)? = nil
    ) {
        guard settings.onlineMetadataEnabled else {
            toasts.error(
                String(
                    localized: "Turn on online metadata to download catalog books."
                )
            )
            return
        }
        guard acquisition.canImport else {
            toasts.info(
                String(
                    localized: "This acquisition must be opened at its source."
                )
            )
            return
        }
        let catalog = catalogID.flatMap(catalogConfiguration)
            ?? selectedCatalog
        guard let catalog else { return }
        let id = downloadID(publication, catalogID: catalog.id)
        guard downloadingPublicationIDs.insert(id).inserted else {
            return
        }
        let access = settings.catalogAccess(for: catalog)

        let task = Task { [weak self] in
            guard let self else { return }
            var downloadedSource: ImportSource?
            do {
                let source = try await service.download(
                    acquisition,
                    title: publication.title,
                    access: access
                )
                downloadedSource = source
                try Task.checkCancellation()
                library.reviewCatalogBook(
                    from: source,
                    context: CatalogImportContext(
                        catalogID: catalog.id,
                        catalogName: catalog.name,
                        publicationID: publication.id,
                        publicationTitle: publication.title,
                        publicationAuthors: publication.authors,
                        publicationLanguage: publication.language,
                        selectedFormat: acquisition.formatLabel,
                        acquisitionRelation: acquisition.relation
                    )
                ) { [weak self] imported in
                    guard let self else { return }
                    self.downloadingPublicationIDs.remove(id)
                    self.downloadTasks[id] = nil
                    guard !imported.isEmpty else { return }
                    self.downloadedPublicationIDs.insert(id)
                    self.toasts.success(
                        String(
                            localized: "Imported “\(publication.title)” from \(catalog.name)."
                        )
                    )
                    onSuccessfulImport?(imported)
                }
            } catch is CancellationError {
                if let downloadedSource {
                    Self.cleanupUnclaimedSource(downloadedSource)
                }
                self.downloadingPublicationIDs.remove(id)
                self.downloadTasks[id] = nil
            } catch {
                self.downloadingPublicationIDs.remove(id)
                self.downloadTasks[id] = nil
                self.toasts.error(Self.downloadErrorMessage(error))
            }
        }
        downloadTasks[id] = task
    }

    nonisolated private static func cleanupUnclaimedSource(
        _ source: ImportSource
    ) {
        guard let lease = source.ownedLease else { return }
        Task.detached(priority: .utility) {
            try? ImportSourceLeaseStore().remove(lease)
        }
    }

    private var selectedAccess: OPDSCatalogAccess? {
        selectedCatalog.map(settings.catalogAccess)
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
        guard let access = selectedAccess else {
            phase = .failed(.invalidFeed)
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        requestedURL = url
        failedURL = nil
        refreshFailure = nil
        phase = .loading
        do {
            var result = try await service.feed(
                at: url,
                access: access
            )
            guard !Task.isCancelled,
                  generation == loadGeneration else {
                return
            }
            if includeRootShortcuts, let selectedCatalog {
                result = result.prependingNavigation(
                    selectedCatalog.presentationShortcuts
                )
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

    private func rebuildSearchGroups() {
        searchGroups = OPDSSearchAggregator.aggregate(
            states: searchStates,
            catalogNames: Dictionary(
                uniqueKeysWithValues: catalogs.map { ($0.id, $0.name) }
            ),
            ownership: ownershipIndex
        )
    }

    private func downloadID(
        _ publication: OPDSPublication,
        catalogID: String?
    ) -> String {
        "\(catalogID ?? selectedCatalog?.id ?? "catalog")|\(publication.id)"
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
        guard let error = error as? OPDSServiceError else {
            return .network
        }
        switch error {
        case .authenticationRequired:
            return .authenticationRequired
        case .unsupportedCrossOriginAuthentication:
            return .unsupportedAuthentication
        case .insecureTransport:
            return .insecureTransport
        case .insecureRedirect:
            return .insecureRedirect
        case .feedTooLarge:
            return .feedTooLarge
        case .invalidFeed, .invalidURL, .invalidDownload,
             .downloadTooLarge, .unsupportedSearch:
            return .invalidFeed
        case .server(let status):
            return .server(status)
        case .network:
            return .network
        }
    }

    private static func downloadErrorMessage(
        _ error: any Error
    ) -> String {
        guard let error = error as? OPDSServiceError else {
            return String(localized: "The book couldn’t be downloaded.")
        }
        switch error {
        case .authenticationRequired:
            return String(
                localized: "This catalog requires valid download credentials."
            )
        case .unsupportedCrossOriginAuthentication:
            return String(
                localized: "The linked download requires a separate sign-in. Open it at the source instead."
            )
        case .insecureRedirect:
            return String(
                localized: "Winston blocked an insecure download redirect."
            )
        case .downloadTooLarge:
            return String(
                localized: "This book is too large to download safely."
            )
        case .invalidDownload:
            return String(
                localized: "The catalog returned an invalid book file."
            )
        default:
            return String(localized: "The book couldn’t be downloaded.")
        }
    }
}
