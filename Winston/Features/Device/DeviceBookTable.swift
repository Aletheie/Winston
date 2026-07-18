import SwiftUI

struct DeviceLibrarySection: View {
    let rows: [DeviceBookRow]
    let authors: [String]
    @Binding var selection: Set<DeviceBook.ID>
    let onCopy: (Set<DeviceBook.ID>) -> Void
    let onDelete: (Set<DeviceBook.ID>) -> Void
    let onDeleteByAuthor: (String) -> Void

    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var authorFilter: String?
    @State private var sortOrder = DeviceTableQuery.recentFirst
    @State private var displayedRows: [DeviceBookRow] = []

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            DeviceFilterBar(
                searchText: $searchText,
                authorFilter: $authorFilter,
                authors: authors,
                shownCount: displayedRows.count,
                totalCount: rows.count
            )
            Divider()
            if displayedRows.isEmpty {
                noMatchesState
            } else {
                DeviceBookTable(
                    rows: displayedRows,
                    selection: $selection,
                    sortOrder: $sortOrder,
                    onCopy: onCopy,
                    onDelete: onDelete,
                    onDeleteByAuthor: onDeleteByAuthor
                )
            }
        }
        .onChange(of: rows, initial: true) { recomputeDisplayedRows() }
        .onChange(of: authorFilter) { recomputeDisplayedRows() }
        .onChange(of: sortOrder) { recomputeDisplayedRows() }
        .onChange(of: debouncedSearchText) { recomputeDisplayedRows() }
        .task(id: searchText) {
            if !searchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
            }
            debouncedSearchText = searchText
        }
    }

    private func recomputeDisplayedRows() {
        displayedRows = DeviceTableQuery.apply(
            to: rows,
            searchText: debouncedSearchText,
            author: authorFilter,
            sort: sortOrder
        )
    }

    private var noMatchesState: some View {
        ContentUnavailableView {
            Label {
                Text(theme.copy.noMatches)
            } icon: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
        } actions: {
            Button(theme.copy.showAll) {
                searchText = ""
                authorFilter = nil
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Filter bar

private struct DeviceFilterBar: View {
    @Binding var searchText: String
    @Binding var authorFilter: String?
    let authors: [String]
    let shownCount: Int
    let totalCount: Int

    @Environment(\.theme) private var theme

    private var isFiltering: Bool { shownCount != totalCount }

    var body: some View {
        HStack(spacing: 10) {
            searchField

            if !authors.isEmpty {
                AuthorFilterButton(authorFilter: $authorFilter, authors: authors)
            }

            Spacer()

            if isFiltering {
                countText
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
            TextField(text: $searchText) {
                theme.styledText(terminal: "filter", native: "Filter by title or author")
            }
            .textFieldStyle(.plain)
            .font(theme.label(size: 12))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(theme.copy.clearSearch)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 240)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.surface.opacity(0.6)))
    }

    private var countText: Text {
        theme.usesTerminalCopy
            ? Text(verbatim: "\(shownCount)/\(totalCount)")
            : Text("\(shownCount) of \(totalCount)", comment: "Books shown by the device filter, of the device total")
    }
}

private struct AuthorFilterButton: View {
    @Binding var authorFilter: String?
    let authors: [String]

    @State private var isPresented = false
    @State private var authorQuery = ""

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Button {
                authorQuery = ""
                isPresented.toggle()
            } label: {
                Label {
                    if let author = authorFilter {
                        Text(verbatim: author).lineLimit(1)
                    } else {
                        theme.styledText(terminal: "author", native: "Author")
                    }
                } icon: {
                    Image(systemName: authorFilter == nil ? "person.crop.circle" : "person.crop.circle.fill")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(authorFilter == nil ? nil : theme.accent)
            .help("Show only books by one author")

            if authorFilter != nil {
                Button {
                    authorFilter = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(theme.copy.clearSearch)
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            authorList
        }
    }

    private var visibleAuthors: [String] {
        authorQuery.isEmpty ? authors : authors.filter { $0.localizedStandardContains(authorQuery) }
    }

    private var authorList: some View {
        VStack(spacing: 0) {
            TextField(text: $authorQuery) {
                theme.styledText(terminal: "filter_authors", native: "Filter authors")
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .padding(8)

            Divider()

            List {
                Button {
                    select(nil)
                } label: {
                    authorRow(theme.styledText(terminal: "all_authors", native: "All Authors"),
                              isSelected: authorFilter == nil)
                }
                .buttonStyle(.plain)

                ForEach(visibleAuthors, id: \.self) { author in
                    Button {
                        select(author)
                    } label: {
                        authorRow(Text(verbatim: author), isSelected: authorFilter == author)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 260, height: 320)
    }

    private func authorRow(_ text: Text, isSelected: Bool) -> some View {
        HStack {
            text
                .font(theme.label(size: 11))
                .lineLimit(1)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private func select(_ author: String?) {
        authorFilter = author
        isPresented = false
    }
}

// MARK: - Table

struct DeviceBookTable: View {
    let rows: [DeviceBookRow]
    @Binding var selection: Set<DeviceBook.ID>
    @Binding var sortOrder: [KeyPathComparator<DeviceBookRow>]
    let onCopy: (Set<DeviceBook.ID>) -> Void
    let onDelete: (Set<DeviceBook.ID>) -> Void
    let onDeleteByAuthor: (String) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { _ in
                Image(systemName: "book.closed")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(theme.textTertiary)
            }
            .width(28)

            TableColumn(column("Title", "title"), value: \.title, comparator: .localizedStandard) { row in
                Text(row.title)
                    .font(theme.body(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .help(row.book.fileName)
            }
            .width(min: 200, ideal: 420, max: 720)

            TableColumn(column("Author", "author"), value: \.sortAuthor, comparator: .localizedStandard) { row in
                Text(row.author ?? "\u{2014}")
                    .font(theme.label(size: 10, weight: .regular))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 220, max: 360)

            TableColumn(column("Format", "fmt"), value: \.format) { row in
                Text(row.format.isEmpty ? "\u{2014}" : row.format)
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.accentSecondary)
            }
            .width(70)

            TableColumn(column("Size", "size"), value: \.sizeBytes) { row in
                Text(row.book.sizeDisplay)
                    .font(theme.label(size: 10, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
            }
            .width(80)

            TableColumn(column("Added", "added"), value: \.sortDate) { row in
                Group {
                    if let date = row.book.modifiedDate {
                        Text(date, format: .dateTime.day().month().year())
                    } else {
                        Text(verbatim: "\u{2014}")
                    }
                }
                .font(theme.label(size: 10, weight: .regular))
                .foregroundStyle(theme.textTertiary)
                .monospacedDigit()
            }
            .width(min: 80, ideal: 90)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: DeviceBook.ID.self) { ids in
            let target = ids.isEmpty ? selection : ids
            if !target.isEmpty {
                Button { onCopy(target) } label: {
                    Label("Copy \(target.count) to Library", systemImage: "square.and.arrow.down")
                }
                Divider()
                Button(role: .destructive) { onDelete(target) } label: {
                    Label("Remove \(target.count) from Device", systemImage: "trash")
                }
                let authors = Set(rows.filter { target.contains($0.id) }.compactMap(\.author))
                if authors.count == 1, let author = authors.first {
                    Button(role: .destructive) { onDeleteByAuthor(author) } label: {
                        Label("Remove all by \(author)", systemImage: "person.crop.circle.badge.xmark")
                    }
                }
            }
        }
    }

    private func column(_ native: LocalizedStringKey, _ terminal: String) -> LocalizedStringKey {
        theme.usesTerminalCopy ? LocalizedStringKey(stringLiteral: terminal) : native
    }
}
