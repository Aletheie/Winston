import SwiftUI
import AppKit
import OSLog

// MARK: - Focused values

struct LibraryActions {
    var importBooks: () -> Void
    var importCalibre: () -> Void
    var openInReader: () -> Void
    var quickLook: () -> Void
    var showInFinder: () -> Void
    var editMetadata: () -> Void
    var deleteSelected: () -> Void
    var selectAll: () -> Void
    var toggleSidebar: () -> Void
    var toggleInspector: () -> Void
    var setGridView: () -> Void
    var setListView: () -> Void
    var focusSearch: () -> Void
    var convertSelected: () -> Void
    var fetchMetadata: () -> Void
    var findDuplicates: () -> Void
    var showStatistics: () -> Void
    var showHighlights: () -> Void
    var showSeries: () -> Void
    var exportLibrary: () -> Void
    var saveSearchAsCollection: () -> Void
    var surpriseMe: () -> Void
    var markSelection: (ReadingStatus) -> Void
    var replaceSelected: () -> Void
    var hasSelection: Bool
    var canConvert: Bool
    var canFetchMetadata: Bool
    var canSaveSearch: Bool
    var selectedCount: Int
}

extension FocusedValues {
    @Entry var libraryActions: LibraryActions?
}

// MARK: - Menu commands

struct AppCommands: Commands {
    @FocusedValue(\.libraryActions) var actions
    @Bindable var themeManager: ThemeManager
    let settings: AppSettings
    let updater: SoftwareUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand(updater: updater)
        }

        CommandGroup(replacing: .newItem) {
            Button("Import Books\u{2026}") { actions?.importBooks() }
                .keyboardShortcut("o")
                .disabled(actions == nil)

            Button("Import from Calibre Library\u{2026}") { actions?.importCalibre() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Select All") { actions?.selectAll() }
                .keyboardShortcut("a")
                .disabled(actions == nil)
        }

        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") { actions?.toggleSidebar() }
                .keyboardShortcut("0")
                .disabled(actions == nil)

            Button("Toggle Inspector") { actions?.toggleInspector() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(actions == nil)

            Divider()

            Button("Grid View") { actions?.setGridView() }
                .keyboardShortcut("1")
                .disabled(actions == nil)

            Button("List View") { actions?.setListView() }
                .keyboardShortcut("2")
                .disabled(actions == nil)

            Divider()

            Button("Zoom In") {
                settings.adjustGridZoom(by: AppSettings.gridZoomStep)
            }
            .keyboardShortcut("+")
            .disabled(settings.gridZoom >= 1)
            Button("Zoom Out") {
                settings.adjustGridZoom(by: -AppSettings.gridZoomStep)
            }
            .keyboardShortcut("-")
            .disabled(settings.gridZoom <= 0)

            Divider()

            Picker("Theme", selection: $themeManager.selection) {
                ForEach(AppTheme.allCases) { appTheme in
                    Text(appTheme.displayName).tag(appTheme)
                }
            }

            Button("Toggle Theme") { themeManager.cycle() }
                .keyboardShortcut("t", modifiers: [.command, .shift])

            Divider()

            Button("Find\u{2026}") { actions?.focusSearch() }
                .keyboardShortcut("f")
                .disabled(actions == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Winston Help") { NSApplication.shared.showHelp(nil) }
                .keyboardShortcut("?", modifiers: .command)
        }

        CommandMenu("Library") {
            Button("Statistics\u{2026}") { actions?.showStatistics() }
                .disabled(actions == nil)
            Button("Find Duplicates\u{2026}") { actions?.findDuplicates() }
                .disabled(actions == nil)
            Button("Highlights\u{2026}") { actions?.showHighlights() }
                .disabled(actions == nil)
            Button("Series\u{2026}") { actions?.showSeries() }
                .disabled(actions == nil)
            Divider()
            Button("Surprise Me") { actions?.surpriseMe() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(actions == nil)
            Divider()
            Button("Save Search as Collection\u{2026}") { actions?.saveSearchAsCollection() }
                .disabled(actions?.canSaveSearch != true)
            Button("Export Library\u{2026}") { actions?.exportLibrary() }
                .disabled(actions == nil)
        }

        CommandMenu("Book") {
            Button("Open in Reader") { actions?.openInReader() }
                .keyboardShortcut(.return)
                .disabled(actions?.hasSelection != true)

            Button("Quick Look") { actions?.quickLook() }
                .keyboardShortcut("y")
                .disabled(actions?.hasSelection != true)

            Button("Show in Finder") { actions?.showInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.hasSelection != true)

            Button("Replace File\u{2026}") { actions?.replaceSelected() }
                .disabled(actions?.hasSelection != true)

            Divider()

            Button("Edit Metadata\u{2026}") { actions?.editMetadata() }
                .keyboardShortcut("e")
                .disabled(actions?.hasSelection != true)

            Menu("Mark as") {
                ForEach(ReadingStatus.allCases) { status in
                    Button(status.label) { actions?.markSelection(status) }
                }
            }
            .disabled(actions?.hasSelection != true)

            Button("Fetch Metadata Online") { actions?.fetchMetadata() }
                .disabled(actions?.canFetchMetadata != true)

            Button("Convert to AZW3") { actions?.convertSelected() }
                .disabled(actions?.canConvert != true)

            Divider()

            Button("Delete") { actions?.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(actions?.hasSelection != true)
        }
    }
}
