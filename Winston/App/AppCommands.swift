import SwiftUI

// MARK: - Focused values

enum LibraryCommand: Equatable {
    case importBooks
    case importCalibre
    case openInReader
    case quickLook
    case showInFinder
    case editMetadata
    case deleteSelected
    case selectAll
    case toggleSidebar
    case toggleInspector
    case setGridView
    case setListView
    case focusSearch
    case convertSelected
    case fetchMetadata
    case findDuplicates
    case showMetadataFixes
    case reviewEditions
    case showStatistics
    case showHighlights
    case showSeries
    case exportLibrary
    case saveSearchAsCollection
    case surpriseMe
    case markSelection(ReadingStatus)
    case replaceSelected
    case inspectSelected
}

struct LibraryCommandAvailability: Equatable {
    var hasSelection = false
    var canConvert = false
    var canFetchMetadata = false
    var canSaveSearch = false
}

@Observable
@MainActor
final class LibraryCommandContext {
    private(set) var request: LibraryCommand?
    private(set) var requestGeneration = 0
    private(set) var availability = LibraryCommandAvailability()

    func perform(_ command: LibraryCommand) {
        request = command
        requestGeneration &+= 1
    }

    func updateAvailability(_ newValue: LibraryCommandAvailability) {
        guard availability != newValue else { return }
        availability = newValue
    }
}

extension FocusedValues {
    @Entry var libraryCommandContext: LibraryCommandContext?
}

// MARK: - Menu commands

struct AppCommands: Commands {
    @FocusedValue(\.libraryCommandContext) var library
    @Bindable var themeManager: ThemeManager
    let settings: AppSettings
    let updater: SoftwareUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand(updater: updater)
        }

        CommandGroup(replacing: .newItem) {
            Button("Import Books\u{2026}") { library?.perform(.importBooks) }
                .keyboardShortcut("o")
                .disabled(library == nil)

            Button("Import from Calibre Library\u{2026}") { library?.perform(.importCalibre) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(library == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Select All") { library?.perform(.selectAll) }
                .keyboardShortcut("a")
                .disabled(library == nil)
        }

        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") { library?.perform(.toggleSidebar) }
                .keyboardShortcut("0")
                .disabled(library == nil)

            Button("Toggle Inspector") { library?.perform(.toggleInspector) }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(library == nil)

            Divider()

            Button("Grid View") { library?.perform(.setGridView) }
                .keyboardShortcut("1")
                .disabled(library == nil)

            Button("List View") { library?.perform(.setListView) }
                .keyboardShortcut("2")
                .disabled(library == nil)

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

            Button("Find\u{2026}") { library?.perform(.focusSearch) }
                .keyboardShortcut("f")
                .disabled(library == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Winston Help") { WinstonHelp.open(for: settings.appLanguage) }
                .keyboardShortcut("?", modifiers: .command)
        }

        CommandMenu("Library") {
            Button("Statistics\u{2026}") { library?.perform(.showStatistics) }
                .disabled(library == nil)
            Button("Find Duplicates\u{2026}") { library?.perform(.findDuplicates) }
                .disabled(library == nil)
            Button("Metadata Fixes\u{2026}") { library?.perform(.showMetadataFixes) }
                .disabled(library == nil)
            Button("Review Edition Suggestions\u{2026}") { library?.perform(.reviewEditions) }
                .disabled(library == nil)
            Button("Highlights\u{2026}") { library?.perform(.showHighlights) }
                .disabled(library == nil)
            Button("Series\u{2026}") { library?.perform(.showSeries) }
                .disabled(library == nil)
            Divider()
            Button("Surprise Me") { library?.perform(.surpriseMe) }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(library == nil)
            Divider()
            Button("Save Search as Collection\u{2026}") { library?.perform(.saveSearchAsCollection) }
                .disabled(library?.availability.canSaveSearch != true)
            Button("Export Library\u{2026}") { library?.perform(.exportLibrary) }
                .disabled(library == nil)
        }

        CommandMenu("Book") {
            Button("Open in Reader") { library?.perform(.openInReader) }
                .keyboardShortcut(.return)
                .disabled(library?.availability.hasSelection != true)

            Button("Quick Look") { library?.perform(.quickLook) }
                .keyboardShortcut("y")
                .disabled(library?.availability.hasSelection != true)

            Button("Show in Finder") { library?.perform(.showInFinder) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(library?.availability.hasSelection != true)

            Button("Replace File\u{2026}") { library?.perform(.replaceSelected) }
                .disabled(library?.availability.hasSelection != true)

            Button("Inspect with Book Doctor\u{2026}") { library?.perform(.inspectSelected) }
                .disabled(library?.availability.hasSelection != true)

            Divider()

            Button("Edit Metadata\u{2026}") { library?.perform(.editMetadata) }
                .keyboardShortcut("e")
                .disabled(library?.availability.hasSelection != true)

            Menu("Mark as") {
                ForEach(ReadingStatus.allCases) { status in
                    Button(status.label) { library?.perform(.markSelection(status)) }
                }
            }
            .disabled(library?.availability.hasSelection != true)

            Button("Fetch Metadata Online") { library?.perform(.fetchMetadata) }
                .disabled(library?.availability.canFetchMetadata != true)

            Button("Convert to AZW3") { library?.perform(.convertSelected) }
                .disabled(library?.availability.canConvert != true)

            Divider()

            Button("Delete") { library?.perform(.deleteSelected) }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(library?.availability.hasSelection != true)
        }
    }
}
