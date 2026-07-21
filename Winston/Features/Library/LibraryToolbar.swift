import SwiftUI

enum LibraryViewMode: String, Hashable {
    case grid, table
}

enum BookSort: CaseIterable, Identifiable {
    case title, author, dateAdded, rating

    var id: Self { self }

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

struct LibraryToolbar: ToolbarContent {
    @Binding var viewMode: LibraryViewMode
    @Binding var sortOrder: [KeyPathComparator<Book>]
    @Binding var showInspector: Bool
    @Binding var kindlePresenceFilter: KindlePresenceFilter
    let showsKindleFilter: Bool
    let transmitEnabled: Bool
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
                                  systemImage: ascending ? "chevron.up" : "chevron.down")
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

        if showsKindleFilter {
            ToolbarItem(placement: .primaryAction) {
                KindlePresenceFilterControl(selection: $kindlePresenceFilter)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button(action: onTransmit) {
                Label(theme.copy.transmit, systemImage: "paperplane")
            }
            .disabled(!transmitEnabled)
            .help(transmitEnabled ? "Send selected books to the device" : "Connect a device and select books")
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

    private var ascending: Bool {
        sortOrder.first?.order == .forward
    }

    private func isCurrent(_ sort: BookSort) -> Bool {
        guard let current = sortOrder.first else { return false }
        return current == sort.comparator(ascending: true)
            || current == sort.comparator(ascending: false)
    }

    private func toggle(_ sort: BookSort) {
        if isCurrent(sort) {
            sortOrder = [sort.comparator(ascending: !ascending)]
        } else {
            let asc = sort == .title || sort == .author
            sortOrder = [sort.comparator(ascending: asc)]
        }
    }
}
