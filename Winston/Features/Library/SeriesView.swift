import SwiftUI

struct SeriesView: View {
    let books: [Book]
    let onOpen: (Book) -> Void
    let onShowInLibrary: (String) -> Void
    let seriesName: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings

    @State private var displayedGroups: [SeriesGroup] = []
    @State private var groupFingerprint = ""
    @State private var completionModel: SeriesCompletionViewModel
    @State private var retryGeneration = 0

    init(
        books: [Book],
        onOpen: @escaping (Book) -> Void,
        onShowInLibrary: @escaping (String) -> Void,
        seriesName: String? = nil,
        catalogService: any SeriesCatalogFetching = HardcoverSeriesService.shared
    ) {
        self.books = books
        self.onOpen = onOpen
        self.onShowInLibrary = onShowInLibrary
        self.seriesName = seriesName
        self.completionModel = SeriesCompletionViewModel(service: catalogService)
    }

    var body: some View {
        VStack(spacing: 0) {
            SeriesSheetHeader(seriesName: seriesName)
            Divider()

            if let notice = catalogNotice {
                SeriesCatalogNotice(state: notice, onRetry: { retryGeneration += 1 })
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            if displayedGroups.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No series yet"), systemImage: "books.vertical")
                } description: {
                    Text("Books with a series (and a series number) appear here in reading order.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(displayedGroups) { group in
                            SeriesSection(
                                name: group.name,
                                books: group.books,
                                completion: completionModel.completions[group.lookup.id],
                                catalogPhase: completionModel.phase,
                                isFocused: seriesName != nil,
                                onOpen: onOpen,
                                onShowInLibrary: onShowInLibrary
                            )
                        }
                    }
                    .padding(20)
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .background(ThemedBackground())
        .frame(
            minWidth: 560,
            idealWidth: 680,
            maxWidth: 1_050,
            minHeight: 600,
            idealHeight: 780,
            maxHeight: .infinity
        )
        .onAppear { rebuildGroups() }
        .task(id: catalogTaskID) {
            let token = settings.hardcoverToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard settings.onlineMetadataEnabled, !token.isEmpty else {
                completionModel.reset()
                return
            }
            await completionModel.load(
                lookups: displayedGroups.map(\.lookup),
                token: token
            )
        }
    }

    private var catalogNotice: SeriesCatalogNotice.State? {
        if !settings.onlineMetadataEnabled { return .onlineDisabled }
        if settings.hardcoverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .tokenMissing
        }
        switch completionModel.phase {
        case .idle: return nil
        case .loading: return .loading
        case .loaded: return nil
        case .failed: return .failed
        }
    }

    private var catalogTaskID: CatalogTaskID {
        CatalogTaskID(
            onlineEnabled: settings.onlineMetadataEnabled,
            tokenHash: settings.hardcoverToken.hashValue,
            groupFingerprint: groupFingerprint,
            retryGeneration: retryGeneration
        )
    }

    private struct CatalogTaskID: Hashable {
        let onlineEnabled: Bool
        let tokenHash: Int
        let groupFingerprint: String
        let retryGeneration: Int
    }

    private struct SeriesGroup: Identifiable {
        let id: String
        let name: String
        let books: [Book]
        let lookup: SeriesLookup
    }

    private func makeGroups() -> [SeriesGroup] {
        SeriesLookupBuilder.groups(from: books).map {
            SeriesGroup(id: $0.id, name: $0.name, books: $0.books, lookup: $0.lookup)
        }
    }

    private func rebuildGroups() {
        let groups = makeGroups()
        if let seriesName {
            displayedGroups = groups.filter { $0.name == seriesName }
        } else {
            displayedGroups = groups
        }
        groupFingerprint = displayedGroups.map { group in
            let books = group.books.map {
                "\($0.uuid.uuidString):\($0.displayTitle):\($0.seriesIndex ?? "-")"
            }.joined(separator: ",")
            return "\(group.id):\(books)"
        }.joined(separator: "|")
    }
}

private struct SeriesSheetHeader: View {
    let seriesName: String?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(theme.accent.gradient)
                Image(systemName: "list.number")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            .shadow(color: theme.accent.opacity(0.35), radius: 6, y: 3)
            .accessibilityHidden(true)
            if let seriesName {
                VStack(alignment: .leading, spacing: 2) {
                    theme.styledText(terminal: "SERIE", native: "Series")
                        .font(theme.label(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                    Text(verbatim: seriesName)
                        .font(theme.body(size: 17, weight: .bold))
                        .lineLimit(1)
                }
            } else if theme.usesTerminalCopy {
                Text(verbatim: "// series")
                    .font(theme.body(size: 17, weight: .bold))
            } else {
                Text("Series")
                    .font(theme.body(size: 17, weight: .bold))
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Hardcover availability

private struct SeriesCatalogNotice: View {
    enum State {
        case onlineDisabled
        case tokenMissing
        case loading
        case failed
    }

    let state: State
    let onRetry: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            switch state {
            case .onlineDisabled:
                Image(systemName: "network.slash")
                Text("Enable online metadata to check which series books are missing.")
                Spacer()
                SettingsLink {
                    Text("Open Settings")
                }
                    .controlSize(.small)
            case .tokenMissing:
                Image(systemName: "key")
                Text("Add a Hardcover API token to check which series books are missing.")
                Spacer()
                SettingsLink {
                    Text("Open Settings")
                }
                    .controlSize(.small)
            case .loading:
                ProgressView().controlSize(.small)
                Text("Checking series on Hardcover…")
                Spacer()
            case .failed:
                Image(systemName: "wifi.exclamationmark")
                Text("Couldn’t load series details from Hardcover.")
                Spacer()
                Button("Try Again", action: onRetry)
                    .controlSize(.small)
            }
        }
        .font(theme.label(size: 11, weight: .regular))
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 10, tintOpacity: 0.35)
    }

}

// MARK: - One local series

private struct SeriesSection: View {
    let name: String
    let books: [Book]
    let completion: SeriesCompletion?
    let catalogPhase: SeriesCompletionViewModel.Phase
    let isFocused: Bool
    let onOpen: (Book) -> Void
    let onShowInLibrary: (String) -> Void

    @Environment(\.theme) private var theme

    private var readCount: Int { books.filter { $0.readingStatus == .finished }.count }
    private var nextUnread: Book? { books.first { $0.readingStatus != .finished } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SeriesSectionHeader(
                name: name,
                books: books,
                nextUnread: nextUnread,
                onOpen: onOpen,
                onShowInLibrary: onShowInLibrary
            )
            LocalReadingProgress(readCount: readCount, totalCount: books.count)

            if let completion {
                SeriesOwnershipSummary(completion: completion)
            } else if catalogPhase == .loaded {
                Label("No exact Hardcover match", systemImage: "questionmark.circle")
                    .font(theme.label(size: 10, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
                    .help("The series name, author, and local titles did not identify one unambiguous Hardcover series.")
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(books) { book in
                    SeriesLocalBookRow(book: book)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 14, tintOpacity: 0.4)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.accent.opacity(0.55), lineWidth: 1.5)
            }
        }
    }
}

private struct SeriesSectionHeader: View {
    let name: String
    let books: [Book]
    let nextUnread: Book?
    let onOpen: (Book) -> Void
    let onShowInLibrary: (String) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: name)
                .font(theme.body(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Button { onShowInLibrary(name) } label: {
                Label("Show in Library", systemImage: "rectangle.stack")
            }
            .controlSize(.small)
            .help("Show in Library")
            SendSeriesButton(books: books)
                .controlSize(.small)
            if let nextUnread {
                Button { onOpen(nextUnread) } label: {
                    Label("Read next", systemImage: "book")
                }
                .controlSize(.small)
            }
        }
    }
}

private struct LocalReadingProgress: View {
    let readCount: Int
    let totalCount: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(readCount), total: Double(max(totalCount, 1)))
                .tint(theme.accent)
                .frame(maxWidth: 220)
            Text("Read \(readCount) of \(totalCount)",
                 comment: "Reading progress within the local series: first value is read books, second is local books.")
                .font(theme.label(size: 10, weight: .regular))
                .foregroundStyle(theme.textSecondary)
                .monospacedDigit()
        }
    }
}

private struct SeriesLocalBookRow: View {
    let book: Book

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: book.seriesIndex ?? "\u{00B7}")
                .font(theme.label(size: 10, weight: .regular))
                .foregroundStyle(theme.textTertiary)
                .frame(width: 26, alignment: .trailing)
                .monospacedDigit()
            Image(systemName: book.readingStatus.systemImage)
                .font(.system(size: 11))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(readingStatusColor)
                .help(book.readingStatus.label)
            Text(book.displayTitle)
                .font(theme.label(size: 12, weight: .regular))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var readingStatusColor: Color {
        switch book.readingStatus {
        case .unread: theme.textTertiary
        case .reading: theme.accent
        case .paused: theme.highlight
        case .finished: theme.success
        case .didNotFinish: theme.destructive
        }
    }
}

// MARK: - Hardcover completion

private struct SeriesOwnershipSummary: View {
    let completion: SeriesCompletion

    @Environment(\.theme) private var theme

    private var shownMissingCount: Int {
        min(4, completion.missingBooks.count)
    }

    private var remainingMissingCount: Int {
        max(0, completion.missingCount - shownMissingCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if completion.missingCount == 0 {
                    Label("Series complete", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(theme.success)
                } else if theme.usesTerminalCopy {
                    Text(verbatim: "OWNED \(completion.ownedCount)/\(completion.catalog.totalBookCount) // MISSING \(completion.missingCount)")
                } else {
                    Text(
                        "In your library: \(completion.ownedCount) of \(completion.catalog.totalBookCount) · Missing \(completion.missingCount)",
                        comment: "Series ownership summary: first value is owned, second total, third missing."
                    )
                }
                Spacer()
                Link(destination: completion.catalog.hardcoverURL) {
                    Label("Hardcover", systemImage: "arrow.up.right")
                }
                .help("View this series on Hardcover")
            }
            .font(theme.label(size: 10, weight: .semibold))

            ProgressView(
                value: Double(completion.ownedCount),
                total: Double(max(completion.catalog.totalBookCount, 1))
            )
            .tint(completion.missingCount == 0 ? theme.success : theme.accentSecondary)

            if completion.missingCount > 0 {
                Text("Missing books")
                    .font(theme.label(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)

                ForEach(completion.missingBooks.prefix(4)) { book in
                    MissingSeriesBookRow(book: book)
                }

                if remainingMissingCount > 0 {
                    Link(destination: completion.catalog.hardcoverURL) {
                        Text("See \(remainingMissingCount) more on Hardcover")
                    }
                    .font(theme.label(size: 9, weight: .semibold))
                }
            }
        }
        .padding(12)
        .background(theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.accent.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct MissingSeriesBookRow: View {
    let book: HardcoverSeriesBook

    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 7) {
            Link(destination: book.hardcoverURL) {
                HStack(spacing: 7) {
                    Text(verbatim: positionLabel)
                        .font(theme.label(size: 9, weight: .regular))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 34, alignment: .trailing)
                        .monospacedDigit()
                    Text(verbatim: book.title)
                        .font(theme.label(size: 10, weight: .regular))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let externalBookURL {
                Link(destination: externalBookURL) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Search External Website")
                .accessibilityLabel("Search External Website")
            }
        }
    }

    private var externalBookURL: URL? {
        ExternalBookSearchURL.make(
            websiteURL: settings.externalBookWebsiteURL,
            title: book.title,
            author: book.authors.first
        )
    }

    private var positionLabel: String {
        if let text = book.positionText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        guard let position = book.position else { return "\u{00B7}" }
        return position.formatted(.number.precision(.fractionLength(0...2)))
    }
}
