import SwiftUI
import Charts

nonisolated struct LibraryStats: Sendable {
    struct MonthEntry: Identifiable, Sendable {
        let month: Int
        let label: String
        let started: Int
        let finished: Int
        var id: Int { month }
    }

    struct Input: Sendable {
        struct ReadingCycle: Sendable {
            let status: ReadingSessionStatus
            let startedAt: Date
            let endedAt: Date?
        }

        let title: String
        let author: String?
        let series: String?
        let format: String
        let rating: Int?
        let status: ReadingStatus
        let readingCycles: [ReadingCycle]
        let fileSizeBytes: Int64
        let workUUID: UUID
    }

    @MainActor
    static func snapshot(of books: [Book]) -> [Input] {
        books.map { book in
            let retainedBytes: Int64
            if book.assets.isEmpty {
                retainedBytes = book.fileSizeBytes
            } else {
                retainedBytes = book.assets
                    .filter { $0.validationStatus != .missing }
                    .reduce(0) { total, asset in
                        if asset.sizeBytes > 0 { return total + asset.sizeBytes }
                        return total + (asset.fileName == book.fileName ? book.fileSizeBytes : 0)
                    }
            }
            let readingCycles: [Input.ReadingCycle]
            if book.readingSessions.isEmpty {
                readingCycles = legacyCycle(for: book)
            } else {
                readingCycles = book.readingSessions.map {
                    Input.ReadingCycle(status: $0.status, startedAt: $0.startedAt, endedAt: $0.endedAt)
                }
            }
            return Input(
                title: book.displayTitle,
                author: book.displayAuthor,
                series: book.series,
                format: book.format,
                rating: book.rating,
                status: book.readingStatus,
                readingCycles: readingCycles,
                fileSizeBytes: retainedBytes,
                workUUID: book.work?.uuid ?? book.uuid
            )
        }
    }

    @MainActor
    private static func legacyCycle(for book: Book) -> [Input.ReadingCycle] {
        switch book.readingStatus {
        case .unread:
            return []
        case .reading:
            guard let startedAt = book.dateStarted else { return [] }
            return [Input.ReadingCycle(status: .reading, startedAt: startedAt, endedAt: nil)]
        case .paused:
            guard let startedAt = book.dateStarted else { return [] }
            return [Input.ReadingCycle(status: .paused, startedAt: startedAt, endedAt: nil)]
        case .finished:
            guard let endedAt = book.dateFinished else { return [] }
            return [Input.ReadingCycle(status: .finished, startedAt: book.dateStarted ?? endedAt, endedAt: endedAt)]
        case .didNotFinish:
            guard let startedAt = book.dateStarted else { return [] }
            return [Input.ReadingCycle(status: .didNotFinish, startedAt: startedAt, endedAt: nil)]
        }
    }

    var bookCount = 0
    var totalSizeDisplay = ""
    var finishedCount = 0
    var readingCount = 0
    var uniqueAuthors = 0
    var uniqueSeries = 0
    var uniqueWorks = 0
    var finishedThisYear = 0
    var monthly: [MonthEntry] = []
    var formatData: [(label: String, count: Int)] = []
    var ratingData: [(label: String, count: Int)] = []
    var averageDaysToFinish: Int?
    var largestFinished: (title: String, sizeDisplay: String)?

    @MainActor
    init(books: [Book], calendar: Calendar = .current, now: Date = .now) {
        self.init(inputs: Self.snapshot(of: books), calendar: calendar, now: now)
    }

    init(inputs: [Input], calendar: Calendar = .current, now: Date = .now) {
        let year = calendar.component(.year, from: now)

        var startedByMonth = [Int](repeating: 0, count: 12)
        var finishedByMonth = [Int](repeating: 0, count: 12)
        var formats: [String: Int] = [:]
        var ratings = [Int](repeating: 0, count: 6)
        var authors = Set<String>()
        var series = Set<String>()
        var works = Set<UUID>()
        var totalBytes: Int64 = 0
        var finishDurations: [Double] = []
        var largest: Input?

        for book in inputs {
            totalBytes += book.fileSizeBytes
            formats[book.format.isEmpty ? "\u{2014}" : book.format, default: 0] += 1
            if let rating = book.rating, (1...5).contains(rating) { ratings[rating] += 1 }
            if let author = book.author { authors.insert(author) }
            if let s = book.series, !s.isEmpty { series.insert(s) }
            works.insert(book.workUUID)

            switch book.status {
            case .finished: finishedCount += 1
            case .reading, .paused: readingCount += 1
            case .unread, .didNotFinish: break
            }

            var hasFinishedCycle = false
            for cycle in book.readingCycles {
                if calendar.component(.year, from: cycle.startedAt) == year {
                    startedByMonth[calendar.component(.month, from: cycle.startedAt) - 1] += 1
                }
                guard cycle.status == .finished, let finished = cycle.endedAt else { continue }
                hasFinishedCycle = true
                if calendar.component(.year, from: finished) == year {
                    finishedThisYear += 1
                    finishedByMonth[calendar.component(.month, from: finished) - 1] += 1
                }
                if finished >= cycle.startedAt {
                    finishDurations.append(finished.timeIntervalSince(cycle.startedAt) / 86_400)
                }
            }
            if hasFinishedCycle, book.fileSizeBytes > (largest?.fileSizeBytes ?? 0) {
                largest = book
            }
        }

        bookCount = inputs.count
        totalSizeDisplay = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        uniqueAuthors = authors.count
        uniqueSeries = series.count
        uniqueWorks = works.count

        let symbols = calendar.shortMonthSymbols
        monthly = (0..<12).map {
            MonthEntry(month: $0 + 1, label: symbols[$0],
                       started: startedByMonth[$0], finished: finishedByMonth[$0])
        }
        formatData = formats
            .map { (label: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
        ratingData = (1...5).reversed().compactMap { stars in
            ratings[stars] > 0 ? (label: String(repeating: "\u{2605}", count: stars), count: ratings[stars]) : nil
        }
        if !finishDurations.isEmpty {
            averageDaysToFinish = Int((finishDurations.reduce(0, +) / Double(finishDurations.count)).rounded())
        }
        if let largest {
            largestFinished = (largest.title,
                               ByteCountFormatter.string(fromByteCount: largest.fileSizeBytes, countStyle: .file))
        }
    }
}

struct StatisticsView: View {
    let books: [Book]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var stats: LibraryStats?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(theme.usesTerminalCopy ? "// year_in_books" : "Year in Books")
                    .font(theme.body(size: 15, weight: .bold))
                Spacer()
            }
            .padding(16)
            Divider()

            if let stats {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        GoalRingSection(finishedThisYear: stats.finishedThisYear)
                        StatsSummaryGrid(stats: stats)
                        if stats.finishedThisYear > 0 || stats.monthly.contains(where: { $0.started > 0 }) {
                            MonthlyChart(monthly: stats.monthly)
                        }
                        if !stats.formatData.isEmpty {
                            DistributionChart(title: String(localized: "By format"), data: stats.formatData)
                        }
                        if !stats.ratingData.isEmpty {
                            DistributionChart(title: String(localized: "By rating"), data: stats.ratingData)
                        }
                    }
                    .padding(18)
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
                .padding(12)
        }
        .frame(minWidth: 480, idealWidth: 620, maxWidth: 1000,
               minHeight: 640, idealHeight: 780, maxHeight: .infinity)
        .task {
            let inputs = LibraryStats.snapshot(of: books)
            stats = await Self.compute(inputs)
        }
    }

    // Off-main — works on a Sendable snapshot; @Model rows must not be read here.
    @concurrent
    private static func compute(_ inputs: [LibraryStats.Input]) async -> LibraryStats {
        LibraryStats(inputs: inputs)
    }
}

// MARK: - Reading goal

private struct GoalRingSection: View {
    let finishedThisYear: Int

    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var settings = settings
        let goal = max(settings.readingGoal, 1)
        let progress = min(1, Double(finishedThisYear) / Double(goal))

        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(theme.surface, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: progress)
                VStack(spacing: 0) {
                    Text(verbatim: "\(finishedThisYear)")
                        .font(theme.display(size: 20, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Text(verbatim: "/ \(settings.readingGoal)")
                        .font(theme.label(size: 9, weight: .regular))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 6) {
                Text("Reading goal")
                    .font(theme.label(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Text("Finished this year")
                    .font(theme.label(size: 10, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
                Stepper("Goal: \(settings.readingGoal)", value: $settings.readingGoal, in: 1...500)
                    .font(theme.label(size: 10))
                    .fixedSize()
            }
            Spacer()
        }
    }
}

// MARK: - Charts

private struct MonthlyChart: View {
    let monthly: [LibraryStats.MonthEntry]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Started vs finished")
                .font(theme.label(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Chart(monthly) { entry in
                BarMark(
                    x: .value("Month", entry.label),
                    y: .value("Count", entry.started)
                )
                .foregroundStyle(by: .value("Kind", String(localized: "Started")))
                .position(by: .value("Kind", String(localized: "Started")))
                .cornerRadius(3)

                BarMark(
                    x: .value("Month", entry.label),
                    y: .value("Count", entry.finished)
                )
                .foregroundStyle(by: .value("Kind", String(localized: "Finished")))
                .position(by: .value("Kind", String(localized: "Finished")))
                .cornerRadius(3)
            }
            .chartForegroundStyleScale([
                String(localized: "Started"): theme.accentSecondary.opacity(0.75),
                String(localized: "Finished"): theme.accent,
            ])
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .frame(height: 150)
        }
    }
}

private struct DistributionChart: View {
    let title: String
    let data: [(label: String, count: Int)]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(theme.label(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Chart(data, id: \.label) { item in
                BarMark(
                    x: .value("Count", item.count),
                    y: .value("Name", item.label)
                )
                .foregroundStyle(theme.accent.opacity(0.85))
                .cornerRadius(3)
                .annotation(position: .trailing) {
                    Text(verbatim: "\(item.count)")
                        .font(theme.label(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(data.count) * 28 + 12)
        }
    }
}

// MARK: - Summary

private struct StatsSummaryGrid: View {
    let stats: LibraryStats

    @Environment(\.theme) private var theme

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatTile(label: String(localized: "Books"), value: "\(stats.bookCount)")
            StatTile(label: String(localized: "Works"), value: stats.uniqueWorks.formatted())
            StatTile(label: String(localized: "Total size"), value: stats.totalSizeDisplay)
            StatTile(label: String(localized: "Finished"), value: "\(stats.finishedCount)")
            StatTile(label: String(localized: "Reading"), value: "\(stats.readingCount)")
            StatTile(label: String(localized: "Authors"), value: "\(stats.uniqueAuthors)")
            StatTile(label: String(localized: "Series"), value: "\(stats.uniqueSeries)")
            if let days = stats.averageDaysToFinish {
                StatTile(label: String(localized: "Avg. days to finish"), value: "\(days)")
            }
            if let largest = stats.largestFinished {
                StatTile(label: String(localized: "Largest: \(largest.title)"), value: largest.sizeDisplay)
            }
        }
    }
}

private struct StatTile: View {
    let label: String
    let value: String

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(theme.display(size: 22, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text(verbatim: label)
                .font(theme.label(size: 10))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: WinstonLayout.cornerMedium, style: .continuous).fill(theme.surface.opacity(0.5)))
        .themedBorder(cornerRadius: WinstonLayout.cornerMedium)
    }
}
