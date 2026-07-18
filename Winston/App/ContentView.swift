import SwiftUI
import SwiftData

enum MainDestination: Hashable {
    case library
    case device
    case discover
    case catalogs
    case updates
}

struct ContentView: View {
    var viewModel: LibraryViewModel

    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings
    @Environment(DeviceMonitor.self) private var deviceMonitor
    @Environment(ToastCenter.self) private var toasts
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
    @Query(sort: \BookCollection.name) private var collections: [BookCollection]

    @State private var sidebarSelection: SidebarItem? = .all
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var folderWatcher = FolderWatcher()
    @State private var watchStability = WatchFolderStabilityTracker()
    @State private var watchScanTask: Task<Void, Never>?
    @State private var activeLibrarySheet: LibrarySheet?

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
                        viewModel: viewModel,
                        filter: filter,
                        onShowAll: { sidebarSelection = .all },
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
            LibraryStatusToasts(viewModel: viewModel, onReviewEditions: openEditionReview)
        }
        .tint(theme.accent)
        .task {
            deviceMonitor.start()
            restartWatcher()
            await viewModel.notices.checkForNewReleasesIfDue()
        }
        .task(priority: .background) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await checkIntegrityAndBackup()
            guard !Task.isCancelled else { return }
            await viewModel.backfillMissingSizes()
            guard !Task.isCancelled else { return }
            await viewModel.detectMissingDRM()
            guard !Task.isCancelled else { return }
            await viewModel.backfillMissingAssetHashes()
            guard !Task.isCancelled else { return }
            await viewModel.editions.scanLibrary()
            guard !Task.isCancelled else { return }
            await viewModel.rescanMissingMetadata()
        }
        .task(id: metadataBackfillConfiguration, priority: .background) {
            guard settings.onlineMetadataEnabled else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            viewModel.backfillOnlineMetadata()
            await viewModel.notices.checkForNewReleasesIfDue()
        }
        .onChange(of: deviceMonitor.isConnected) { _, connected in
            if !connected, sidebarSelection == .device { sidebarSelection = .all }
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
    }

    private var metadataBackfillConfiguration: String {
        "\(settings.onlineMetadataEnabled)|\(settings.hardcoverToken)|\(settings.releaseCheckEnabled)"
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

    // MARK: - Integrity & backup

    private func checkIntegrityAndBackup() async {
        let missing = await viewModel.scanForMissingFiles()
        if missing > 0 {
            toasts.error(String(localized: "Some book files are missing (\(missing))."))
        }
        runAutoBackupIfDue()
    }

    private func runAutoBackupIfDue() {
        guard settings.autoBackupEnabled, let path = settings.backupFolderPath else { return }
        let due = settings.lastBackupAt.map { Date.now.timeIntervalSince($0) > 24 * 3600 } ?? true
        guard due else { return }
        let folder = URL(fileURLWithPath: path)
        Task {
            do {
                _ = try await Task.detached(priority: .utility) {
                    try LibraryBackup.backup(storeURL: PersistenceController.storeURL,
                                             coversDirectory: AppPaths.coversDirectory,
                                             to: folder)
                }.value
                settings.lastBackupAt = .now
                toasts.info(String(localized: "Library backed up."))
            } catch {
                toasts.error(String(localized: "Backup failed."))
            }
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
