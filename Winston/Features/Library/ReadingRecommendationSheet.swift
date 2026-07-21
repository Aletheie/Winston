import Observation
import SwiftData
import SwiftUI

nonisolated private struct ReadingRecommendationCandidateSource: Sendable {
    let id: UUID
    let title: String
    let author: String?
    let readingStatus: ReadingStatus
    let activeProgress: Double?
    let pageCount: Int?
    let tags: [String]
    let language: String?
    let series: String?
    let seriesIndex: Double?
    let personalRating: Int?
    let communityRating: Double?
    let dateAdded: Date
    let fileURL: URL
    let validationAllowsReading: Bool

    func candidate(fileExists: Bool) -> ReadingRecommendationCandidate {
        ReadingRecommendationCandidate(
            id: id,
            title: title,
            author: author,
            readingStatus: readingStatus,
            activeProgress: activeProgress,
            pageCount: pageCount,
            tags: tags,
            language: language,
            series: series,
            seriesIndex: seriesIndex,
            personalRating: personalRating,
            communityRating: communityRating,
            dateAdded: dateAdded,
            isAvailable: fileExists && validationAllowsReading
        )
    }
}

nonisolated private struct PreparedReadingRecommendations: Sendable {
    let candidates: [ReadingRecommendationCandidate]
    let sourceBookCount: Int
    let availableTags: [String]
    let availableLanguages: [String]
}

nonisolated private enum ReadingRecommendationPreparer {
    static func prepare(_ sources: [ReadingRecommendationCandidateSource]) -> PreparedReadingRecommendations {
        var candidates: [ReadingRecommendationCandidate] = []
        candidates.reserveCapacity(sources.count)

        for source in sources {
            if Task.isCancelled { break }
            candidates.append(source.candidate(
                fileExists: FileManager.default.fileExists(
                    atPath: source.fileURL.path(percentEncoded: false)
                )
            ))
        }

        return PreparedReadingRecommendations(
            candidates: candidates,
            sourceBookCount: candidates.count {
                $0.isAvailable
                    && ($0.readingStatus == .unread
                        || $0.readingStatus == .reading
                        || $0.readingStatus == .paused)
            },
            availableTags: uniqueSorted(candidates.flatMap(\.tags)),
            availableLanguages: uniqueSorted(candidates.compactMap(\.language))
        )
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        var displayValueByKey: [String: String] = [:]
        for value in values {
            guard let display = nonempty(value) else { continue }
            let key = normalized(display)
            if displayValueByKey[key] == nil {
                displayValueByKey[key] = display
            }
        }
        return displayValueByKey.values.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

@MainActor
@Observable
final class ReadingRecommendationViewModel {
    var preferences = ReadingRecommendationPreferences.default {
        didSet {
            guard preferences != oldValue else { return }
            scheduleRecompute()
        }
    }

    private(set) var currentRecommendation: ReadingRecommendation?
    private(set) var currentBook: Book?
    private(set) var recommendationCount = 0
    private(set) var currentOrdinal = 0
    private(set) var availableTags: [String] = []
    private(set) var availableLanguages: [String] = []
    private(set) var sourceBookCount = 0
    private(set) var isPreparing = false

    @ObservationIgnored private var candidates: [ReadingRecommendationCandidate] = []
    @ObservationIgnored private var rankedRecommendations: [ReadingRecommendation] = []
    @ObservationIgnored private var booksByID: [UUID: Book] = [:]
    @ObservationIgnored private var rotationAnchorID: UUID?
    @ObservationIgnored private var activePreparationID: UUID?
    @ObservationIgnored private var rankingTask: Task<Void, Never>?
    @ObservationIgnored private var selectedIndex = 0

    var hasCustomPreferences: Bool {
        preferences != .default
    }

    func prepare(books: [Book], after previousBookID: UUID?) async {
        let preparationID = UUID()
        activePreparationID = preparationID
        isPreparing = true
        rotationAnchorID = previousBookID

        var sourceBooksByID: [UUID: Book] = [:]
        sourceBooksByID.reserveCapacity(books.count)
        var sources: [ReadingRecommendationCandidateSource] = []
        sources.reserveCapacity(books.count)
        for (index, book) in books.enumerated() {
            guard !Task.isCancelled, activePreparationID == preparationID else { return }
            sourceBooksByID[book.uuid] = book
            sources.append(Self.candidateSource(from: book))
            if index > 0, index.isMultiple(of: 128) { await Task.yield() }
        }
        let preparationTask = Task.detached(priority: .userInitiated) {
            ReadingRecommendationPreparer.prepare(sources)
        }
        let prepared = await withTaskCancellationHandler {
            await preparationTask.value
        } onCancel: {
            preparationTask.cancel()
        }

        guard !Task.isCancelled, activePreparationID == preparationID else { return }
        isPreparing = false
        booksByID = sourceBooksByID
        candidates = prepared.candidates
        sourceBookCount = prepared.sourceBookCount
        availableTags = prepared.availableTags
        availableLanguages = prepared.availableLanguages

        var updated = preferences
        if let tag = updated.moodTag,
           !availableTags.contains(where: { Self.sameText($0, tag) }) {
            updated.moodTag = nil
        }
        if let language = updated.language,
           !availableLanguages.contains(where: { Self.sameText($0, language) }) {
            updated.language = nil
        }

        if updated != preferences {
            preferences = updated
        } else {
            scheduleRecompute(immediately: true)
        }
    }

    func chooseAnother() {
        guard rankedRecommendations.count > 1 else { return }
        selectedIndex = (selectedIndex + 1) % rankedRecommendations.count
        updateCurrentRecommendation()
    }

    func resetPreferences() {
        if preferences == .default {
            selectedIndex = 0
            scheduleRecompute(immediately: true)
        } else {
            preferences = .default
        }
    }

    private func scheduleRecompute(immediately: Bool = false) {
        rankingTask?.cancel()
        let candidates = candidates
        let preferences = preferences
        let anchor = rotationAnchorID
        rankingTask = Task { [weak self] in
            if !immediately {
                do {
                    try await Task.sleep(for: .milliseconds(35))
                } catch {
                    return
                }
            }
            let ranked = await Self.rank(
                candidates,
                preferences: preferences,
                after: anchor
            )
            guard !Task.isCancelled, let self,
                  self.preferences == preferences,
                  self.rotationAnchorID == anchor else { return }
            self.rankedRecommendations = ranked
            self.selectedIndex = 0
            self.updateCurrentRecommendation()
            self.rankingTask = nil
        }
    }

    @concurrent
    private static func rank(
        _ candidates: [ReadingRecommendationCandidate],
        preferences: ReadingRecommendationPreferences,
        after anchor: UUID?
    ) async -> [ReadingRecommendation] {
        let ranked = ReadingRecommendationService.rank(
            candidates,
            preferences: preferences
        )
        guard !Task.isCancelled else { return [] }
        return ReadingRecommendationService.rotatingStrongMatches(
            ranked,
            after: anchor
        )
    }

    private func updateCurrentRecommendation() {
        recommendationCount = rankedRecommendations.count
        guard rankedRecommendations.indices.contains(selectedIndex) else {
            currentRecommendation = nil
            currentBook = nil
            currentOrdinal = 0
            return
        }
        let recommendation = rankedRecommendations[selectedIndex]
        currentRecommendation = recommendation
        currentBook = booksByID[recommendation.bookID]
        rotationAnchorID = recommendation.bookID
        currentOrdinal = selectedIndex + 1
    }

    private static func candidateSource(from book: Book) -> ReadingRecommendationCandidateSource {
        let primaryAsset = book.assets.first { $0.fileName == book.fileName }
        let validationAllowsReading = primaryAsset?.validationStatus != .missing
            && primaryAsset?.validationStatus != .corrupt
        return ReadingRecommendationCandidateSource(
            id: book.uuid,
            title: book.displayTitle,
            author: book.displayAuthor,
            readingStatus: book.readingStatus,
            activeProgress: book.activeReadingSession?.progress,
            pageCount: book.pageCount,
            tags: book.tags,
            language: nonempty(book.language),
            series: nonempty(book.series),
            seriesIndex: book.seriesIndex.flatMap(Double.init),
            personalRating: book.rating,
            communityRating: book.communityRating,
            dateAdded: book.dateAdded,
            fileURL: book.primaryFileURL ?? book.coverCacheURL,
            validationAllowsReading: validationAllowsReading
        )
    }

    private static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

struct ReadingRecommendationSheet: View {
    let books: [Book]
    let onOpen: (UUID) -> Void
    let onShowInLibrary: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @AppStorage("readingRecommendation.lastBookID") private var lastRecommendationBookID = ""
    @State private var model = ReadingRecommendationViewModel()

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ReadingRecommendationHeader()
            Divider()
            HSplitView {
                ReadingRecommendationPreferencesPane(
                    preferences: $model.preferences,
                    tags: model.availableTags,
                    languages: model.availableLanguages
                )
                .frame(minWidth: 380, idealWidth: 400, maxWidth: 420)

                ReadingRecommendationResultPane(
                    book: model.currentBook,
                    recommendation: model.currentRecommendation,
                    recommendationCount: model.recommendationCount,
                    currentOrdinal: model.currentOrdinal,
                    hasSourceBooks: model.sourceBookCount > 0,
                    isPreparing: model.isPreparing,
                    onChooseAnother: model.chooseAnother,
                    onReset: model.resetPreferences,
                    onOpen: onOpen,
                    onShowInLibrary: onShowInLibrary
                )
                .frame(minWidth: 470, idealWidth: 560)
            }
            Divider()
            ReadingRecommendationFooter(
                canReset: model.hasCustomPreferences,
                onReset: model.resetPreferences,
                onDone: { dismiss() }
            )
        }
        .frame(minWidth: 900, idealWidth: 940, maxWidth: 1_160,
               minHeight: 600, idealHeight: 700, maxHeight: 900)
        .background(theme.background)
        .task(id: LibraryMutationLog.shared.catalogRevision) {
            if model.currentRecommendation != nil || model.sourceBookCount > 0 {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            var descriptor = FetchDescriptor<Book>()
            descriptor.relationshipKeyPathsForPrefetching = [\Book.assets, \Book.readingSessions]
            let candidateBooks = (try? modelContext.fetch(descriptor)) ?? books
            await model.prepare(
                books: candidateBooks,
                after: UUID(uuidString: lastRecommendationBookID)
            )
        }
        .onChange(of: model.currentRecommendation?.bookID) { _, bookID in
            if let bookID {
                lastRecommendationBookID = bookID.uuidString
            }
        }
    }
}

private struct ReadingRecommendationHeader: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 38, height: 38)
                .background(theme.accent.opacity(0.12), in: RoundedRectangle(
                    cornerRadius: WinstonLayout.cornerMedium,
                    style: .continuous
                ))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                theme.styledText(
                    terminal: "// read_today",
                    native: "What Should I Read Today?"
                )
                .font(theme.body(size: 19, weight: .bold))
                .foregroundStyle(theme.textPrimary)

                Text("Tune the moment, then let Winston explain its pick.")
                    .font(theme.label(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }
}

private struct ReadingRecommendationPreferencesPane: View {
    @Binding var preferences: ReadingRecommendationPreferences
    let tags: [String]
    let languages: [String]

    @Environment(\.theme) private var theme
    @FocusState private var modeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ReadingModePreference(
                    mode: $preferences.mode,
                    isFocused: $modeFocused
                )
                Divider()
                ReadingTimePreference(timeBudget: $preferences.timeBudget)
                Divider()
                ReadingMoodPreference(
                    moodTag: $preferences.moodTag,
                    language: $preferences.language,
                    tags: tags,
                    languages: languages
                )
                Divider()
                ReadingSeriesPreferenceSection(
                    seriesPreference: $preferences.seriesPreference
                )
                Divider()
                ReadingRankingSignalsPreference(
                    preferHighlyRated: $preferences.preferHighlyRated,
                    preferWaitingLongest: $preferences.preferWaitingLongest
                )
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.backgroundAlt.opacity(0.34))
        .task {
            await Task.yield()
            modeFocused = true
        }
    }
}

private struct ReadingModePreference: View {
    @Binding var mode: ReadingRecommendationMode
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PreferenceSectionTitle(
                title: "Reading goal",
                detail: "Continue something or start fresh."
            )
            Picker("Reading goal", selection: $mode) {
                ForEach(ReadingRecommendationMode.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .focused(isFocused)
            .accessibilityLabel("Reading goal")
        }
    }
}

private struct ReadingTimePreference: View {
    @Binding var timeBudget: ReadingTimeBudget

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PreferenceSectionTitle(
                title: "Time commitment",
                detail: "Use total length as a soft preference."
            )
            Picker("Time commitment", selection: $timeBudget) {
                ForEach(ReadingTimeBudget.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            Text(timeBudget.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ReadingMoodPreference: View {
    @Binding var moodTag: String?
    @Binding var language: String?
    let tags: [String]
    let languages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            PreferenceSectionTitle(
                title: "Mood and language",
                detail: "Tags act as your local mood or genre vocabulary."
            )
            Picker("Mood or genre", selection: $moodTag) {
                Text("Any mood").tag(nil as String?)
                ForEach(tags, id: \.self) { tag in
                    Text(verbatim: tag).tag(Optional(tag))
                }
            }
            Picker("Language", selection: $language) {
                Text("Any language").tag(nil as String?)
                ForEach(languages, id: \.self) { language in
                    Text(verbatim: language).tag(Optional(language))
                }
            }
        }
    }
}

private struct ReadingSeriesPreferenceSection: View {
    @Binding var seriesPreference: ReadingSeriesPreference

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PreferenceSectionTitle(
                title: "Series",
                detail: "Winston never jumps past an earlier unread numbered volume."
            )
            Picker("Series preference", selection: $seriesPreference) {
                ForEach(ReadingSeriesPreference.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel("Series preference")
        }
    }
}

private struct ReadingRankingSignalsPreference: View {
    @Binding var preferHighlyRated: Bool
    @Binding var preferWaitingLongest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PreferenceSectionTitle(
                title: "Tie-breakers",
                detail: "These influence ranking but never hide a match."
            )
            Toggle("Prefer highly rated books", isOn: $preferHighlyRated)
            Toggle("Prefer books waiting longest", isOn: $preferWaitingLongest)
        }
    }
}

private struct PreferenceSectionTitle: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(theme.body(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(detail)
                .font(theme.label(size: 10))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ReadingRecommendationResultPane: View {
    let book: Book?
    let recommendation: ReadingRecommendation?
    let recommendationCount: Int
    let currentOrdinal: Int
    let hasSourceBooks: Bool
    let isPreparing: Bool
    let onChooseAnother: () -> Void
    let onReset: () -> Void
    let onOpen: (UUID) -> Void
    let onShowInLibrary: (UUID) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        if isPreparing {
            ProgressView("Checking your library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.background)
        } else if let book, let recommendation {
            ScrollView {
                ReadingRecommendationResult(
                    book: book,
                    reasons: recommendation.reasons,
                    recommendationCount: recommendationCount,
                    currentOrdinal: currentOrdinal,
                    onChooseAnother: onChooseAnother,
                    onOpen: { onOpen(book.uuid) },
                    onShowInLibrary: { onShowInLibrary(book.uuid) }
                )
                .padding(28)
            }
            .background(theme.background)
        } else {
            ReadingRecommendationEmptyState(
                hasSourceBooks: hasSourceBooks,
                onReset: onReset
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
        }
    }
}

private struct ReadingRecommendationResult: View {
    let book: Book
    let reasons: [ReadingRecommendationReason]
    let recommendationCount: Int
    let currentOrdinal: Int
    let onChooseAnother: () -> Void
    let onOpen: () -> Void
    let onShowInLibrary: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 24) {
                BookCoverImageView(book: book)
                    .aspectRatio(WinstonLayout.coverAspect, contentMode: .fill)
                    .frame(width: 150, height: 225)
                    .clipped()
                    .clipShape(RoundedRectangle(
                        cornerRadius: WinstonLayout.cornerMedium,
                        style: .continuous
                    ))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .accessibilityHidden(true)

                ReadingRecommendationBookSummary(
                    title: book.displayTitle,
                    author: book.displayAuthor,
                    status: book.readingStatus,
                    pageCount: book.pageCount,
                    series: book.series,
                    seriesIndex: book.seriesIndex,
                    recommendationCount: recommendationCount,
                    currentOrdinal: currentOrdinal
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ReadingRecommendationReasons(reasons: reasons)

            ViewThatFits {
                HStack(spacing: 9) {
                    resultActions
                }
                VStack(alignment: .leading, spacing: 9) {
                    resultActions
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var resultActions: some View {
        Button(action: onOpen) {
            Label("Open in Reader", systemImage: "book")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)

        Button(action: onShowInLibrary) {
            Label("Show in Library", systemImage: "rectangle.grid.2x2")
        }

        Button(action: onChooseAnother) {
            Label("Try Another", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(recommendationCount < 2)
        .help(recommendationCount < 2 ? "No other books match these preferences" : "Show the next matching book")
    }
}

private struct ReadingRecommendationBookSummary: View {
    let title: String
    let author: String?
    let status: ReadingStatus
    let pageCount: Int?
    let series: String?
    let seriesIndex: String?
    let recommendationCount: Int
    let currentOrdinal: Int

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WINSTON’S PICK")
                .font(theme.label(size: 9, weight: .semibold))
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title)
                    .font(theme.display(size: 25, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let author {
                    Text(verbatim: author)
                        .font(theme.body(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
            }

            ReadingRecommendationMetadata(
                status: status,
                pageCount: pageCount,
                series: series,
                seriesIndex: seriesIndex
            )

            if recommendationCount > 1 {
                Text(
                    "Pick \(currentOrdinal) of \(recommendationCount)",
                    comment: "Recommendation position; first placeholder is the current pick, second is total matches."
                )
                .font(theme.label(size: 10))
                .foregroundStyle(theme.textTertiary)
            }
        }
    }
}

private struct ReadingRecommendationMetadata: View {
    let status: ReadingStatus
    let pageCount: Int?
    let series: String?
    let seriesIndex: String?

    var body: some View {
        HStack(spacing: 7) {
            RecommendationMetadataPill(
                text: status.label,
                systemImage: status.systemImage
            )
            if let pageCount {
                RecommendationMetadataPill(
                    text: String(localized: "\(pageCount) pages"),
                    systemImage: "doc.text"
                )
            }
            if let series {
                RecommendationMetadataPill(
                    text: seriesIndex.map { "\(series) #\($0)" } ?? series,
                    systemImage: "books.vertical"
                )
            }
        }
    }
}

private struct RecommendationMetadataPill: View {
    let text: String
    let systemImage: String

    @Environment(\.theme) private var theme

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(theme.label(size: 9, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(theme.backgroundAlt, in: Capsule())
            .overlay(Capsule().stroke(theme.borderSubtle, lineWidth: 1))
    }
}

private struct ReadingRecommendationReasons: View {
    let reasons: [ReadingRecommendationReason]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why this one")
                .font(theme.body(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(reasons) { reason in
                    ReadingRecommendationReasonRow(reason: reason)
                }
            }
        }
    }
}

private struct ReadingRecommendationReasonRow: View {
    let reason: ReadingRecommendationReason

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: reason.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(reason.text)
                .font(theme.body(size: 12))
                .foregroundStyle(theme.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ReadingRecommendationEmptyState: View {
    let hasSourceBooks: Bool
    let onReset: () -> Void

    var body: some View {
        ContentUnavailableView {
            if hasSourceBooks {
                Label("No Matching Books", systemImage: "line.3.horizontal.decrease.circle")
            } else {
                Label("Nothing to Recommend Yet", systemImage: "books.vertical")
            }
        } description: {
            if hasSourceBooks {
                Text("Try broadening the reading goal, mood, language, or series preference.")
            } else {
                Text("Add an unread book or keep a book in progress, then ask Winston again.")
            }
        } actions: {
            if hasSourceBooks {
                Button("Reset Preferences", action: onReset)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readingRecommendation.empty")
    }
}

private struct ReadingRecommendationFooter: View {
    let canReset: Bool
    let onReset: () -> Void
    let onDone: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Label("Uses only your local library metadata", systemImage: "lock")
                .font(theme.label(size: 10))
                .foregroundStyle(theme.textTertiary)
            Spacer()
            Button("Reset", action: onReset)
                .disabled(!canReset)
            Button("Done", action: onDone)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("readingRecommendation.done")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.backgroundAlt.opacity(0.98))
    }
}
