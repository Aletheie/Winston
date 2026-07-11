import SwiftUI
import SwiftData
import AppKit

struct HighlightsView: View {
    let books: [Book]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(ToastCenter.self) private var toasts
    @State private var search = ""
    @State private var visible: [BookGroup] = []

    private struct BookGroup: Identifiable {
        let book: Book
        let highlights: [Highlight]
        var id: PersistentIdentifier { book.id }
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
        .onChange(of: search, initial: true) { recompute() }
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
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.surface.opacity(0.6)))
            .themedBorder(cornerRadius: 6)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if visible.isEmpty {
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

    private var booksWithHighlights: [Book] {
        books.filter { !$0.highlights.isEmpty }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    private func recompute() {
        let query = search.lowercased()
        visible = booksWithHighlights.compactMap { book in
            var highlights = book.highlights.sorted { ($0.location ?? "") < ($1.location ?? "") }
            if !query.isEmpty {
                highlights = highlights.filter { $0.text.lowercased().contains(query) }
            }
            return highlights.isEmpty ? nil : BookGroup(book: book, highlights: highlights)
        }
    }

    private var totalCount: Int {
        booksWithHighlights.reduce(0) { $0 + $1.highlights.count }
    }

    // MARK: - Export

    private func exportHighlights() {
        Task {
            guard let folder = await FilePanel.chooseFolder(
                message: String(localized: "Choose a folder to export highlights into."),
                prompt: String(localized: "Export")
            ) else { return }

            let snapshots = booksWithHighlights.map { snapshot($0) }
            dismiss()
            let result = await Task.detached(priority: .userInitiated) {
                HighlightsExporter.export(snapshots, to: folder)
            }.value
            toasts.success(String(localized: "Highlights exported (\(result.written))."))
        }
    }

    private func snapshot(_ book: Book) -> HighlightsExporter.BookHighlights {
        let entries = book.highlights
            .sorted { ($0.location ?? "") < ($1.location ?? "") }
            .map { HighlightsExporter.BookHighlights.Entry(text: $0.text, isNote: $0.isNote, location: $0.location) }
        return .init(title: book.displayTitle, author: book.displayAuthor, entries: entries)
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
