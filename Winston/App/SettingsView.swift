import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(AppSettings.self) private var settings

    @State private var showRelaunchPrompt = false
    @State private var backups: [URL] = []
    @State private var restoreCandidate: URL?
    @State private var showLibraryTimeMachine = false
    @State private var zoomDraft = AppSettings.defaultGridZoom

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                generalTab
            }
            Tab("View", systemImage: "square.grid.2x2") {
                viewTab
            }
            Tab("Plugins", systemImage: "puzzlepiece.extension") {
                PluginsSettingsPane()
            }
        }
        .frame(width: 460, height: 560)
        .onAppear {
            zoomDraft = settings.gridZoom
            reloadBackups()
        }
        .onChange(of: settings.backupFolderPath) { reloadBackups() }
        .alert("Relaunch to change language?", isPresented: $showRelaunchPrompt) {
            Button("Relaunch Now") { relaunch() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Winston needs to relaunch for the new language to take effect.")
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(
                get: { restoreCandidate != nil },
                set: { if !$0 { restoreCandidate = nil } }
            )
        ) {
            Button("Restore & Relaunch", role: .destructive) {
                if let backup = restoreCandidate {
                    LibraryBackup.requestRestore(from: backup)
                    relaunch()
                }
                restoreCandidate = nil
            }
            Button("Cancel", role: .cancel) { restoreCandidate = nil }
        } message: {
            Text("Winston relaunches and replaces the current catalog (metadata, collections, reading status, covers) with this backup. The current state is saved as a new backup first. Book files are not touched.")
        }
        .sheet(isPresented: $showLibraryTimeMachine, onDismiss: reloadBackups) {
            if let path = settings.backupFolderPath {
                LibraryTimeMachineSheet(
                    backupFolder: URL(fileURLWithPath: path, isDirectory: true),
                    onBackupsChanged: reloadBackups
                )
            }
        }
    }

    // MARK: - View tab

    private static let fontFamilies: [String] = {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return [
            "Avenir Next",
            "Charter",
            "Futura",
            "Georgia",
            "Helvetica Neue",
            "Palatino",
            "Times New Roman",
            "Verdana",
        ].filter(installed.contains)
    }()

    private var fontFamilyOptions: [String] {
        guard let current = themeManager.fontFamily,
              !Self.fontFamilies.contains(current) else { return Self.fontFamilies }
        return (Self.fontFamilies + [current]).sorted()
    }

    private var viewTab: some View {
        @Bindable var themeManager = themeManager
        @Bindable var settings = settings

        return Form {
            Section("Appearance") {
                Picker("Theme", selection: $themeManager.selection) {
                    ForEach(AppTheme.allCases) { appTheme in
                        Text(appTheme.displayName).tag(appTheme)
                    }
                }
                .pickerStyle(.radioGroup)

                Picker("Font", selection: $themeManager.fontFamily) {
                    Text("Theme Default").tag(String?.none)
                    Divider()
                    ForEach(fontFamilyOptions, id: \.self) { family in
                        Text(verbatim: family)
                            .font(.custom(family, size: NSFont.systemFontSize))
                            .tag(String?.some(family))
                    }
                }
                Text("Changes the text font across the whole app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Covers") {
                Slider(
                    value: $zoomDraft,
                    in: 0...1,
                    step: AppSettings.gridZoomStep,
                    label: { Text("Cover size") },
                    minimumValueLabel: { Image(systemName: "square.grid.3x3").font(.system(size: 10)) },
                    maximumValueLabel: { Image(systemName: "square.grid.2x2").font(.system(size: 12)) },
                    onEditingChanged: { editing in
                        if !editing { settings.gridZoom = zoomDraft }
                    }
                )
                Text("Adjusts the cover size in the library grid. \u{2318}+ and \u{2318}\u{2212} in the View menu do the same.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SidebarVisibilitySettingsSection(
                showDiscover: $settings.showDiscoverInSidebar,
                showCatalogs: $settings.showCatalogsInSidebar
            )
        }
        .formStyle(.grouped)
    }

    // MARK: - General tab

    private var generalTab: some View {
        @Bindable var settings = settings

        return Form {
            Section("Language") {
                Picker("Language", selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text("Changing the language takes effect after Winston relaunches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: settings.appLanguage) { showRelaunchPrompt = true }

            Section("Metadata") {
                Toggle("Fetch metadata online", isOn: $settings.onlineMetadataEnabled)
                Text("Looks up covers and details from free catalogs (Open Library, Google Books) for imported books, filling in only what's missing. When off, Winston stays fully offline and uses the metadata embedded in your files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Community Ratings") {
                TextField("Hardcover API token", text: $settings.hardcoverToken)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.onlineMetadataEnabled)
                if let url = URL(string: "https://hardcover.app/account/api") {
                    Link("Get a free token at hardcover.app", destination: url)
                        .font(.caption)
                }
                Text("Optional. Hardcover has the best reader ratings. Paste a token to use it as the rating source; without one, ratings fall back to Google Books and Open Library, which cover far fewer books.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Check for new series releases", isOn: $settings.releaseCheckEnabled)
                    .disabled(!settings.onlineMetadataEnabled
                        || settings.hardcoverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Once a day, Winston looks for newly released books in the series you own and posts them to Updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ExternalBookWebsiteSettingsSection(
                websiteURL: $settings.externalBookWebsiteURL
            )

            Section("Auto-Import") {
                Toggle("Watch a folder for new books", isOn: $settings.watchFolderEnabled)
                HStack {
                    Text(settings.watchFolderPath.map { URL(fileURLWithPath: $0).path } ?? "No folder chosen")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Choose\u{2026}") { chooseWatchFolder() }
                }
                Text("EPUB/MOBI/AZW3/PDF files added to this folder are imported automatically (duplicates are skipped).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Backup") {
                Toggle("Automatic backup", isOn: $settings.autoBackupEnabled)
                HStack {
                    Text(settings.backupFolderPath.map { URL(fileURLWithPath: $0).path } ?? "No folder chosen")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Choose\u{2026}") { chooseBackupFolder() }
                }
                Text("Copies the library catalog and covers to this folder about once a day, keeping the most recent backups. A safety net separate from Export Library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !backups.isEmpty {
                    Button {
                        showLibraryTimeMachine = true
                    } label: {
                        Label("Browse Backup History…", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("libraryTimeMachine.open")

                    ForEach(backups, id: \.self) { backup in
                        HStack {
                            if let date = LibraryBackup.date(of: backup) {
                                Text(date, format: .dateTime.day().month().year().hour().minute())
                            } else {
                                Text(verbatim: backup.lastPathComponent)
                            }
                            Spacer()
                            Button("Restore\u{2026}") { restoreCandidate = backup }
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func reloadBackups() {
        guard let path = settings.backupFolderPath else { backups = []; return }
        backups = LibraryBackup.availableBackups(in: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private func chooseWatchFolder() {
        Task {
            guard let url = await FilePanel.chooseFolder(
                message: String(localized: "Choose a folder to watch for new books.")
            ) else { return }
            settings.watchFolderPath = url.path
            settings.watchFolderEnabled = true
        }
    }

    private func chooseBackupFolder() {
        Task {
            guard let url = await FilePanel.chooseFolder(
                message: String(localized: "Choose a folder for automatic backups.")
            ) else { return }
            settings.backupFolderPath = url.path
            settings.autoBackupEnabled = true
        }
    }
}

private struct SidebarVisibilitySettingsSection: View {
    @Binding var showDiscover: Bool
    @Binding var showCatalogs: Bool

    var body: some View {
        Section("Sidebar") {
            Toggle("Show Discover", isOn: $showDiscover)
            Toggle("Show Catalogs", isOn: $showCatalogs)
            Text("Choose which online browsing destinations appear in the library sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ExternalBookWebsiteSettingsSection: View {
    @Binding var websiteURL: String

    private var hasWebsiteURL: Bool {
        !websiteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var validationURL: URL? {
        ExternalBookSearchURL.make(
            websiteURL: websiteURL,
            title: "Shatter Me",
            author: "Tahereh Mafi"
        )
    }

    var body: some View {
        Section("External Book Website") {
            TextField("Website URL", text: $websiteURL)
                .textFieldStyle(.roundedBorder)

            Text("Enter the website URL. Winston always uses this exact search format:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(verbatim: "https://example.com/search?index=&page=1&sort=&display=&q=Stephanie+garber")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if hasWebsiteURL && validationURL == nil {
                Label(
                    "Enter a complete http:// or https:// URL.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(ThemeManager())
        .environment(AppSettings())
}
