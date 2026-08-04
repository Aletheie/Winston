import SwiftUI

extension Notification.Name {
    static let showDiscoverDestination = Notification.Name("showDiscoverDestination")
    static let showCatalogsDestination = Notification.Name("showCatalogsDestination")
    static let showImportedBooks = Notification.Name("showImportedBooks")
}

// MARK: - Focused values

enum LibraryCommand: Equatable {
    case importBooks
    case importCalibre
    case importReadingHistory
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
    case searchInsideBooks
    case convertSelected
    case fetchMetadata
    case showLibraryIntegrity
    case showImportRecovery
    case showMetadataFixes
    case reviewEditions
    case showStatistics
    case showHighlights
    case showSeries
    case exportLibrary
    case saveSearchAsCollection
    case recommendReading
    case markSelection(ReadingStatus)
    case replaceSelected
    case inspectSelected
}

nonisolated struct BookActionAvailability: Equatable, Sendable {
    var selectionCount = 0
    var hasPrimarySelection = false
    var primaryHasPersistedDigitalFile = false
    var persistedDigitalFileCount = 0
    var sendableDigitalFileCount = 0
    var drmProtectedDigitalFileCount = 0
    var conversionEligibleCount = 0
    var calibreAvailable = false
    var onlineMetadataEnabled = false
    var onDeviceSelectionCount = 0
    var hasMeaningfulSearch = false

    var hasSelection: Bool {
        selectionCount > 0
    }

    var canUsePrimaryFile: Bool {
        hasPrimarySelection && primaryHasPersistedDigitalFile
    }

    var canReplaceOrAttachFile: Bool {
        hasPrimarySelection
    }

    var canEditMetadata: Bool {
        hasSelection
    }

    var canFetchMetadata: Bool {
        hasSelection && onlineMetadataEnabled
    }

    var canConvertForKindle: Bool {
        conversionEligibleCount > 0
    }

    var canRemoveFromDevice: Bool {
        onDeviceSelectionCount > 0
    }

    var canTransmit: Bool {
        sendableDigitalFileCount > 0
    }

    var canInspectWithBookDoctor: Bool {
        persistedDigitalFileCount > 0
    }

    var hasDRMOnlyDigitalSelection: Bool {
        persistedDigitalFileCount > 0
            && drmProtectedDigitalFileCount == persistedDigitalFileCount
    }

    var canSaveSearch: Bool {
        hasMeaningfulSearch
    }
}

@Observable
@MainActor
final class LibraryCommandContext {
    private(set) var request: LibraryCommand?
    private(set) var requestGeneration = 0
    private(set) var availability = BookActionAvailability()

    func perform(_ command: LibraryCommand) {
        request = command
        requestGeneration &+= 1
    }

    func updateAvailability(_ newValue: BookActionAvailability) {
        guard availability != newValue else { return }
        availability = newValue
    }
}

@Observable
@MainActor
final class CatalogCommandContext {
    private(set) var focusSearchGeneration = 0

    func focusSearch() {
        focusSearchGeneration &+= 1
    }
}

extension FocusedValues {
    @Entry var libraryCommandContext: LibraryCommandContext?
    @Entry var catalogCommandContext: CatalogCommandContext?
}

// MARK: - Menu commands

struct AppCommands: Commands {
    @FocusedValue(\.libraryCommandContext) var library
    @FocusedValue(\.catalogCommandContext) var catalog
    @Bindable var themeManager: ThemeManager
    let settings: AppSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Books\u{2026}") { library?.perform(.importBooks) }
                .keyboardShortcut("o")
                .disabled(library == nil)

            Button("Import from Calibre Library\u{2026}") { library?.perform(.importCalibre) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(library == nil)

            Button("Import Reading History\u{2026}") { library?.perform(.importReadingHistory) }
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

            Button("Discover") {
                settings.showDiscoverInSidebar = true
                NotificationCenter.default.post(name: .showDiscoverDestination, object: nil)
            }

            Button("Catalogs") {
                settings.showCatalogsInSidebar = true
                NotificationCenter.default.post(name: .showCatalogsDestination, object: nil)
            }

            Divider()

            Button("Find\u{2026}") {
                if let catalog {
                    catalog.focusSearch()
                } else {
                    library?.perform(.focusSearch)
                }
            }
                .keyboardShortcut("f")
                .disabled(library == nil && catalog == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Winston Help") { WinstonHelp.open(for: settings.appLanguage) }
                .keyboardShortcut("?", modifiers: .command)
        }

        CommandMenu("Library") {
            Button("Search Inside Books\u{2026}") { library?.perform(.searchInsideBooks) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(library == nil)
            Divider()
            Button("Statistics\u{2026}") { library?.perform(.showStatistics) }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(library == nil)
            Button("Reconcile Books\u{2026}") { library?.perform(.reviewEditions) }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(library == nil)
            Button("Library Integrity\u{2026}") { library?.perform(.showLibraryIntegrity) }
                .disabled(library == nil)
            Button("Import Review & Recovery\u{2026}") { library?.perform(.showImportRecovery) }
                .disabled(library == nil)
            Button("Metadata Cleanup\u{2026}") {
                library?.perform(.showMetadataFixes)
            }
                .disabled(library == nil)
            Button("Highlights\u{2026}") { library?.perform(.showHighlights) }
                .disabled(library == nil)
            Button("Series\u{2026}") { library?.perform(.showSeries) }
                .disabled(library == nil)
            Divider()
            Button("What Should I Read Today\u{2026}") { library?.perform(.recommendReading) }
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
                .disabled(library?.availability.canUsePrimaryFile != true)

            Button("Quick Look") { library?.perform(.quickLook) }
                .keyboardShortcut("y")
                .disabled(library?.availability.canUsePrimaryFile != true)

            Button("Show in Finder") { library?.perform(.showInFinder) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(library?.availability.canUsePrimaryFile != true)

            Button(
                library?.availability.primaryHasPersistedDigitalFile == true
                    ? "Replace File\u{2026}"
                    : "Attach Digital File\u{2026}"
            ) {
                library?.perform(.replaceSelected)
            }
                .disabled(library?.availability.canReplaceOrAttachFile != true)

            Button("Inspect with Book Doctor\u{2026}") { library?.perform(.inspectSelected) }
                .disabled(library?.availability.canInspectWithBookDoctor != true)

            Divider()

            Button("Edit Metadata\u{2026}") { library?.perform(.editMetadata) }
                .keyboardShortcut("e")
                .disabled(library?.availability.canEditMetadata != true)

            Menu("Mark as") {
                ForEach(ReadingStatus.allCases) { status in
                    Button(status.label) { library?.perform(.markSelection(status)) }
                }
            }
            .disabled(library?.availability.hasSelection != true)

            Button("Fetch Metadata Online") { library?.perform(.fetchMetadata) }
                .disabled(library?.availability.canFetchMetadata != true)

            Button("Convert for Kindle") { library?.perform(.convertSelected) }
                .disabled(library?.availability.canConvertForKindle != true)

            Divider()

            Button("Delete") { library?.perform(.deleteSelected) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(library?.availability.hasSelection != true)
        }
    }
}
