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
    @Environment(OPDSViewModel.self) private var opdsViewModel

    @SceneStorage("main.sidebarSelection") private var restoredSidebarSelection = SidebarItem.all.rawValue
    @SceneStorage("main.columnVisibility") private var restoredColumnVisibility = "all"
    @State private var sidebarSelection: SidebarItem? = .all
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var folderWatcher = FolderWatcher()
    @State private var watchStability = WatchFolderStabilityTracker()
    @State private var watchScanTask: Task<Void, Never>?
    @State private var activeLibrarySheet: LibrarySheet?
    @State private var showImportReview = false
    @State private var projectionStore = LibraryProjectionStore()
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
        let _ = LibraryPerformanceDiagnostics.recordBody("ContentViewBody")
        let books = projectionStore.books
        let collections = projectionStore.collections
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
                DeviceView(
                    books: books,
                    readModel: libraryReadModel,
                    viewModel: viewModel
                )
            case .discover:
                DiscoveryView(wishlist: viewModel.wishlist)
            case .catalogs:
                OPDSCatalogView(
                    library: viewModel,
                    readModel: libraryReadModel
                )
            case .updates:
                NoticesView(
                    notices: viewModel.notices,
                    viewModel: viewModel,
                    onOpenSeries: { sidebarSelection = .series($0) }
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            LibraryProjectionStatusBanner(
                store: projectionStore,
                onRetry: projectionStore.requestRetry
            )
        }
        .overlay(alignment: .bottomTrailing) {
            LibraryStatusToasts(
                viewModel: viewModel,
                maintenance: viewModel.maintenance,
                onReviewEditions: openEditionReview,
                onReviewImport: openImportReview,
                onResolveDigitalFile: resolveDigitalFile
            )
        }
        .background {
            LibraryReadModelSyncView(
                readModel: libraryReadModel,
                projectionStore: projectionStore
            )
        }
        .sheet(isPresented: $showImportReview, onDismiss: importReviewDidDismiss) {
            ImportReviewSheet(
                viewModel: viewModel,
                onShowImportedBooks: showImportedBooks,
                onReviewIssues: showImportIssues
            )
        }
        .tint(theme.accent)
        .task {
            StartupPerformance.markInteractive()
            Log.persistenceSignposter.emitEvent(
                "LibraryInteractive",
                id: Log.persistenceSignposter.makeSignpostID()
            )
            if LibraryPerformanceConfiguration.isScenarioEnabled {
                sidebarSelection = .all
                columnVisibility = .all
                return
            }
            restoreSceneState()
            normalizeRestoredDestination()
            deviceMonitor.start()
            restartWatcher()
            await viewModel.notices.checkForNewReleasesIfDue()
        }
        .task(priority: .background) {
            guard !LibraryPerformanceConfiguration.isScenarioEnabled else { return }
            viewModel.maintenance.start()
        }
        .task(id: metadataBackfillConfiguration, priority: .background) {
            guard !LibraryPerformanceConfiguration.isScenarioEnabled else { return }
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
        .task(id: libraryReadModel.isReady) {
            await LibraryPerformanceScenario.run(
                books: books,
                collections: collections,
                readModel: libraryReadModel,
                viewModel: viewModel
            )
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
        .onChange(of: importReviewPresentation) { _, presentation in
            guard let presentation else {
                showImportReview = false
                return
            }
            switch presentation.phase {
            case .preparing:
                if presentation.requestedCount > 1
                    || settings.alwaysReviewImports {
                    showImportReview = true
                }
            case .ready, .failed:
                showImportReview = true
            case .committing, .completed:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchFolderChanged)) { _ in
            scheduleWatchScan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDiscoverDestination)) { _ in
            sidebarSelection = .discover
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCatalogsDestination)) { notification in
            sidebarSelection = .catalogs
            if let seed = notification.object as? CatalogSearchSeed {
                viewModelIfAvailableReceive(seed)
            }
        }
        .onDisappear {
            watchScanTask?.cancel()
            viewModel.cancelLongRunningSessions()
        }
    }

    private func viewModelIfAvailableReceive(_ seed: CatalogSearchSeed) {
        // The environment-owned catalog model survives destination changes,
        // so a source view can hand it a Sendable seed without retaining UI.
        let model = opdsViewModel
        model.receiveSearchSeed(seed)
    }

    private var metadataBackfillConfiguration: String {
        "\(settings.onlineMetadataEnabled)|\(settings.hardcoverToken.hashValue)|\(settings.releaseCheckEnabled)"
    }

    private struct ImportReviewPresentation: Equatable {
        enum Phase: Equatable {
            case preparing
            case ready
            case committing
            case completed
            case failed
        }

        let id: UUID
        let requestedCount: Int
        let phase: Phase
    }

    private var importReviewPresentation: ImportReviewPresentation? {
        guard let batch = viewModel.preparedImportBatch else { return nil }
        let phase: ImportReviewPresentation.Phase = switch batch.phase {
        case .preparing: .preparing
        case .ready: .ready
        case .committing: .committing
        case .completed: .completed
        case .failed: .failed
        }
        return ImportReviewPresentation(
            id: batch.id,
            requestedCount: batch.requestedCount,
            phase: phase
        )
    }

    private func importReviewDidDismiss() {
        guard let batch = viewModel.preparedImportBatch else { return }
        switch batch.phase {
        case .preparing, .ready, .committing:
            viewModel.cancelImportReview()
        case .completed, .failed:
            viewModel.dismissImportReviewResult()
        }
    }

    private func showImportedBooks(_ bookIDs: [UUID]) {
        if destination != .library {
            sidebarSelection = .all
        }
        Task { @MainActor in
            await Task.yield()
            NotificationCenter.default.post(
                name: .showImportedBooks,
                object: nil,
                userInfo: ["bookIDs": bookIDs]
            )
        }
    }

    private func showImportIssues() {
        sidebarSelection = .all
        Task { @MainActor in
            await Task.yield()
            activeLibrarySheet = .importRecovery
        }
    }

    private func openEditionReview() {
        sidebarSelection = .all
        Task { @MainActor in
            await Task.yield()
            activeLibrarySheet = .editionReview
        }
    }

    private func openImportReview() {
        sidebarSelection = .all
        Task { @MainActor in
            await Task.yield()
            activeLibrarySheet = .importRecovery
        }
    }

    private func resolveDigitalFile(_ bookID: UUID) {
        guard let book = libraryReadModel.book(uuid: bookID) else { return }
        Task {
            await LibraryExternalActions.relink(book, via: viewModel)
        }
    }

    private var isWishlistSelected: Bool {
        guard case .collection(let id) = sidebarSelection else { return false }
        return projectionStore.collections.contains { $0.id == id && $0.isWishlist }
    }

    private func normalizeRestoredDestination() {
        switch sidebarSelection {
        case .discover where !settings.showDiscoverInSidebar,
             .catalogs where !settings.showCatalogsInSidebar:
            sidebarSelection = .all
        case .collection(let id)
            where !projectionStore.collections.contains(where: { $0.id == id }):
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
    let projectionStore: LibraryProjectionStore

    @Environment(\.modelContext) private var modelContext
    @Environment(DeviceMonitor.self) private var deviceMonitor

    private struct Revision: Hashable {
        let catalogRevision: Int
        let deviceInventoryGeneration: Int
        let deviceFileNames: Set<String>
        let deviceIsConnected: Bool
        let projectionRetryRequestID: Int
    }

    private var revision: Revision {
        Revision(
            catalogRevision: LibraryMutationLog.shared.catalogRevision,
            deviceInventoryGeneration: deviceMonitor.inventoryGeneration,
            deviceFileNames: deviceMonitor.deviceFileNames,
            deviceIsConnected: deviceMonitor.isConnected,
            projectionRetryRequestID: projectionStore.retryRequestID
        )
    }

    var body: some View {
        let _ = LibraryPerformanceDiagnostics.recordBody("LibraryReadModelSyncViewBody")
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: revision) {
                let requestedRevision = revision
                let synchronizationToken = projectionStore.beginSynchronization()
                let wasReady = readModel.isReady
                let synchronized = await projectionStore.synchronizeWithRetry(
                    context: modelContext,
                    delta: {
                        LibraryMutationLog.shared.catalogDelta(
                            since: projectionStore.generation
                        )
                    },
                    token: synchronizationToken
                )
                guard synchronized,
                      !Task.isCancelled,
                      projectionStore.synchronizationIsCurrent(
                        synchronizationToken
                      ),
                      requestedRevision == revision else { return }
                let books = projectionStore.books
                let collections = projectionStore.collections
                if LibraryPerformanceConfiguration.isScenarioEnabled, !wasReady {
                    LibraryPerformanceDiagnostics.writeOutput(
                        "WINSTON_LIBRARY_PERFORMANCE_SYNC_STARTED books=\(books.count)"
                    )
                }
                let readDelta = LibraryMutationLog.shared.catalogDelta(
                    since: readModel.generation
                )
                guard requestedRevision.deviceInventoryGeneration
                        == deviceMonitor.inventoryGeneration else {
                    return
                }
                let deviceInventoryDelta = deviceMonitor.lastInventoryDelta
                await readModel.synchronize(
                    books: books,
                    collections: collections,
                    delta: readDelta,
                    deviceFileNames: requestedRevision.deviceFileNames,
                    deviceIsConnected: requestedRevision.deviceIsConnected,
                    deviceInventoryDelta: deviceInventoryDelta
                )
                guard !Task.isCancelled,
                      projectionStore.synchronizationIsCurrent(
                        synchronizationToken
                      ),
                      requestedRevision == revision else { return }
                if LibraryPerformanceConfiguration.isScenarioEnabled, !wasReady {
                    LibraryPerformanceDiagnostics.writeOutput(
                        "WINSTON_LIBRARY_PERFORMANCE_SYNC_FINISHED generation=\(readModel.generation)"
                    )
                    LibraryPerformanceDiagnostics.endInitialLoad()
                }
            }
    }
}

private struct LibraryProjectionStatusBanner: View {
    let store: LibraryProjectionStore
    let onRetry: () -> Void

    var body: some View {
        switch store.status {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Group {
                    if store.isReady {
                        Text("Refreshing library…")
                    } else {
                        Text("Loading library…")
                    }
                }
                .font(.callout)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }

        case .stale(_, _, let failure):
            failureBanner(
                title: "Library data may be out of date.",
                failure: failure
            )

        case .failed(let failure):
            failureBanner(
                title: "Couldn’t load the library.",
                failure: failure
            )

        case .ready:
            EmptyView()
        }
    }

    private func failureBanner(
        title: LocalizedStringKey,
        failure: LibraryProjectionFailure
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(verbatim: failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if failure.isRetryable {
                Button("Retry", action: onRetry)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
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
