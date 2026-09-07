import AppKit
import Darwin
import SwiftUI
import SwiftData
import OSLog

private enum LibraryStartupState: Equatable {
    case preparing
    case ready
}

@main
private enum WinstonEntryPoint {
    static func main() {
        if PluginWorkerProcessMain.isWorkerInvocation {
            PluginWorkerProcessMain.run()
        }
        do {
            try LibraryPerformanceConfiguration.configureAppPathsIfNeeded()
            if let request = try LibraryPerformanceConfiguration.preparationRequest() {
                try LibraryPerformanceDatasetBuilder.prepare(request)
                FileHandle.standardOutput.write(Data(
                    "WINSTON_LIBRARY_PERFORMANCE_PREPARED books=\(request.bookCount) root=\(request.rootDirectory.path)\n".utf8
                ))
                return
            }
        } catch {
            FileHandle.standardError.write(Data(
                "WINSTON_LIBRARY_PERFORMANCE_PREPARATION_FAILED \(error.localizedDescription)\n".utf8
            ))
            Darwin.exit(EXIT_FAILURE)
        }
        StartupPerformance.begin()
        LibraryPerformanceDiagnostics.beginInitialLoad()
        WinstonApp.main()
    }
}

struct WinstonApp: App {
    private let container: ModelContainer
    private let languageAtLaunch: AppLanguage
    @State private var themeManager = ThemeManager()
    @State private var settings: AppSettings
    @State private var toastCenter: ToastCenter
    @State private var viewModel: LibraryViewModel
    @State private var libraryReadModel: LibraryReadModel
    @State private var deviceMonitor = DeviceMonitor()
    @State private var kindleSyncProfiles: KindleSyncProfileStore
    @State private var transferQueue: TransferQueue
    @State private var operationReports = OperationReportStore()
    @State private var pluginService: PluginService
    @State private var discoveryViewModel: DiscoveryViewModel
    @State private var opdsViewModel: OPDSViewModel
    @State private var libraryStartupState: LibraryStartupState

    init() {
        let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let container = isRunningUnitTests ? PersistenceController.inMemory() : PersistenceController.shared
        self.container = container
        let context = container.mainContext
        let mayUseLibrary = PersistenceController.lastRecovery?.allowsLibraryAccess ?? true
        _libraryStartupState = State(
            initialValue: !isRunningUnitTests && mayUseLibrary
                ? .preparing
                : .ready
        )
        let settings = AppSettings()
        languageAtLaunch = settings.appLanguage
        let toastCenter = ToastCenter()
        _settings = State(initialValue: settings)
        _toastCenter = State(initialValue: toastCenter)
        let viewModel = LibraryViewModel(modelContext: context, settings: settings, toasts: toastCenter)
        _viewModel = State(initialValue: viewModel)
        let libraryReadModel = LibraryReadModel()
        _libraryReadModel = State(initialValue: libraryReadModel)
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
        _pluginService = State(initialValue: PluginService(
            modelContext: context,
            settings: settings,
            toasts: toastCenter,
            libraryReadModel: libraryReadModel
        ))
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
                        ContentView(
                            viewModel: viewModel,
                            libraryReadModel: libraryReadModel
                        )
                            .task {
                                guard !LibraryPerformanceConfiguration.isScenarioEnabled else {
                                    return
                                }
                                await pluginService.refresh()
                            }
                    }
                }
            }
                .environment(themeManager)
                .environment(settings)
                .environment(deviceMonitor)
                .environment(kindleSyncProfiles)
                .environment(transferQueue)
                .environment(operationReports)
                .environment(toastCenter)
                .environment(pluginService)
                .environment(discoveryViewModel)
                .environment(opdsViewModel)
                .accessibleTheme(themeManager.theme)
                .font(themeManager.defaultFont)
                .preferredColorScheme(themeManager.theme.colorScheme)
        }
        .modelContainer(container)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 1100, height: 700)
        .commands {
            AppCommands(themeManager: themeManager, settings: settings)
        }

        Settings {
            Group {
                if let recovery = PersistenceController.lastRecovery,
                   !recovery.allowsLibraryAccess {
                    StoreUnavailableView(recovery: recovery)
                } else if libraryStartupState == .ready {
                    SettingsView(
                        maintenance: viewModel.maintenance,
                        languageAtLaunch: languageAtLaunch
                    )
                } else {
                    LibraryStartupProgressView()
                }
            }
                .modelContainer(container)
                .environment(themeManager)
                .environment(settings)
                .environment(pluginService)
                .environment(opdsViewModel)
                .accessibleTheme(themeManager.theme)
                .font(themeManager.defaultFont)
                .preferredColorScheme(themeManager.theme.colorScheme)
        }
    }

    @MainActor
    private func prepareLibrary() async {
        LibraryPerformanceDiagnostics.writeOutput(
            "WINSTON_LIBRARY_PERFORMANCE_RECOVERY_STARTED"
        )
        let signposter = Log.persistenceSignposter
        let interval = signposter.beginInterval(
            "CriticalStartupRecovery",
            id: signposter.makeSignpostID()
        )
        defer { signposter.endInterval("CriticalStartupRecovery", interval) }

        if case .quarantined(let snapshotURL) = PersistenceController.lastRecovery {
            operationReports.upsert(.databaseRecovery(
                id: Self.databaseRecoveryReportID,
                snapshotURL: snapshotURL
            ))
        }
        let recovery = await viewModel.recoverManagedFiles()
        guard libraryStartupState == .preparing else { return }
        if recovery.hasPendingWork {
            LibraryPerformanceDiagnostics.writeOutput(
                "WINSTON_LIBRARY_PERFORMANCE_RECOVERY_FINISHED_WITH_ISSUES"
            )
            operationReports.upsert(.managedFileRecovery(
                id: Self.managedFileRecoveryReportID,
                report: recovery
            ))
        } else {
            LibraryPerformanceDiagnostics.writeOutput(
                "WINSTON_LIBRARY_PERFORMANCE_RECOVERY_FINISHED"
            )
        }
        let leaseStore = ImportSourceLeaseStore()
        do {
            let removed = try await Task.detached(priority: .utility) {
                try leaseStore.pruneStaleLeases()
            }.value
            if removed > 0 {
                Log.persistence.info(
                    "Pruned \(removed) stale import source lease(s)"
                )
            }
        } catch {
            Log.persistence.error(
                "Could not prune stale import source leases: \(error.localizedDescription, privacy: .public)"
            )
        }
        libraryStartupState = .ready
    }

    private static let managedFileRecoveryReportID = UUID(
        uuidString: "A1100000-0000-4000-8000-000000000001"
    )!
    private static let databaseRecoveryReportID = UUID(
        uuidString: "DA7A0000-0000-4000-8000-000000000001"
    )!
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

private struct StoreUnavailableView: View {
    let recovery: PersistenceController.Recovery

    var body: some View {
        ContentUnavailableView {
            Label(
                "Library Unavailable",
                systemImage: "externaldrive.badge.exclamationmark"
            )
        } description: {
            VStack(spacing: 8) {
                Text(message)
                    .frame(maxWidth: 560)
                if let snapshotURL {
                    Text("Recovery files: \(snapshotURL.path(percentEncoded: false))")
                        .font(.caption)
                        .textSelection(.enabled)
                }
                Text(failureMessage)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        } actions: {
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
