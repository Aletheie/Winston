import AppKit
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

private enum LibraryStartupState: Equatable {
    case preparing
    case ready
    case managedFileRecoveryFailed(pendingItemCount: Int)
    case legacyMigrationFailed
}

@main
private enum WinstonEntryPoint {
    static func main() {
        if PluginWorkerProcessMain.isWorkerInvocation {
            PluginWorkerProcessMain.run()
        }
        WinstonApp.main()
    }
}

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
    @State private var libraryStartupState: LibraryStartupState

    init() {
        let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let container = isRunningUnitTests ? PersistenceController.inMemory() : PersistenceController.shared
        self.container = container
        _showStoreRecoveryNotice = State(
            initialValue: !isRunningUnitTests && {
                if case .quarantined = PersistenceController.lastRecovery { return true }
                return false
            }()
        )
        let context = container.mainContext
        let mayUseLibrary = PersistenceController.lastRecovery?.allowsLibraryAccess ?? true
        _libraryStartupState = State(
            initialValue: !isRunningUnitTests && mayUseLibrary ? .preparing : .ready
        )
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
            Group {
                if let recovery = PersistenceController.lastRecovery,
                   !recovery.allowsLibraryAccess {
                    StoreUnavailableView(recovery: recovery)
                } else {
                    switch libraryStartupState {
                    case .preparing:
                        LibraryStartupProgressView()
                            .task { await prepareLibrary() }
                    case .ready:
                        ContentView(viewModel: viewModel)
                            .task { await pluginService.refresh() }
                    case .managedFileRecoveryFailed(let pendingItemCount):
                        ManagedFileRecoveryUnavailableView(
                            pendingItemCount: pendingItemCount,
                            onRetry: { libraryStartupState = .preparing }
                        )
                    case .legacyMigrationFailed:
                        LegacyMigrationUnavailableView(
                            onRetry: { libraryStartupState = .preparing }
                        )
                    }
                }
            }
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
                .alert("Library Database Recovered", isPresented: $showStoreRecoveryNotice) {
                    Button("OK", role: .cancel) {}
                } message: {
                    if case .quarantined(let snapshotURL) = PersistenceController.lastRecovery {
                        Text("Winston confirmed that the library database was corrupt and preserved a verified recovery snapshot at \(snapshotURL.path(percentEncoded: false)) before creating a fresh database.")
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
            Group {
                if let recovery = PersistenceController.lastRecovery,
                   !recovery.allowsLibraryAccess {
                    StoreUnavailableView(recovery: recovery)
                } else if libraryStartupState == .ready {
                    SettingsView()
                } else {
                    LibraryStartupProgressView()
                }
            }
                .modelContainer(container)
                .environment(themeManager)
                .environment(settings)
                .environment(pluginService)
                .accessibleTheme(themeManager.theme)
                .font(themeManager.defaultFont)
                .preferredColorScheme(themeManager.theme.colorScheme)
        }
    }

    @MainActor
    private func prepareLibrary() async {
        let signposter = Log.persistenceSignposter
        let interval = signposter.beginInterval(
            "StartupMigrations",
            id: signposter.makeSignpostID()
        )
        defer { signposter.endInterval("StartupMigrations", interval) }

        let recovery = await viewModel.recoverManagedFiles()
        guard !recovery.hasPendingWork else {
            libraryStartupState = .managedFileRecoveryFailed(
                pendingItemCount: recovery.failedTransactionIDs.count
                    + recovery.unreadableJournalURLs.count
                    + recovery.failureMessages.count
            )
            return
        }
        guard await viewModel.migrateLegacyLibraryIfNeeded() else {
            libraryStartupState = .legacyMigrationFailed
            return
        }
        StartupMigrationCheckpoint.runIfNeeded(context: container.mainContext)
        libraryStartupState = .ready
    }
}

private struct LibraryStartupProgressView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Preparing Library")
                .font(.headline)
            Text("Winston is completing pending file operations before opening the catalog.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ManagedFileRecoveryUnavailableView: View {
    let pendingItemCount: Int
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Library Files Need Attention")
                .font(.title2.bold())
            Text("Winston could not safely finish \(pendingItemCount) pending file operation(s). The catalog remains closed so it cannot expose incomplete books or covers.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            HStack {
                Button("Retry", action: onRetry)
                Button("Quit Winston") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LegacyMigrationUnavailableView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Legacy Library Migration Paused")
                .font(.title2.bold())
            Text("The original legacy catalog remains untouched. Resolve the file access problem, then retry the migration.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            HStack {
                Button("Retry", action: onRetry)
                Button("Quit Winston") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StoreUnavailableView: View {
    let recovery: PersistenceController.Recovery

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Library Unavailable")
                .font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560)
            if let snapshotURL {
                Text("Recovery files: \(snapshotURL.path(percentEncoded: false))")
                    .font(.caption)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            Text(failureMessage)
                .font(.caption)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            HStack {
                if let snapshotURL {
                    Button("Show Recovery Files") {
                        NSWorkspace.shared.activateFileViewerSelecting([snapshotURL])
                    }
                }
                Button("Quit Winston") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var message: LocalizedStringResource {
        switch recovery {
        case .retryableFailure:
            "Winston couldn’t open your library because of a storage or access problem. The original database was left untouched. Resolve the problem and reopen Winston."
        case .migrationRequired:
            "This library needs a compatible database migration. The original database was left untouched and no empty library was created."
        case .readOnlyRecovery:
            "Recovery could not finish safely. Winston did not activate an empty persistent library; use the preserved files or a backup to recover your catalog."
        case .quarantined:
            "The library is available."
        }
    }

    private var snapshotURL: URL? {
        switch recovery {
        case .readOnlyRecovery(let snapshotURL, _): snapshotURL
        default: nil
        }
    }

    private var failureMessage: String {
        switch recovery {
        case .retryableFailure(let failure),
             .migrationRequired(let failure),
             .readOnlyRecovery(_, let failure):
            "\(failure.domain) (\(failure.code)): \(failure.message)"
        case .quarantined:
            ""
        }
    }
}
