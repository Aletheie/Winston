import SwiftUI
import SwiftData

@main
struct WinstonApp: App {
    private let container: ModelContainer
    @State private var themeManager = ThemeManager()
    @State private var settings: AppSettings
    @State private var toastCenter: ToastCenter
    @State private var viewModel: LibraryViewModel
    @State private var deviceMonitor = DeviceMonitor()
    @State private var transferQueue: TransferQueue
    @State private var updater: SoftwareUpdater
    @State private var pluginService: PluginService
    @State private var discoveryViewModel: DiscoveryViewModel
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
            LegacyLibraryMigrator.migrateIfNeeded(context: context)
            EditionsBackfill.run(context: context)
            EditionsBackfill.pruneOrphanWorks(context: context)
        }
        let settings = AppSettings()
        let toastCenter = ToastCenter()
        _settings = State(initialValue: settings)
        _toastCenter = State(initialValue: toastCenter)
        _viewModel = State(initialValue: LibraryViewModel(modelContext: context, settings: settings, toasts: toastCenter))
        _transferQueue = State(initialValue: TransferQueue(toasts: toastCenter))
        _updater = State(initialValue: SoftwareUpdater())
        _pluginService = State(initialValue: PluginService(modelContext: context, settings: settings, toasts: toastCenter))
        _discoveryViewModel = State(initialValue: DiscoveryViewModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .environment(themeManager)
                .environment(settings)
                .environment(deviceMonitor)
                .environment(transferQueue)
                .environment(toastCenter)
                .environment(pluginService)
                .environment(discoveryViewModel)
                .environment(\.theme, themeManager.theme)
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
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 700)
        .commands {
            AppCommands(themeManager: themeManager, settings: settings, updater: updater)
        }

        Settings {
            SettingsView()
                .environment(themeManager)
                .environment(settings)
                .environment(pluginService)
                .environment(\.theme, themeManager.theme)
                .font(themeManager.defaultFont)
                .preferredColorScheme(themeManager.theme.colorScheme)
        }
    }
}
