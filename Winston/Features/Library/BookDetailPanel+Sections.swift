import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Empty / multi

struct DetailEmptyState: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ContentUnavailableView {
            Label(theme.copy.selectABook, systemImage: "book.pages")
                .font(theme.label(size: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DetailMultiSelection: View {
    let count: Int
    let convertibleCount: Int
    let actions: BookActions

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 28, weight: .thin))
                .foregroundStyle(theme.textTertiary.opacity(0.6))
            Text("\(count) books selected")
                .font(theme.label(size: 12))
                .foregroundStyle(theme.textSecondary)

            VStack(spacing: 6) {
                DetailActionButton(title: theme.styledText(terminal: "EDIT", native: "Edit Metadata"),
                                   icon: "pencil", color: theme.accentSecondary) {
                    actions.editSelection()
                }
                if convertibleCount > 0 {
                    DetailActionButton(
                        title: theme.styledText(terminal: "CONVERT \(convertibleCount)",
                                                native: "Convert \(convertibleCount) for Kindle"),
                        icon: "arrow.triangle.2.circlepath", color: theme.accent
                    ) {
                        actions.convertSelection()
                    }
                }
                DetailActionButton(title: theme.styledText(terminal: "DELETE", native: "Delete"),
                                   icon: "trash", color: theme.destructive) {
                    actions.deleteSelection()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Single book

struct DetailSingleBook: View {
    let book: Book
    let viewModel: LibraryViewModel
    let actions: BookActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailCover(book: book, actions: actions)
                VStack(alignment: .leading, spacing: 8) {
                    DetailIdentity(title: book.displayTitle, author: book.displayAuthor)
                    DetailStatusRow(book: book, actions: actions)
                    DetailActions(book: book, actions: actions, isConverting: viewModel.isConverting(book))
                    Divider().opacity(WinstonLayout.dividerOpacity)
                    DetailMetadataList(book: book)
                    DetailRatingRow(book: book, viewModel: viewModel)
                    if let community = book.communityRating {
                        DetailCommunityRating(average: community, count: book.communityRatingCount,
                                              source: book.communityRatingSource)
                    }
                    if let description = book.bookDescription?.strippedHTML, !description.isEmpty {
                        Divider().opacity(WinstonLayout.dividerOpacity)
                        DetailDescription(text: description)
                    }
                    if !book.highlights.isEmpty {
                        Divider().opacity(WinstonLayout.dividerOpacity)
                        DetailHighlights(highlights: book.highlights)
                    }
                    Divider().opacity(WinstonLayout.dividerOpacity)
                    DetailNotes(book: book, viewModel: viewModel)
                    Divider().opacity(WinstonLayout.dividerOpacity)
                    DetailFileInfo(book: book)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
        }
        .scrollContentBackground(.hidden)
    }
}

struct DetailCover: View {
    let book: Book
    let actions: BookActions

    @State private var isDropTargeted = false

    var body: some View {
        BookCoverImageView(book: book)
            .frame(maxWidth: .infinity)
            .aspectRatio(WinstonLayout.coverAspect, contentMode: .fill)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: WinstonLayout.cornerMedium, style: .continuous))
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: WinstonLayout.cornerMedium, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .shadow(color: Color.black.opacity(0.20), radius: 6, y: 3)
            .padding(14)
            .contextMenu {
                Button("Choose Cover\u{2026}") { chooseCover() }
                Button("Reset Cover") { actions.resetCover(book) }
            }
            .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                handleImageDrop(providers)
            }
            .help("Drop an image, or right-click to change the cover")
    }

    private func chooseCover() {
        Task {
            guard let url = await FilePanel.chooseFile(
                message: String(localized: "Choose a cover image."),
                allowedContentTypes: [.image]
            ) else { return }
            actions.setCover(book, url)
        }
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSURL.self) { reading, _ in
            guard let url = reading as? URL else { return }
            Task { @MainActor in actions.setCover(book, url) }
        }
        return true
    }
}

struct DetailIdentity: View {
    let title: String
    let author: String?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(theme.body(size: 13, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(3)
                .help(title)
            if let author {
                Text("by \(author)")
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }
}

struct DetailStatusRow: View {
    let book: Book
    let actions: BookActions

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(
                get: { book.readingStatus },
                set: { actions.setStatus(book, $0) }
            )) {
                ForEach(ReadingStatus.allCases) { status in
                    Text(theme.usesTerminalCopy ? status.terminalLabel : status.label).tag(status)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if book.dateStarted != nil || book.dateFinished != nil {
                HStack(spacing: 10) {
                    if let started = book.dateStarted {
                        readingDate(label: theme.styledText(terminal: "started", native: "Started"), date: started)
                    }
                    if let finished = book.dateFinished {
                        readingDate(label: theme.styledText(terminal: "finished", native: "Finished"), date: finished)
                    }
                }
            }
        }
    }

    private func readingDate(label: Text, date: Date) -> some View {
        HStack(spacing: 4) {
            label
                .font(theme.label(size: 9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Text(date, format: .dateTime.day().month().year())
                .font(theme.label(size: 9))
                .foregroundStyle(theme.textSecondary)
        }
    }
}

struct DetailActions: View {
    let book: Book
    let actions: BookActions
    let isConverting: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                DetailActionButton(title: theme.styledText(terminal: "OPEN", native: "Open"),
                                   icon: "book", color: theme.accentSecondary) {
                    actions.open(book)
                }
                DetailActionButton(title: theme.styledText(terminal: "FINDER", native: "Finder"),
                                   icon: "folder", color: theme.accentSecondary) {
                    actions.showInFinder(book)
                }
            }
            HStack(spacing: 6) {
                DetailActionButton(title: theme.styledText(terminal: "EDIT", native: "Edit"),
                                   icon: "pencil", color: theme.accentTertiary) {
                    actions.edit(book)
                }
                DetailActionButton(title: theme.styledText(terminal: "DELETE", native: "Delete"),
                                   icon: "trash", color: theme.destructive) {
                    actions.delete(book)
                }
            }
            if EbookConverter.needsConversion(format: book.format) {
                if isConverting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(theme.usesTerminalCopy ? "converting..." : "Converting\u{2026}")
                            .font(theme.label(size: 9, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                } else {
                    DetailActionButton(title: theme.styledText(terminal: "CONVERT", native: "Convert for Kindle"),
                                       icon: "arrow.triangle.2.circlepath", color: theme.accent) {
                        actions.convert(book)
                    }
                    .disabled(!EbookConverter.canConvertForKindle(book.format))
                    .help(EbookConverter.canConvertForKindle(book.format) ? "Convert to a Kindle-friendly format"
                                                                          : "Install calibre to convert books")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct DetailMetadataList: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DetailMetaRow(key: "FORMAT", value: book.format.isEmpty ? "\u{2014}" : book.format)
            DetailMetaRow(key: "SIZE", value: book.fileSizeDisplay)
            if let publisher = book.publisher, !publisher.isEmpty { DetailMetaRow(key: "PUB", value: publisher) }
            if let year = book.year, !year.isEmpty { DetailMetaRow(key: "YEAR", value: year) }
            if let language = book.language, !language.isEmpty { DetailMetaRow(key: "LANG", value: language) }
            if let isbn = book.isbn, !isbn.isEmpty { DetailMetaRow(key: "ISBN", value: isbn) }
            if let series = book.series, !series.isEmpty {
                DetailMetaRow(key: "SERIES", value: book.seriesIndex.map { "\(series) #\($0)" } ?? series)
            }
            if !book.tags.isEmpty { DetailMetaRow(key: "TAGS", value: book.tags.joined(separator: ", ")) }
        }
    }
}

struct DetailRatingRow: View {
    let book: Book
    let viewModel: LibraryViewModel

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            Text("RATING")
                .frame(width: 52, alignment: .leading)
                .font(theme.label(size: 10, weight: .regular))
                .foregroundStyle(theme.textTertiary)
            ForEach(1...5, id: \.self) { star in
                Button {
                    viewModel.updateRating(for: book, rating: book.rating == star ? nil : star)
                } label: {
                    Image(systemName: (book.rating ?? 0) >= star ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundStyle((book.rating ?? 0) >= star ? theme.highlight : theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct DetailCommunityRating: View {
    let average: Double
    let count: Int?
    let source: String?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                theme.styledText(terminal: "READERS", native: "Readers")
                    .frame(width: 52, alignment: .leading)
                    .font(theme.label(size: 10, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
                ForEach(1...5, id: \.self) { position in
                    Image(systemName: starName(for: position))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.highlight)
                }
                Text(average, format: .number.precision(.fractionLength(1)))
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.leading, 3)
            }
            if let subline {
                Text(verbatim: subline)
                    .font(theme.label(size: 9, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, 54)
            }
        }
    }

    private func starName(for position: Int) -> String {
        let threshold = Double(position)
        if average >= threshold - 0.25 { return "star.fill" }
        if average >= threshold - 0.75 { return "star.leadinghalf.filled" }
        return "star"
    }

    private var subline: String? {
        let parts = [count.map { "(\($0.formatted()))" }, source].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}

struct DetailDescription: View {
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            theme.styledText(terminal: "ABOUT", native: "About")
                .font(theme.label(size: 10, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Text(text)
                .font(theme.label(size: 11, weight: .regular))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailHighlights: View {
    private let highlights: [Highlight]

    init(highlights: [Highlight]) {
        self.highlights = highlights.sorted { ($0.location ?? "") < ($1.location ?? "") }
    }

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(theme.usesTerminalCopy ? "HIGHLIGHTS (\(highlights.count))" : "Highlights (\(highlights.count))")
                .font(theme.label(size: 10, weight: .semibold))
                .foregroundStyle(theme.textTertiary)

            ForEach(highlights) { highlight in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: highlight.isNote ? "note.text" : "quote.opening")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.accent)
                        .padding(.top, 2)
                    Text(highlight.text)
                        .font(theme.label(size: 11, weight: .regular))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailNotes: View {
    let book: Book
    let viewModel: LibraryViewModel

    @Environment(\.theme) private var theme
    @State private var draft = ""
    @State private var editing: Book?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            theme.styledText(terminal: "NOTES", native: "My Notes")
                .font(theme.label(size: 10, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            TextEditor(text: $draft)
                .font(theme.label(size: 11, weight: .regular))
                .foregroundStyle(theme.textSecondary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 56)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.surface.opacity(0.4)))
                .themedBorder(cornerRadius: 6)
                .focused($focused)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: book.uuid, initial: true) {
            commit()
            editing = book
            draft = book.notes ?? ""
        }
        .onDisappear { commit() }
    }

    private func commit() {
        guard let editing, (editing.notes ?? "") != draft else { return }
        viewModel.updateNotes(draft, for: editing)
    }
}

struct DetailFileInfo: View {
    let book: Book

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DetailMetaRow(key: "FILE", value: book.originalFileName)
            DetailMetaRow(key: "PATH", value: book.fileURL.deletingLastPathComponent().path)
            Text("Added \(book.dateAdded.formatted(date: .abbreviated, time: .shortened))")
                .font(theme.label(size: 9, weight: .regular))
                .foregroundStyle(theme.textTertiary)
                .padding(.top, 4)
        }
    }
}

// MARK: - Meta row

struct DetailMetaRow: View {
    let key: String
    let value: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(key)
                .frame(width: 52, alignment: .leading)
                .foregroundStyle(theme.textTertiary)
            Text(value)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(theme.label(size: 10, weight: .regular))
    }
}
