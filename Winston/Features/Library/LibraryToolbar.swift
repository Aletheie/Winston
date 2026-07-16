import SwiftUI

enum LibraryViewMode: Hashable {
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
    let transmitEnabled: Bool
    let onSearchInsideBooks: () -> Void
    let onImport: () -> Void
    let onTransmit: () -> Void

    @Environment(\.theme) private var theme

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker("View", selection: $viewMode) {
                Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid)
                Image(systemName: "list.bullet").tag(LibraryViewMode.table)
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

            Button(action: onSearchInsideBooks) {
                Label("Search Inside Books", systemImage: "doc.text.magnifyingglass")
            }
            .help("Search inside EPUB, PDF, TXT, and HTML books")
        }

        ToolbarItem(placement: .primaryAction) {
            Button(action: onImport) {
                Label(theme.copy.addFiles, systemImage: "plus")
            }
            .help("Import book files")
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
