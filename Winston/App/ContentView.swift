import SwiftUI
import SwiftData
import OSLog

enum MainDestination: Hashable {
    case library
    case device
    case discover
    case catalogs
    case updates
}

struct ContentView: View {
    var viewModel: LibraryViewModel
    let libraryReadModel: LibraryReadModel

    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings
    @Environment(DeviceMonitor.self) private var deviceMonitor
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
    @Query(sort: \BookCollection.name) private var collections: [BookCollection]

    @SceneStorage("main.sidebarSelection") private var restoredSidebarSelection = SidebarItem.all.rawValue
    @SceneStorage("main.columnVisibility") private var restoredColumnVisibility = "all"
    @State private var sidebarSelection: SidebarItem? = .all
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var folderWatcher = FolderWatcher()
    @State private var watchStability = WatchFolderStabilityTracker()
    @State private var watchScanTask: Task<Void, Never>?
    @State private var activeLibrarySheet: LibrarySheet?
    init(
        viewModel: LibraryViewModel,
        libraryReadModel: LibraryReadModel = LibraryReadModel()
    ) {
        self.viewModel = viewModel
        self.libraryReadModel = libraryReadModel
    }

    private var destination: MainDestination {
        switch sidebarSelection {
        case .device:   .device
        case .discover: .discover
        case .catalogs: .catalogs
        case .updates:  .updates
        default:        .library
        }
    }

    private var filter: LibraryFilter {
        sidebarSelection?.libraryFilter ?? .all
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                books: books,
                collections: collections,
                readModel: libraryReadModel,
                viewModel: viewModel,
                selection: $sidebarSelection,
                onReviewEditions: openEditionReview
            )
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            switch destination {
            case .library:
                if isWishlistSelected {
                    WishlistView(
                        wishlist: viewModel.wishlist,
                        onBrowseDiscover: { sidebarSelection = .discover }
                    )
                } else {
                    LibraryView(
                        books: books,
                        collections: collections,
                        readModel: libraryReadModel,
                        viewModel: viewModel,
                        filter: filter,
                        onShowAll: { sidebarSelection = .all },
                        onShowAuthor: { sidebarSelection = .author($0) },
                        onShowSeries: { sidebarSelection = .series($0) },
                        columnVisibility: $columnVisibility,
                        activeSheet: $activeLibrarySheet
                    )
                }
            case .device:
                DeviceView(books: books, viewModel: viewModel)
            case .discover:
                DiscoveryView(wishlist: viewModel.wishlist)
            case .catalogs:
                OPDSCatalogView(library: viewModel)
            case .updates:
                NoticesView(
                    notices: viewModel.notices,
                    viewModel: viewModel,
                    onOpenSeries: { sidebarSelection = .series($0) }
                )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            LibraryStatusToasts(
                viewModel: viewModel,
                maintenance: viewModel.maintenance,
                onReviewEditions: openEditionReview
            )
        }
        .background {
            LibraryReadModelSyncView(
                readModel: libraryReadModel,
                books: books,
                collections: collections
            )
        }
        .tint(theme.accent)
        .task {
            StartupPerformance.markInteractive()
            Log.persistenceSignposter.emitEvent(
                "LibraryInteractive",
                id: Log.persistenceSignposter.makeSignpostID()
            )
            restoreSceneState()
            normalizeRestoredDestination()
            deviceMonitor.start()
            restartWatcher()
            await viewModel.notices.checkForNewReleasesIfDue()
        }
        .task(priority: .background) {
            viewModel.maintenance.start()
        }
        .task(id: metadataBackfillConfiguration, priority: .background) {
            guard settings.onlineMetadataEnabled else { return }
            try? await Task.sleep(for: .seconds(8))
            while viewModel.maintenance.isActive {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await viewModel.backfillOnlineMetadata()
            await viewModel.notices.checkForNewReleasesIfDue()
        }
        .onChange(of: deviceMonitor.isConnected) { _, connected in
            if !connected, sidebarSelection == .device { sidebarSelection = .all }
        }
        .onChange(of: sidebarSelection) { _, selection in
            restoredSidebarSelection = selection?.rawValue ?? SidebarItem.all.rawValue
        }
        .onChange(of: columnVisibility) { _, visibility in
            restoredColumnVisibility = Self.storageValue(for: visibility)
        }
        .onChange(of: settings.watchFolderEnabled) { _, _ in restartWatcher() }
        .onChange(of: settings.watchFolderPath) { _, _ in restartWatcher() }
        .onChange(of: settings.showDiscoverInSidebar) { _, isVisible in
            if !isVisible, sidebarSelection == .discover { sidebarSelection = .all }
        }
        .onChange(of: settings.showCatalogsInSidebar) { _, isVisible in
            if !isVisible, sidebarSelection == .catalogs { sidebarSelection = .all }
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchFolderChanged)) { _ in
            scheduleWatchScan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDiscoverDestination)) { _ in
            sidebarSelection = .discover
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCatalogsDestination)) { _ in
            sidebarSelection = .catalogs
        }
        .onDisappear {
            watchScanTask?.cancel()
            viewModel.cancelLongRunningSessions()
        }
    }

    private var metadataBackfillConfiguration: String {
        "\(settings.onlineMetadataEnabled)|\(settings.hardcoverToken.hashValue)|\(settings.releaseCheckEnabled)"
    }

    private func openEditionReview() {
        sidebarSelection = .all
        Task { @MainActor in
            await Task.yield()
            activeLibrarySheet = .editionReview
        }
    }

    private var isWishlistSelected: Bool {
        guard case .collection(let id) = sidebarSelection else { return false }
        return collections.contains { $0.id == id && $0.isWishlist }
    }

    private func normalizeRestoredDestination() {
        switch sidebarSelection {
        case .discover where !settings.showDiscoverInSidebar,
             .catalogs where !settings.showCatalogsInSidebar:
            sidebarSelection = .all
        case .collection(let id) where !collections.contains(where: { $0.id == id }):
            sidebarSelection = .all
        default:
            break
        }
    }

    private func restoreSceneState() {
        sidebarSelection = SidebarItem(rawValue: restoredSidebarSelection) ?? .all
        columnVisibility = Self.columnVisibility(for: restoredColumnVisibility)
    }

    private static func storageValue(for visibility: NavigationSplitViewVisibility) -> String {
        if visibility == .detailOnly { return "detailOnly" }
        if visibility == .doubleColumn { return "doubleColumn" }
        if visibility == .automatic { return "automatic" }
        return "all"
    }

    private static func columnVisibility(for value: String) -> NavigationSplitViewVisibility {
        switch value {
        case "detailOnly": .detailOnly
        case "doubleColumn": .doubleColumn
        case "automatic": .automatic
        default: .all
        }
    }

    // MARK: - Watch folder

    private func restartWatcher() {
        folderWatcher.stop()
        watchScanTask?.cancel()
        Task { await watchStability.reset() }
        guard settings.watchFolderEnabled, let path = settings.watchFolderPath else { return }
        folderWatcher.start(path: path)
        scheduleWatchScan()
    }

    private func scheduleWatchScan() {
        watchScanTask?.cancel()
        watchScanTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard settings.watchFolderEnabled, let path = settings.watchFolderPath else { return }
                let directory = URL(fileURLWithPath: path)
                let result = await watchStability.scan(directory: directory)
                guard !Task.isCancelled,
                      settings.watchFolderEnabled,
                      settings.watchFolderPath == path else { return }
                if !result.ready.isEmpty { viewModel.addBooks(from: result.ready) }
                if !result.needsPolling { return }
            }
        }
    }

}

private struct LibraryReadModelSyncView: View {
    let readModel: LibraryReadModel
    let books: [Book]
    let collections: [BookCollection]

    @Environment(DeviceMonitor.self) private var deviceMonitor

    private struct Revision: Hashable {
        let catalogRevision: Int
        let bookCount: Int
        let collectionCount: Int
        let deviceFileNames: Set<String>
        let deviceIsConnected: Bool
    }

    private var revision: Revision {
        Revision(
            catalogRevision: LibraryMutationLog.shared.catalogRevision,
            bookCount: books.count,
            collectionCount: collections.count,
            deviceFileNames: deviceMonitor.deviceFileNames,
            deviceIsConnected: deviceMonitor.isConnected
        )
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: revision) {
                let delta = LibraryMutationLog.shared.catalogDelta(
                    since: readModel.catalogRevision
                )
                await readModel.synchronize(
                    books: books,
                    collections: collections,
                    delta: delta,
                    deviceFileNames: revision.deviceFileNames,
                    deviceIsConnected: revision.deviceIsConnected
                )
            }
    }
}

#Preview("Purple") {
    let container = PersistenceController.inMemory()
    ContentView(viewModel: LibraryViewModel(modelContext: container.mainContext, settings: AppSettings(), toasts: ToastCenter()))
        .modelContainer(container)
        .environment(ThemeManager())
        .environment(DeviceMonitor())
        .environment(KindleSyncProfileStore())
        .environment(TransferQueue(toasts: ToastCenter()))
        .environment(ToastCenter())
        .environment(AppSettings())
        .environment(DiscoveryViewModel(settings: AppSettings()))
        .environment(OPDSViewModel(settings: AppSettings(), toasts: ToastCenter()))
        .environment(\.theme, .purple)
        .frame(width: 1100, height: 700)
}

#Preview("White") {
    let container = PersistenceController.inMemory()
    ContentView(viewModel: LibraryViewModel(modelContext: container.mainContext, settings: AppSettings(), toasts: ToastCenter()))
        .modelContainer(container)
        .environment(ThemeManager())
        .environment(DeviceMonitor())
        .environment(KindleSyncProfileStore())
        .environment(TransferQueue(toasts: ToastCenter()))
        .environment(ToastCenter())
        .environment(AppSettings())
        .environment(DiscoveryViewModel(settings: AppSettings()))
        .environment(OPDSViewModel(settings: AppSettings(), toasts: ToastCenter()))
        .environment(\.theme, .white)
        .frame(width: 1100, height: 700)
}
