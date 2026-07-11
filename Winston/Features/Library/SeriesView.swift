import AppKit
import SwiftUI

struct SeriesView: View {
    let books: [Book]
    let onOpen: (Book) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings

    @State private var seriesGroups: [SeriesGroup] = []
    @State private var completionModel: SeriesCompletionViewModel
    @State private var retryGeneration = 0

    init(
        books: [Book],
        onOpen: @escaping (Book) -> Void,
        catalogService: any SeriesCatalogFetching = HardcoverSeriesService()
    ) {
        self.books = books
        self.onOpen = onOpen
        _completionModel = State(
            initialValue: SeriesCompletionViewModel(service: catalogService)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SeriesSheetHeader()
            Divider()

            if let notice = catalogNotice {
                SeriesCatalogNotice(state: notice, onRetry: { retryGeneration += 1 })
                Divider().opacity(0.35)
            }

            if seriesGroups.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No series yet"), systemImage: "books.vertical")
                } description: {
                    Text("Books with a series (and a series number) appear here in reading order.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(seriesGroups) { group in
                            SeriesSection(
                                name: group.name,
                                books: group.books,
                                completion: completionModel.completions[group.lookup.id],
                                catalogPhase: completionModel.phase,
                                onOpen: onOpen
                            )
                        }
                    }
                    .padding(18)
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(
            minWidth: 560,
            idealWidth: 680,
            maxWidth: 1_050,
            minHeight: 600,
            idealHeight: 780,
            maxHeight: .infinity
        )
        .onAppear { seriesGroups = makeGroups() }
        .task(id: catalogTaskID) {
            let token = settings.hardcoverToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard settings.onlineMetadataEnabled, !token.isEmpty else {
                completionModel.reset()
                return
            }
            await completionModel.load(
                lookups: seriesGroups.map(\.lookup),
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
        let groupFingerprint = seriesGroups.map { group in
            let books = group.books.map {
                "\($0.uuid.uuidString):\($0.displayTitle):\($0.seriesIndex ?? "-")"
            }.joined(separator: ",")
            return "\(group.id):\(books)"
        }.joined(separator: "|")
        return CatalogTaskID(
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
        let withSeries = books.filter { !($0.series ?? "").isEmpty }
        return Dictionary(grouping: withSeries, by: { $0.series ?? "" })
            .map { name, groupBooks in
                let sortedBooks = groupBooks.sorted { lhs, rhs in
                    let left = seriesIndex(lhs)
                    let right = seriesIndex(rhs)
                    if left != right { return left < right }
                    return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
                }
                let authors = Array(Set(sortedBooks.compactMap(\.displayAuthor))).sorted()
                let snapshots = sortedBooks.map {
                    SeriesLocalBookSnapshot(
                        id: $0.uuid,
                        title: $0.displayTitle,
                        author: $0.displayAuthor,
                        position: $0.seriesIndex.flatMap(Double.init)
                    )
                }
                return SeriesGroup(
                    id: name,
                    name: name,
                    books: sortedBooks,
                    lookup: SeriesLookup(name: name, authors: authors, books: snapshots)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func seriesIndex(_ book: Book) -> Double {
        book.seriesIndex.flatMap(Double.init) ?? .greatestFiniteMagnitude
    }
}

private struct SeriesSheetHeader: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            if theme.usesTerminalCopy {
                Text(verbatim: "// series")
                    .font(theme.body(size: 15, weight: .bold))
            } else {
                Text("Series")
                    .font(theme.body(size: 15, weight: .bold))
            }
            Spacer()
        }
        .padding(16)
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
                Button("Open Settings", action: openSettingsWindow)
                    .controlSize(.small)
            case .tokenMissing:
                Image(systemName: "key")
                Text("Add a Hardcover API token to check which series books are missing.")
                Spacer()
                Button("Open Settings", action: openSettingsWindow)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.surfaceGlass.opacity(0.45))
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

// MARK: - One local series

private struct SeriesSection: View {
    let name: String
    let books: [Book]
    let completion: SeriesCompletion?
    let catalogPhase: SeriesCompletionViewModel.Phase
    let onOpen: (Book) -> Void

    @Environment(\.theme) private var theme

    private var readCount: Int { books.filter { $0.readingStatus == .finished }.count }
    private var nextUnread: Book? { books.first { $0.readingStatus != .finished } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SeriesSectionHeader(name: name, nextUnread: nextUnread, onOpen: onOpen)
            LocalReadingProgress(readCount: readCount, totalCount: books.count)

            if let completion {
                SeriesOwnershipSummary(completion: completion)
            } else if catalogPhase == .loaded {
                Label("No exact Hardcover match", systemImage: "questionmark.circle")
                    .font(theme.label(size: 9, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
                    .help("The series name, author, and local titles did not identify one unambiguous Hardcover series.")
            }

            VStack(spacing: 4) {
                ForEach(books) { book in
                    SeriesLocalBookRow(book: book)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.surfaceGlass.opacity(0.32), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.borderSubtle, lineWidth: 1)
        }
    }
}

private struct SeriesSectionHeader: View {
    let name: String
    let nextUnread: Book?
    let onOpen: (Book) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Text(verbatim: name)
                .font(theme.body(size: 13, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
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
        HStack(spacing: 8) {
            ProgressView(value: Double(readCount), total: Double(max(totalCount, 1)))
                .tint(theme.accent)
                .frame(maxWidth: 200)
            Text("Read \(readCount) of \(totalCount)",
                 comment: "Reading progress within the local series: first value is read books, second is local books.")
                .font(theme.label(size: 9, weight: .regular))
                .foregroundStyle(theme.textTertiary)
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
            Image(systemName: book.readingStatus == .finished ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(book.readingStatus == .finished ? theme.success : theme.textTertiary)
            Text(book.displayTitle)
                .font(theme.label(size: 11, weight: .regular))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            Spacer()
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
        .padding(10)
        .background(theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(theme.accent.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct MissingSeriesBookRow: View {
    let book: HardcoverSeriesBook

    @Environment(\.theme) private var theme

    var body: some View {
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
