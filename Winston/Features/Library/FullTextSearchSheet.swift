import Observation
import SwiftUI

@MainActor
@Observable
final class FullTextSearchViewModel {
    enum Phase: Equatable {
        case idle
        case indexing(searchableBooks: Int)
        case ready(FullTextIndexSummary)
        case failed(String)
    }

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }
    private(set) var phase: Phase = .idle
    private(set) var results: [FullTextBookResult] = []
    private(set) var isSearching = false

    @ObservationIgnored private let service: FullTextIndexService
    @ObservationIgnored private var preparationTask: Task<FullTextIndexSummary, Error>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var preparationGeneration = 0
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var lastPreparedRevision: Int?
    @ObservationIgnored private var lastManualRefreshGeneration = 0

    init(service: FullTextIndexService = .shared) {
        self.service = service
    }

    func prepare(
        books: [Book],
        fullTextRevision: Int,
        manualRefreshGeneration: Int
    ) async {
        preparationGeneration &+= 1
        let generation = preparationGeneration
        preparationTask?.cancel()
        searchTask?.cancel()
        searchGeneration &+= 1
        isSearching = false

        let forceReindex = manualRefreshGeneration != lastManualRefreshGeneration
        let delta = lastPreparedRevision.map {
            LibraryMutationLog.shared.fullTextDelta(since: $0)
        }
        let requiresFullSynchronization = forceReindex
            || delta == nil
            || delta?.requiresFullRebuild == true
        let currentBookIDs = Set(books.map(\.uuid))
        let changedBookIDs = delta?.affectedBookIDs ?? []
        let snapshots = Self.snapshots(
            from: requiresFullSynchronization
                ? books
                : books.filter { changedBookIDs.contains($0.uuid) }
        )
        let removedBookIDs = requiresFullSynchronization
            ? Set<UUID>()
            : changedBookIDs.subtracting(currentBookIDs)
        let searchableBooks = if case .ready(let summary) = phase {
            summary.searchableBooks
        } else {
            snapshots.count { $0.source != nil }
        }
        phase = .indexing(searchableBooks: searchableBooks)

        let task = Task { [service] in
            if requiresFullSynchronization {
                try await service.synchronize(snapshots, forceReindex: forceReindex)
            } else {
                try await service.applyChanges(snapshots, removing: removedBookIDs)
            }
        }
        preparationTask = task

        do {
            let summary = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled, generation == preparationGeneration else { return }
            preparationTask = nil
            lastPreparedRevision = fullTextRevision
            lastManualRefreshGeneration = manualRefreshGeneration
            phase = .ready(summary)
            scheduleSearch(immediately: true)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == preparationGeneration else { return }
            preparationTask = nil
            phase = .failed(String(localized: "The local search index couldn’t be prepared."))
        }
    }

    func cancel() {
        preparationGeneration &+= 1
        searchGeneration &+= 1
        preparationTask?.cancel()
        searchTask?.cancel()
        preparationTask = nil
        searchTask = nil
        isSearching = false
    }

    private func scheduleSearch(immediately: Bool = false) {
        searchGeneration &+= 1
        let generation = searchGeneration
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        guard case .ready = phase else {
            results = []
            isSearching = false
            return
        }

        results = []
        isSearching = true
        searchTask = Task { [weak self, service] in
            if !immediately {
                do {
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let found: [FullTextBookResult]
            do {
                found = try await service.search(trimmed)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self,
                      generation == self.searchGeneration else { return }
                self.results = []
                self.isSearching = false
                self.phase = .failed(String(localized: "The local search index couldn’t be searched."))
                return
            }
            guard !Task.isCancelled, let self,
                  generation == self.searchGeneration,
                  self.query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            self.results = found
            self.isSearching = false
        }
    }

    private struct SourceCandidate {
        let source: FullTextBookSnapshot.Source
        let isPrimary: Bool
        let originRank: Int
    }

    private static func snapshots(from books: [Book]) -> [FullTextBookSnapshot] {
        books.map { book in
            var candidates = book.assets.map { asset in
                SourceCandidate(
                    source: .init(
                        fileURL: asset.fileURL,
                        generation: .init(
                            assetID: asset.uuid,
                            fileName: asset.fileName,
                            contentHash: asset.contentHash,
                            sizeBytes: asset.sizeBytes,
                            dateAdded: asset.dateAdded
                        )
                    ),
                    isPrimary: asset.fileName == book.fileName,
                    originRank: rank(asset.origin)
                )
            }
            if ManagedLeafName(rawValue: book.fileName) != nil,
               !candidates.contains(where: { $0.source.fileURL.lastPathComponent == book.fileName }) {
                candidates.append(SourceCandidate(
                    source: .init(
                        fileURL: BookFileStore.url(for: book.fileName),
                        generation: .init(
                            assetID: book.uuid,
                            fileName: book.fileName,
                            contentHash: nil,
                            sizeBytes: book.fileSizeBytes,
                            dateAdded: book.dateAdded
                        )
                    ),
                    isPrimary: true,
                    originRank: 0
                ))
            }

            let source = candidates
                .filter { FullTextIndexService.supportedFormats.contains($0.source.format) }
                .sorted(by: candidateComesFirst)
                .first?.source
            return FullTextBookSnapshot(
                bookID: book.uuid,
                title: book.displayTitle,
                author: book.displayAuthor,
                source: source
            )
        }
    }

    private static func candidateComesFirst(_ lhs: SourceCandidate, _ rhs: SourceCandidate) -> Bool {
        if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
        if lhs.originRank != rhs.originRank { return lhs.originRank < rhs.originRank }
        let leftFormat = formatRank(lhs.source.format)
        let rightFormat = formatRank(rhs.source.format)
        if leftFormat != rightFormat { return leftFormat < rightFormat }
        return lhs.source.fileURL.path < rhs.source.fileURL.path
    }

    private static func rank(_ origin: AssetOrigin) -> Int {
        switch origin {
        case .original: 0
        case .imported: 1
        case .generated: 2
        }
    }

    private static func formatRank(_ format: String) -> Int {
        switch format {
        case "epub": 0
        case "html", "htm": 1
        case "txt": 2
        case "pdf": 3
        default: 4
        }
    }
}

struct FullTextSearchSheet: View {
    private struct PreparationID: Equatable {
        let fullTextRevision: Int
        let manualRefreshGeneration: Int
    }

    let books: [Book]
    let onOpen: (UUID) -> Void
    let onShowInLibrary: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var model = FullTextSearchViewModel()
    @State private var manualRefreshGeneration = 0

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            FullTextSearchHeader(
                query: $model.query,
                phase: model.phase,
                isSearching: model.isSearching
            )
            Divider()
            FullTextSearchContent(
                phase: model.phase,
                query: model.query,
                results: model.results,
                isSearching: model.isSearching,
                onOpen: onOpen,
                onShowInLibrary: onShowInLibrary,
                onRetry: refreshIndex
            )
            Divider()
            FullTextSearchFooter(
                phase: model.phase,
                onRefresh: refreshIndex,
                onDone: { dismiss() }
            )
        }
        .frame(minWidth: 700, idealWidth: 820, maxWidth: 1060,
               minHeight: 560, idealHeight: 700, maxHeight: 940)
        .background(theme.background)
        .task(id: PreparationID(
            fullTextRevision: LibraryMutationLog.shared.fullTextRevision,
            manualRefreshGeneration: manualRefreshGeneration
        )) {
            await model.prepare(
                books: books,
                fullTextRevision: LibraryMutationLog.shared.fullTextRevision,
                manualRefreshGeneration: manualRefreshGeneration
            )
        }
        .onDisappear { model.cancel() }
    }

    private func refreshIndex() {
        manualRefreshGeneration &+= 1
    }
}

private struct FullTextSearchHeader: View {
    @Binding var query: String
    let phase: FullTextSearchViewModel.Phase
    let isSearching: Bool

    @Environment(\.theme) private var theme
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    theme.styledText(terminal: "// full_text_search", native: "Search Inside Books")
                        .font(theme.body(size: 18, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Search EPUB, PDF, TXT, and HTML without leaving your Mac.")
                        .font(theme.label(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                FullTextIndexStatus(phase: phase, isSearching: isSearching)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                TextField("Search for a word or phrase", text: $query)
                    .textFieldStyle(.plain)
                    .font(theme.body(size: 13))
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Search")
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(theme.surface.opacity(0.64), in: RoundedRectangle(
                cornerRadius: WinstonLayout.cornerMedium,
                style: .continuous
            ))
            .themedBorder(cornerRadius: WinstonLayout.cornerMedium)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .onAppear { searchFocused = true }
    }
}

private struct FullTextIndexStatus: View {
    let phase: FullTextSearchViewModel.Phase
    let isSearching: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
            }
            Text(statusText)
                .foregroundStyle(theme.textSecondary)
        }
        .font(theme.label(size: 10, weight: .semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(theme.surfaceGlass, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusText)
    }

    private var isBusy: Bool {
        if isSearching { return true }
        if case .indexing = phase { return true }
        return false
    }

    private var statusIcon: String {
        if case .failed = phase { return "exclamationmark.triangle.fill" }
        return "lock.fill"
    }

    private var statusColor: Color {
        if case .failed = phase { return theme.destructive }
        return theme.success
    }

    private var statusText: String {
        if isSearching { return String(localized: "Searching…") }
        switch phase {
        case .idle:
            return String(localized: "Local index")
        case .indexing(let count):
            return String(
                localized: "Indexing \(count) books…",
                comment: "Full-text indexing progress; the value is the number of searchable books."
            )
        case .ready(let summary):
            return String(
                localized: "\(summary.searchableBooks) books indexed",
                comment: "Full-text index status; the value is the number of searchable books."
            )
        case .failed:
            return String(localized: "Index unavailable")
        }
    }
}

private struct FullTextSearchContent: View {
    let phase: FullTextSearchViewModel.Phase
    let query: String
    let results: [FullTextBookResult]
    let isSearching: Bool
    let onOpen: (UUID) -> Void
    let onShowInLibrary: (UUID) -> Void
    let onRetry: () -> Void

    var body: some View {
        Group {
            switch phase {
            case .idle, .indexing:
                FullTextIndexingState()
            case .failed(let message):
                FullTextFailureState(message: message, onRetry: onRetry)
            case .ready(let summary):
                if summary.searchableBooks == 0 {
                    FullTextNoBooksState()
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                    FullTextPromptState(searchableBooks: summary.searchableBooks)
                } else if isSearching {
                    FullTextSearchingState()
                } else if results.isEmpty {
                    FullTextNoMatchesState(query: query)
                } else {
                    FullTextResultsList(
                        results: results,
                        query: query,
                        onOpen: onOpen,
                        onShowInLibrary: onShowInLibrary
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FullTextIndexingState: View {
    var body: some View {
        ContentUnavailableView {
            ProgressView()
                .controlSize(.large)
        } description: {
            Text("Building a private search index on this Mac…")
        }
    }
}

private struct FullTextSearchingState: View {
    var body: some View {
        ContentUnavailableView {
            ProgressView()
                .controlSize(.large)
        } description: {
            Text("Searching chapters and pages…")
        }
    }
}

private struct FullTextFailureState: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Search Index Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: onRetry)
        }
    }
}

private struct FullTextNoBooksState: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Searchable Books", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Add an EPUB, PDF, TXT, or HTML book to search inside its text.")
        }
    }
}

private struct FullTextPromptState: View {
    let searchableBooks: Int

    var body: some View {
        ContentUnavailableView {
            Label("Search Inside Books", systemImage: "text.magnifyingglass")
        } description: {
            Text(
                "Enter at least two characters to search \(searchableBooks) locally indexed books.",
                comment: "Full-text search prompt; the value is the number of searchable books."
            )
        }
    }
}

private struct FullTextNoMatchesState: View {
    let query: String

    var body: some View {
        ContentUnavailableView.search(text: query)
    }
}

private struct FullTextResultsList: View {
    let results: [FullTextBookResult]
    let query: String
    let onOpen: (UUID) -> Void
    let onShowInLibrary: (UUID) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(results) { result in
                    FullTextBookResultSection(
                        result: result,
                        query: query,
                        onOpen: { onOpen(result.bookID) },
                        onShowInLibrary: { onShowInLibrary(result.bookID) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }
}

private struct FullTextBookResultSection: View {
    let result: FullTextBookResult
    let query: String
    let onOpen: () -> Void
    let onShowInLibrary: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 24, height: 24)
                    .background(theme.accent.opacity(0.12), in: RoundedRectangle(
                        cornerRadius: WinstonLayout.cornerSmall,
                        style: .continuous
                    ))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(theme.body(size: 14, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                    if let author = result.author {
                        Text(author)
                            .font(theme.label(size: 10))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                Spacer(minLength: 10)
                Text(verbatim: result.format)
                    .font(theme.label(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                Text(
                    "\(result.matchCount) matches",
                    comment: "Full-text result count for one book."
                )
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textTertiary)
                Button("Show in Library", action: onShowInLibrary)
                    .controlSize(.small)
                Button("Open", action: onOpen)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(result.chapters) { chapter in
                    FullTextChapterSection(chapter: chapter, query: query, onOpen: onOpen)
                }
            }
            .padding(.leading, 34)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FullTextChapterSection: View {
    let chapter: FullTextChapterResult
    let query: String
    let onOpen: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(locationTitle, systemImage: chapter.kind == .page ? "doc.text" : "text.book.closed")
                .font(theme.label(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)

            VStack(spacing: 0) {
                ForEach(chapter.excerpts) { excerpt in
                    Button(action: onOpen) {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "quote.opening")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(theme.accent)
                                .padding(.top, 3)
                                .accessibilityHidden(true)
                            HighlightedFullText(text: excerpt.text, query: query)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(theme.textTertiary)
                                .padding(.top, 3)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open book in the default reader")
                    .accessibilityLabel(excerpt.text)
                    .accessibilityHint("Open book in the default reader")

                    if excerpt.id != chapter.excerpts.last?.id {
                        Divider().padding(.leading, 28)
                    }
                }
            }
            .background(theme.surface.opacity(0.42), in: RoundedRectangle(
                cornerRadius: WinstonLayout.cornerMedium,
                style: .continuous
            ))
        }
    }

    private var locationTitle: String {
        if let title = chapter.title, !title.isEmpty { return title }
        switch chapter.kind {
        case .chapter:
            return String(
                localized: "Chapter \(chapter.ordinal)",
                comment: "Fallback full-text result location; the value is the chapter number."
            )
        case .page:
            return String(
                localized: "Page \(chapter.ordinal)",
                comment: "Full-text PDF result location; the value is the page number."
            )
        case .document:
            return String(localized: "Document")
        }
    }
}

private struct HighlightedFullText: View {
    let text: String
    let query: String

    @Environment(\.theme) private var theme

    var body: some View {
        Text(attributedText)
            .font(theme.label(size: 11, weight: .regular))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var attributedText: AttributedString {
        var attributed = AttributedString(text)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        if let stringRange = text.range(of: query, options: options),
           let range = Range(stringRange, in: attributed) {
            attributed[range].foregroundColor = theme.accent
            attributed[range].font = theme.label(size: 11, weight: .bold)
        }
        return attributed
    }
}

private struct FullTextSearchFooter: View {
    let phase: FullTextSearchViewModel.Phase
    let onRefresh: () -> Void
    let onDone: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Label("Local only · no network requests", systemImage: "lock.shield")
                .font(theme.label(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            if case .ready(let summary) = phase, summary.failedBooks > 0 {
                Text(
                    "\(summary.failedBooks) files couldn’t be indexed",
                    comment: "Full-text index warning; the value is the number of failed files."
                )
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.destructive)
            }
            Spacer()
            Button("Refresh Index", action: onRefresh)
                .disabled(isBusy)
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var isBusy: Bool {
        if case .indexing = phase { return true }
        return false
    }
}
