import SwiftUI

enum LibraryViewMode: String, Hashable {
    case grid, table
}

nonisolated enum BookSort: String, CaseIterable, Identifiable, Hashable, Sendable {
    case title, author, dateAdded, rating

    var id: Self { self }

    var defaultAscending: Bool {
        self == .title || self == .author
    }

    var displaySortField: LibraryDisplaySort.Field {
        switch self {
        case .title: .title
        case .author: .author
        case .dateAdded: .dateAdded
        case .rating: .rating
        }
    }

    @MainActor
    func comparator(ascending: Bool) -> KeyPathComparator<Book> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .title:     return KeyPathComparator(\Book.displayTitle, order: order)
        case .author:    return KeyPathComparator(\Book.sortAuthor, order: order)
        case .dateAdded: return KeyPathComparator(\Book.dateAdded, order: order)
        case .rating:    return KeyPathComparator(\Book.sortRating, order: order)
        }
    }

    func label(terminal: Bool) -> String {
        switch self {
        case .title:     terminal ? String(localized: "sort.title") : String(localized: "Title", comment: "Sort by title")
        case .author:    terminal ? String(localized: "sort.author") : String(localized: "Author")
        case .dateAdded: terminal ? String(localized: "sort.date") : String(localized: "Date Added", comment: "Sort by date added")
        case .rating:    terminal ? String(localized: "sort.rating") : String(localized: "Rating", comment: "Sort by rating")
        }
    }
}

nonisolated struct LibrarySortPreference: RawRepresentable, Hashable, Sendable {
    let field: BookSort
    let ascending: Bool

    static let defaultValue = LibrarySortPreference(field: .dateAdded, ascending: false)

    init(field: BookSort, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }

    init?(rawValue: String) {
        let components = rawValue.split(separator: ":", maxSplits: 1)
        guard components.count == 2,
              let field = BookSort(rawValue: String(components[0])),
              let ascending = Bool(String(components[1])) else {
            return nil
        }
        self.init(field: field, ascending: ascending)
    }

    var rawValue: String {
        "\(field.rawValue):\(ascending)"
    }

    var displaySort: LibraryDisplaySort {
        LibraryDisplaySort(field: field.displaySortField, ascending: ascending)
    }

    @MainActor
    var comparator: KeyPathComparator<Book> {
        field.comparator(ascending: ascending)
    }
}

struct LibraryToolbar: ToolbarContent {
    @Binding var viewMode: LibraryViewMode
    @Binding var sortPreference: LibrarySortPreference
    @Binding var showInspector: Bool
    @Binding var kindlePresenceFilter: KindlePresenceFilter
    let availability: BookActionAvailability
    let deviceIsConnected: Bool
    let kindleOperationIsActive: Bool
    let onImport: () -> Void
    let onAddPhysicalBook: () -> Void
    let onTransmit: () -> Void

    @Environment(\.theme) private var theme

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker("View", selection: $viewMode) {
                Label("Grid View", systemImage: "square.grid.2x2")
                    .labelStyle(.iconOnly)
                    .tag(LibraryViewMode.grid)
                Label("List View", systemImage: "list.bullet")
                    .labelStyle(.iconOnly)
                    .tag(LibraryViewMode.table)
            }
            .pickerStyle(.segmented)
            .help("Switch between grid and list")

            Menu {
                ForEach(BookSort.allCases) { sort in
                    Button {
                        toggle(sort)
                    } label: {
                        if isCurrent(sort) {
                            Label(sort.label(terminal: theme.usesTerminalCopy),
                                  systemImage: sortPreference.ascending ? "chevron.up" : "chevron.down")
                        } else {
                            Text(sort.label(terminal: theme.usesTerminalCopy))
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort order")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(action: onImport) {
                    Label("Import Book Files…", systemImage: "doc.badge.plus")
                }
                Button(action: onAddPhysicalBook) {
                    Label("Add Physical Book…", systemImage: "books.vertical")
                }
            } label: {
                Label(theme.copy.addFiles, systemImage: "plus")
            }
            .help("Add books")
        }

        ToolbarItem(placement: .primaryAction) {
            KindlePresenceFilterControl(selection: $kindlePresenceFilter)
                .disabled(!deviceIsConnected)
        }

        ToolbarItem(placement: .primaryAction) {
            Button(action: onTransmit) {
                Label(theme.copy.transmit, systemImage: "paperplane")
            }
            .disabled(!transmitEnabled)
            .help(transmitHelp)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Toggle the inspector")
        }
    }

    // MARK: - Sort helpers

    private var transmitEnabled: Bool {
        deviceIsConnected && availability.canTransmit && !kindleOperationIsActive
    }

    private func isCurrent(_ sort: BookSort) -> Bool {
        sortPreference.field == sort
    }

    private func toggle(_ sort: BookSort) {
        if isCurrent(sort) {
            sortPreference = LibrarySortPreference(
                field: sort,
                ascending: !sortPreference.ascending
            )
        } else {
            sortPreference = LibrarySortPreference(
                field: sort,
                ascending: sort.defaultAscending
            )
        }
    }

    private var transmitHelp: String {
        if kindleOperationIsActive {
            return String(localized: "A Kindle operation is already in progress")
        }
        if !deviceIsConnected {
            return String(localized: "Connect a Kindle to send books")
        }
        if !availability.hasSelection {
            return String(localized: "Select books to send to Kindle")
        }
        if availability.persistedDigitalFileCount == 0 {
            return String(localized: "The selection has no sendable digital files")
        }
        if availability.hasDRMOnlyDigitalSelection {
            return String(
                localized: "DRM-protected books can’t be sent to Kindle over USB"
            )
        }
        if !availability.canTransmit {
            return String(localized: "The selection has no sendable digital files")
        }
        return String(localized: "Send selected books to the device")
    }
}
