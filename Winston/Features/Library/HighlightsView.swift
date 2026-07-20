import SwiftUI
import SwiftData
import AppKit

private nonisolated struct HighlightGroupSource: Sendable {
    struct Entry: Sendable {
        let sourceIndex: Int
        let location: String
        let normalizedText: String
    }

    let bookID: UUID
    let title: String
    let entries: [Entry]
}

private nonisolated struct PreparedHighlightGroup: Sendable {
    let bookID: UUID
    let sourceIndices: [Int]
    let normalizedTexts: [String]
}

private nonisolated struct VisibleHighlightGroup: Sendable {
    let bookID: UUID
    let highlightIndices: [Int]
}

struct HighlightsView: View {
    let books: [Book]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(ToastCenter.self) private var toasts
    @State private var search = ""
    @State private var sourceGroups: [BookGroup] = []
    @State private var searchGroups: [PreparedHighlightGroup] = []
    @State private var visible: [BookGroup] = []
    @State private var totalCount = 0
    @State private var isLoading = true
    @State private var groupGeneration = 0

    private struct BookGroup: Identifiable {
        let book: Book
        let highlights: [Highlight]
        var id: UUID { book.uuid }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 700, maxWidth: 1100,
               minHeight: 600, idealHeight: 780, maxHeight: .infinity)
        .task(id: LibraryMutationLog.shared.catalogRevision) {
            await rebuildSourceGroups()
        }
        .task(id: search) {
            if !search.isEmpty {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
            }
            await applySearch()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Text(theme.usesTerminalCopy ? "// highlights" : "Highlights")
                .font(theme.body(size: 15, weight: .bold))
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
                TextField(theme.copy.searchPlaceholder, text: $search)
                    .textFieldStyle(.plain)
                    .font(theme.label(size: 12))
                    .frame(width: 160)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: WinstonLayout.cornerMedium, style: .continuous)
                    .fill(theme.surface.opacity(0.6))
            )
            .themedBorder(cornerRadius: WinstonLayout.cornerMedium)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            ContentUnavailableView {
                Label(search.isEmpty ? String(localized: "No highlights yet")
                                     : String(localized: "No matching highlights"),
                      systemImage: "quote.bubble")
            } description: {
                if search.isEmpty {
                    Text("Import highlights from a connected Kindle to see them here.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(visible) { group in
                        HighlightBookSection(title: group.book.displayTitle,
                                             author: group.book.displayAuthor,
                                             highlights: group.highlights)
                    }
                }
                .padding(18)
            }
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 4) {
                Text(verbatim: "\(totalCount)")
                    .font(theme.label(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                theme.styledText(terminal: "highlights", native: "highlights")
                    .font(theme.label(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
            Button("Export\u{2026}") { exportHighlights() }
                .disabled(totalCount == 0)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - Data

    private func rebuildSourceGroups() async {
        isLoading = true
        var descriptor = FetchDescriptor<Book>(
            sortBy: [SortDescriptor(\Book.dateAdded, order: .reverse)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\Book.highlights]
        let sourceBooks = (try? modelContext.fetch(descriptor)) ?? books

        var booksByID: [UUID: Book] = [:]
        var highlightsByBookID: [UUID: [Highlight]] = [:]
        var sources: [HighlightGroupSource] = []
        booksByID.reserveCapacity(sourceBooks.count)
        highlightsByBookID.reserveCapacity(sourceBooks.count)
        sources.reserveCapacity(sourceBooks.count)
        var processedHighlights = 0

        for book in sourceBooks {
            guard !Task.isCancelled else { return }
            let highlights = book.highlights
            guard !highlights.isEmpty else { continue }
            booksByID[book.uuid] = book
            highlightsByBookID[book.uuid] = highlights

            var entries: [HighlightGroupSource.Entry] = []
            entries.reserveCapacity(highlights.count)
            for (index, highlight) in highlights.enumerated() {
                entries.append(HighlightGroupSource.Entry(
                    sourceIndex: index,
                    location: highlight.location ?? "",
                    normalizedText: highlight.text.lowercased()
                ))
                processedHighlights += 1
                if processedHighlights.isMultiple(of: 256) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                }
            }
            sources.append(HighlightGroupSource(
                bookID: book.uuid,
                title: book.displayTitle,
                entries: entries
            ))
        }

        let prepared = await Self.prepareGroups(sources)
        guard !Task.isCancelled else { return }
        let groups = prepared.compactMap { group -> BookGroup? in
            guard let book = booksByID[group.bookID],
                  let sourceHighlights = highlightsByBookID[group.bookID] else { return nil }
            return BookGroup(
                book: book,
                highlights: group.sourceIndices.compactMap { index in
                    sourceHighlights.indices.contains(index) ? sourceHighlights[index] : nil
                }
            )
        }
        sourceGroups = groups
        searchGroups = prepared
        totalCount = prepared.reduce(0) { $0 + $1.sourceIndices.count }
        isLoading = false
        groupGeneration &+= 1
        await applySearch()
    }

    private func applySearch() async {
        let query = search.lowercased()
        guard !query.isEmpty else {
            visible = sourceGroups
            return
        }

        let generation = groupGeneration
        let matches = await Self.filter(searchGroups, query: query)
        guard !Task.isCancelled,
              generation == groupGeneration,
              query == search.lowercased() else { return }
        let groupsByID = Dictionary(uniqueKeysWithValues: sourceGroups.map { ($0.id, $0) })
        visible = matches.compactMap { match in
            guard let group = groupsByID[match.bookID] else { return nil }
            return BookGroup(
                book: group.book,
                highlights: match.highlightIndices.compactMap { index in
                    group.highlights.indices.contains(index) ? group.highlights[index] : nil
                }
            )
        }
    }

    @concurrent
    private static func prepareGroups(
        _ sources: [HighlightGroupSource]
    ) async -> [PreparedHighlightGroup] {
        var prepared: [(source: HighlightGroupSource, entries: [HighlightGroupSource.Entry])] = []
        prepared.reserveCapacity(sources.count)
        for source in sources {
            guard !Task.isCancelled else { return [] }
            let entries = source.entries.sorted {
                if $0.location == $1.location { return $0.sourceIndex < $1.sourceIndex }
                return $0.location < $1.location
            }
            prepared.append((source: source, entries: entries))
        }
        prepared.sort {
            $0.source.title.localizedCaseInsensitiveCompare($1.source.title) == .orderedAscending
        }
        guard !Task.isCancelled else { return [] }
        return prepared.map { value in
            PreparedHighlightGroup(
                bookID: value.source.bookID,
                sourceIndices: value.entries.map(\.sourceIndex),
                normalizedTexts: value.entries.map(\.normalizedText)
            )
        }
    }

    @concurrent
    private static func filter(
        _ groups: [PreparedHighlightGroup],
        query: String
    ) async -> [VisibleHighlightGroup] {
        var matches: [VisibleHighlightGroup] = []
        matches.reserveCapacity(groups.count)
        for group in groups {
            guard !Task.isCancelled else { return [] }
            let indices = group.normalizedTexts.indices.filter {
                group.normalizedTexts[$0].contains(query)
            }
            if !indices.isEmpty {
                matches.append(VisibleHighlightGroup(
                    bookID: group.bookID,
                    highlightIndices: indices
                ))
            }
        }
        return matches
    }

    // MARK: - Export

    private func exportHighlights() {
        Task {
            guard let folder = await FilePanel.chooseFolder(
                message: String(localized: "Choose a folder to export highlights into."),
                prompt: String(localized: "Export")
            ) else { return }

            let snapshots = sourceGroups.map { snapshot($0) }
            dismiss()
            let result = await Task.detached(priority: .userInitiated) {
                HighlightsExporter.export(snapshots, to: folder)
            }.value
            toasts.success(String(localized: "Highlights exported (\(result.written))."))
        }
    }

    private func snapshot(_ group: BookGroup) -> HighlightsExporter.BookHighlights {
        let entries = group.highlights
            .map { HighlightsExporter.BookHighlights.Entry(text: $0.text, isNote: $0.isNote, location: $0.location) }
        return .init(title: group.book.displayTitle, author: group.book.displayAuthor, entries: entries)
    }
}

// MARK: - Sections

private struct HighlightBookSection: View {
    let title: String
    let author: String?
    let highlights: [Highlight]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(theme.body(size: 13, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                if let author {
                    Text(author)
                        .font(theme.label(size: 10))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            ForEach(highlights) { HighlightRow(highlight: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HighlightRow: View {
    let highlight: Highlight

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: highlight.isNote ? "note.text" : "quote.opening")
                .font(.system(size: 10))
                .foregroundStyle(theme.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.text)
                    .font(theme.label(size: 11, weight: .regular))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let location = highlight.location {
                    Text(verbatim: "location \(location)")
                        .font(theme.label(size: 9))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }
}
