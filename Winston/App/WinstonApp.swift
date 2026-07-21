import SwiftUI
import SwiftData
import OSLog

private enum StartupMigrationCheckpoint {
    private static let catalogV2Key = "migration.catalog-assets-reading-history.v2"

    @MainActor
    static func runIfNeeded(
        context: ModelContext,
        defaults: UserDefaults = .standard,
        restoreApplied: Bool = PersistenceController.restoreAppliedAtLaunch
    ) {
        // A restored backup may predate these backfills; the swapped-in store must earn the checkpoint again.
        if restoreApplied {
            defaults.removeObject(forKey: catalogV2Key)
        }
        guard !defaults.bool(forKey: catalogV2Key) else { return }
        EditionsBackfill.run(context: context)
        ReadingHistoryBackfill.run(context: context)
        EditionsBackfill.pruneOrphanWorks(context: context)
        guard !context.hasChanges else { return }
        defaults.set(true, forKey: catalogV2Key)
    }
}

@main
struct WinstonApp: App {
    private let container: ModelContainer
    @State private var themeManager = ThemeManager()
    @State private var settings: AppSettings
    @State private var toastCenter: ToastCenter
    @State private var viewModel: LibraryViewModel
    @State private var deviceMonitor = DeviceMonitor()
    @State private var kindleSyncProfiles: KindleSyncProfileStore
    @State private var transferQueue: TransferQueue
    @State private var updater: SoftwareUpdater
    @State private var pluginService: PluginService
    @State private var discoveryViewModel: DiscoveryViewModel
    @State private var opdsViewModel: OPDSViewModel
    @State private var showStoreRecoveryNotice: Bool

    init() {
        let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let container = isRunningUnitTests ? PersistenceController.inMemory() : PersistenceController.shared
        self.container = container
        _showStoreRecoveryNotice = State(
            initialValue: !isRunningUnitTests && PersistenceController.lastRecovery != nil
        )
        let context = container.mainContext
        if !isRunningUnitTests {
            let signposter = Log.persistenceSignposter
            let interval = signposter.beginInterval(
                "StartupMigrations",
                id: signposter.makeSignpostID()
            )
            LegacyLibraryMigrator.migrateIfNeeded(context: context)
            StartupMigrationCheckpoint.runIfNeeded(context: context)
            signposter.endInterval("StartupMigrations", interval)
        }
        let settings = AppSettings()
        let toastCenter = ToastCenter()
        _settings = State(initialValue: settings)
        _toastCenter = State(initialValue: toastCenter)
        let viewModel = LibraryViewModel(modelContext: context, settings: settings, toasts: toastCenter)
        _viewModel = State(initialValue: viewModel)
        let kindleSyncProfiles = KindleSyncProfileStore()
        _kindleSyncProfiles = State(initialValue: kindleSyncProfiles)
        _transferQueue = State(initialValue: TransferQueue(
            toasts: toastCenter,
            onConversionArtifact: { bookUUID, url in
                await viewModel.adoptConversionArtifact(for: bookUUID, from: url)
            },
            onTransferCompleted: { record in
                kindleSyncProfiles.record(record)
            }
        ))
        _updater = State(initialValue: SoftwareUpdater())
        _pluginService = State(initialValue: PluginService(modelContext: context, settings: settings, toasts: toastCenter))
        _discoveryViewModel = State(initialValue: DiscoveryViewModel(settings: settings))
        _opdsViewModel = State(initialValue: OPDSViewModel(settings: settings, toasts: toastCenter))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .environment(themeManager)
                .environment(settings)
                .environment(deviceMonitor)
                .environment(kindleSyncProfiles)
                .environment(transferQueue)
                .environment(toastCenter)
                .environment(pluginService)
                .environment(discoveryViewModel)
                .environment(opdsViewModel)
                .accessibleTheme(themeManager.theme)
                .font(themeManager.defaultFont)
                .preferredColorScheme(themeManager.theme.colorScheme)
                .task { await pluginService.refresh() }
                .alert("Library Database Reset", isPresented: $showStoreRecoveryNotice) {
                    Button("OK", role: .cancel) {}
                } message: {
                    if case .recreatedAfterCorruption(let backupPath) = PersistenceController.lastRecovery,
                       let backupPath {
                        Text("Your library database couldn’t be opened, so Winston started with a fresh one. The old file was kept at \(backupPath) — restoring a backup from Settings may bring your catalog back.")
                    } else {
                        Text("Your library database couldn’t be opened, so Winston started with a fresh one. Restoring a backup from Settings may bring your catalog back.")
                    }
                }
        }
        .modelContainer(container)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 1100, height: 700)
        .commands {
            AppCommands(themeManager: themeManager, settings: settings, updater: updater)
        }

        Settings {
            SettingsView()
                .modelContainer(container)
                .environment(themeManager)
                .environment(settings)
                .environment(pluginService)
                .accessibleTheme(themeManager.theme)
                .font(themeManager.defaultFont)
                .preferredColorScheme(themeManager.theme.colorScheme)
        }
    }
}
