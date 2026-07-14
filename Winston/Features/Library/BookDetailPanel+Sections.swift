import SwiftUI
import SwiftData
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
                    if book.probablySample {
                        DetailSampleNotice(book: book, viewModel: viewModel)
                    }
                    DetailStatusRow(book: book, actions: actions)
                    DetailActions(book: book, actions: actions, isConverting: viewModel.isConverting(book))
                    if let work = book.work {
                        DetailWork(work: work, actions: actions)
                    }
                    DetailSeries(book: book, actions: actions)
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
                    DetailFiles(book: book, viewModel: viewModel, actions: actions)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
        }
        .scrollContentBackground(.hidden)
        .task(id: book.uuid) { await viewModel.backfillPageCount(for: book) }
    }
}

struct DetailSampleNotice: View {
    let book: Book
    let viewModel: LibraryViewModel

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(theme.highlight)
            theme.styledText(terminal: "LOW PAGE COUNT - SAMPLE?",
                             native: "This might be a sample, not the full book.")
                .font(theme.label(size: 10, weight: .regular))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                viewModel.markNotSample(book)
            } label: {
                theme.styledText(terminal: "[FULL BOOK]", native: "Full book")
                    .font(theme.label(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.highlight.opacity(0.08)))
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

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DetailMetaRow(key: "FORMAT", value: book.format.isEmpty ? "\u{2014}" : book.format)
            DetailMetaRow(key: "SIZE", value: book.fileSizeDisplay)
            if let pages = book.pageCount {
                DetailMetaRow(key: "PAGES", value: book.format == "PDF" ? "\(pages)" : "~\(pages)")
            }
            if let publisher = book.publisher, !publisher.isEmpty { DetailMetaRow(key: "PUB", value: publisher) }
            if let year = book.year, !year.isEmpty { DetailMetaRow(key: "YEAR", value: year) }
            if let language = book.language, !language.isEmpty { DetailMetaRow(key: "LANG", value: language) }
            if let translator = book.translator, !translator.isEmpty {
                DetailMetaRow(
                    key: theme.usesTerminalCopy ? "PREKLAD" : String(localized: "Translator"),
                    value: translator
                )
            }
            if let statement = book.editionStatement, !statement.isEmpty {
                DetailMetaRow(
                    key: theme.usesTerminalCopy ? "VYDANI" : String(localized: "Edition"),
                    value: statement
                )
            }
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

struct DetailWork: View {
    let work: Work
    let actions: BookActions

    @Environment(\.theme) private var theme

    var body: some View {
        Button { actions.openWork(work) } label: {
            HStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    theme.styledText(terminal: "DILO", native: "Work")
                        .font(theme.label(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                    Text(work.displayTitle)
                        .font(theme.label(size: 11, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(work.editions.count) editions")
                    .font(theme.label(size: 9))
                    .foregroundStyle(theme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(8)
            .background(theme.surface.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

struct DetailSeries: View {
    let book: Book
    let actions: BookActions

    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings
    @Query private var members: [Book]
    @State private var remoteConfirmation: RemoteConfirmation?

    init(book: Book, actions: BookActions) {
        self.book = book
        self.actions = actions
        let series = book.series ?? ""
        _members = Query(filter: #Predicate<Book> { $0.series == series })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let series = book.series, !series.isEmpty,
               Self.shouldDisplay(
                   localBookCount: members.count,
                   remoteBookCount: confirmedRemoteBookCount,
                   onlineMetadataEnabled: settings.onlineMetadataEnabled
               ) {
                Button { actions.openSeries(series) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "list.number")
                            .foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            theme.styledText(terminal: "SERIE", native: "Series")
                                .font(theme.label(size: 9, weight: .semibold))
                                .foregroundStyle(theme.textTertiary)
                            Text(verbatim: seriesLabel(series))
                                .font(theme.label(size: 11, weight: .medium))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(members.count) books", comment: "Number of books owned from the selected series.")
                            .font(theme.label(size: 9))
                            .foregroundStyle(theme.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .padding(8)
                    .background(theme.surface.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                SendSeriesButton(books: members)
                    .controlSize(.small)
            }
        }
        .task(id: remoteProbeTaskID, priority: .utility) {
            await confirmRemoteSeriesIfNeeded()
        }
    }

    static func shouldDisplay(
        localBookCount: Int,
        remoteBookCount: Int?,
        onlineMetadataEnabled: Bool
    ) -> Bool {
        localBookCount >= 2
            || (onlineMetadataEnabled && (remoteBookCount ?? 0) >= 2)
    }

    private func seriesLabel(_ series: String) -> String {
        if let index = book.seriesIndex, !index.isEmpty { return "\(series) #\(index)" }
        return series
    }

    private var confirmedRemoteBookCount: Int? {
        guard remoteConfirmation?.probeID == remoteProbeID else { return nil }
        return remoteConfirmation?.bookCount
    }

    private var remoteProbeID: RemoteProbeID? {
        guard members.count == 1,
              let series = book.series?.trimmingCharacters(in: .whitespacesAndNewlines),
              !series.isEmpty,
              let member = members.first else { return nil }
        return RemoteProbeID(
            bookUUID: member.uuid,
            series: series,
            title: member.displayTitle,
            author: member.displayAuthor,
            position: member.seriesIndex
        )
    }

    private var remoteProbeTaskID: RemoteProbeTaskID {
        RemoteProbeTaskID(
            probeID: remoteProbeID,
            localBookCount: members.count,
            onlineMetadataEnabled: settings.onlineMetadataEnabled,
            tokenHash: settings.hardcoverToken.hashValue
        )
    }

    private func confirmRemoteSeriesIfNeeded() async {
        let token = settings.hardcoverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.onlineMetadataEnabled,
              !token.isEmpty,
              let probeID = remoteProbeID,
              confirmedRemoteBookCount == nil else { return }

        let lookup = SeriesLookup(
            name: probeID.series,
            authors: probeID.author.map { [$0] } ?? [],
            books: [
                SeriesLocalBookSnapshot(
                    id: probeID.bookUUID,
                    title: probeID.title,
                    author: probeID.author,
                    position: probeID.position.flatMap(Double.init)
                )
            ]
        )

        switch await HardcoverSeriesService.shared.cacheStatus(for: lookup) {
        case .catalog(let catalog):
            recordRemoteConfirmation(catalog, probeID: probeID)
            return
        case .noMatch:
            return
        case .notCached:
            break
        }

        do {
            try await Task.sleep(for: .milliseconds(450))
            let catalogs = try await HardcoverSeriesService.shared.catalogs(
                matching: [lookup],
                token: token
            )
            try Task.checkCancellation()
            if let catalog = catalogs[lookup.id] {
                recordRemoteConfirmation(catalog, probeID: probeID)
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private func recordRemoteConfirmation(
        _ catalog: HardcoverSeriesCatalog,
        probeID: RemoteProbeID
    ) {
        guard catalog.totalBookCount >= 2 else { return }
        remoteConfirmation = RemoteConfirmation(
            probeID: probeID,
            bookCount: catalog.totalBookCount
        )
    }

    private struct RemoteProbeID: Hashable {
        let bookUUID: UUID
        let series: String
        let title: String
        let author: String?
        let position: String?
    }

    private struct RemoteProbeTaskID: Hashable {
        let probeID: RemoteProbeID?
        let localBookCount: Int
        let onlineMetadataEnabled: Bool
        let tokenHash: Int
    }

    private struct RemoteConfirmation: Equatable {
        let probeID: RemoteProbeID
        let bookCount: Int
    }
}

struct DetailFiles: View {
    let book: Book
    let viewModel: LibraryViewModel
    let actions: BookActions

    @Environment(\.theme) private var theme
    @State private var removeTarget: BookAsset?
    @State private var isConfirmingRemove = false

    var body: some View {
        let assets = sortedAssets

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                theme.styledText(terminal: "FILES", native: "Files")
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                Button(action: addFile) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add File")
                .accessibilityLabel("Add File")
            }
            ForEach(assets) { asset in
                DetailFileRow(
                    book: book,
                    asset: asset,
                    isPrimary: asset.fileName == book.fileName,
                    canRemove: assets.count == 1 || asset.fileName != book.fileName,
                    viewModel: viewModel,
                    onReplace: replaceFile,
                    onRemove: requestRemove
                )
            }
            Text("Added \(book.dateAdded.formatted(date: .abbreviated, time: .shortened))")
                .font(theme.label(size: 9, weight: .regular))
                .foregroundStyle(theme.textTertiary)
                .padding(.top, 4)
        }
        .confirmationDialog(
            "Remove this file?",
            isPresented: $isConfirmingRemove,
            presenting: removeTarget
        ) { asset in
            Button("Remove File", role: .destructive) { _ = viewModel.removeFile(asset, from: book) }
        } message: { _ in
            Text("The file is deleted from Winston’s managed library.")
        }
    }

    private var sortedAssets: [BookAsset] {
        book.assets.sorted {
            if ($0.fileName == book.fileName) != ($1.fileName == book.fileName) {
                return $0.fileName == book.fileName
            }
            return $0.format < $1.format
        }
    }

    private func addFile() {
        Task {
            guard let url = await FilePanel.chooseFile(message: String(localized: "Choose another format for this edition.")) else { return }
            _ = await viewModel.addFile(to: book, from: url)
        }
    }

    private func replaceFile(_ asset: BookAsset) {
        Task {
            guard let url = await FilePanel.chooseFile(message: String(localized: "Choose a replacement file.")) else { return }
            await viewModel.replace(asset, in: book, from: url)
        }
    }

    private func requestRemove(_ asset: BookAsset) {
        if book.assets.count == 1 {
            actions.delete(book)
        } else {
            removeTarget = asset
            isConfirmingRemove = true
        }
    }
}

private struct DetailFileRow: View {
    let book: Book
    let asset: BookAsset
    let isPrimary: Bool
    let canRemove: Bool
    let viewModel: LibraryViewModel
    let onReplace: (BookAsset) -> Void
    let onRemove: (BookAsset) -> Void

    @Environment(\.theme) private var theme
    @Environment(DeviceMonitor.self) private var deviceMonitor
    @Environment(TransferQueue.self) private var transferQueue

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(validationColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel(Text(validationLabel))
            Text(asset.format)
                .font(theme.label(size: 10, weight: .bold))
                .foregroundStyle(theme.accentSecondary)
                .frame(width: 42, alignment: .leading)
            Text(asset.sizeDisplay)
                .font(theme.label(size: 9))
                .foregroundStyle(theme.textSecondary)
            Group {
                switch asset.origin {
                case .original:
                    theme.styledText(terminal: "ORIG", native: "Original")
                case .generated:
                    theme.styledText(terminal: "GEN", native: "Generated")
                case .imported:
                    theme.styledText(terminal: "IMPORT", native: "Imported")
                }
            }
            .font(theme.label(size: 8, weight: .semibold))
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(theme.surface.opacity(0.5), in: Capsule())
            Spacer()
            if isPrimary {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.highlight)
                    .help("Primary file")
                    .accessibilityLabel("Primary file")
            }
            Menu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([asset.fileURL])
                }
                Button("Validate") {
                    Task { await viewModel.validate(asset) }
                }
                Button("Replace…") { onReplace(asset) }
                Button("Make Primary") {
                    Task { await viewModel.makePrimary(asset, for: book) }
                }
                    .disabled(isPrimary)
                Button("Send This Format to Kindle") {
                    transferQueue.beginSend(asset: asset, for: book, via: deviceMonitor)
                }
                Divider()
                Button("Remove File…", role: .destructive) { onRemove(asset) }
                    .disabled(!canRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel("File actions")
        }
        .padding(.vertical, 3)
    }

    private var validationColor: Color {
        switch asset.validationStatus {
        case .ok: theme.success
        case .missing, .corrupt: theme.destructive
        case nil: theme.textTertiary
        }
    }

    private var validationLabel: LocalizedStringResource {
        switch asset.validationStatus {
        case .ok: "File is valid"
        case .missing: "File is missing"
        case .corrupt: "File is corrupt"
        case nil: "File not validated yet"
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
