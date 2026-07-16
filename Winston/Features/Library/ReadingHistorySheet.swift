import SwiftUI

struct ReadingHistorySheet: View {
    let book: Book
    let viewModel: LibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var progress = 0.0

    private struct RowData: Identifiable {
        let session: ReadingSession
        let number: Int
        var id: UUID { session.uuid }
    }

    var body: some View {
        VStack(spacing: 0) {
            ReadingHistoryHeader(book: book)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    currentReadingSection
                    historySection
                }
                .padding(20)
            }
            Divider()
            HStack {
                if book.finishedReadingCount > 1 {
                    Label("\(book.finishedReadingCount) completed readings", systemImage: "arrow.clockwise")
                        .font(theme.label(size: 10))
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .background(ThemedBackground())
        .frame(minWidth: 520, idealWidth: 620, maxWidth: 820,
               minHeight: 560, idealHeight: 680, maxHeight: 900)
        .task(id: activeSessionID) {
            progress = book.activeReadingSession?.progress ?? 0
        }
    }

    private var activeSessionID: UUID? {
        book.activeReadingSession?.uuid
    }

    private var historyRows: [RowData] {
        let rows = book.readingSessionsChronological.enumerated().map {
            RowData(session: $0.element, number: $0.offset + 1)
        }
        return Array(rows.reversed())
    }

    @ViewBuilder
    private var currentReadingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Current Reading", systemImage: "book.pages")
                .font(theme.body(size: 13, weight: .bold))
                .foregroundStyle(theme.textPrimary)

            if let active = book.activeReadingSession {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        ReadingStatusBadge(status: active.status)
                        Spacer()
                        Text("Started \(active.startedAt, format: .dateTime.day().month().year())")
                            .font(theme.label(size: 10))
                            .foregroundStyle(theme.textTertiary)
                    }

                    HStack(spacing: 10) {
                        Slider(
                            value: $progress,
                            in: 0...1,
                            step: 0.01,
                            onEditingChanged: saveProgressWhenEditingEnds
                        )
                        .accessibilityLabel("Reading progress")
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(theme.label(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }

                    HStack {
                        Button(role: .destructive) {
                            changeStatus(to: .didNotFinish)
                        } label: {
                            Label("Mark DNF", systemImage: "xmark.circle")
                        }
                        Spacer()
                        if active.status == .paused {
                            Button {
                                changeStatus(to: .reading)
                            } label: {
                                Label("Resume", systemImage: "play.fill")
                            }
                        } else {
                            Button {
                                changeStatus(to: .paused)
                            } label: {
                                Label("Pause", systemImage: "pause.fill")
                            }
                        }
                        Button {
                            changeStatus(to: .finished)
                        } label: {
                            Label("Finish", systemImage: "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(14)
                .background(theme.surface.opacity(0.55), in: RoundedRectangle(
                    cornerRadius: WinstonLayout.cornerLarge,
                    style: .continuous
                ))
                .themedBorder(cornerRadius: WinstonLayout.cornerLarge)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(startPrompt)
                        .font(theme.label(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        viewModel.setReadingStatus(.reading, for: [book])
                    } label: {
                        Label(startButtonTitle, systemImage: "book.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(theme.surface.opacity(0.38), in: RoundedRectangle(
                    cornerRadius: WinstonLayout.cornerLarge,
                    style: .continuous
                ))
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Reading History", systemImage: "clock.arrow.circlepath")
                    .font(theme.body(size: 13, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(verbatim: historyCountLabel)
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textTertiary)
            }

            if historyRows.isEmpty {
                ContentUnavailableView {
                    Label("No Reading History", systemImage: "clock")
                } description: {
                    Text("Start reading to create the first cycle.")
                }
                .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(historyRows) { row in
                        ReadingCycleRow(session: row.session, number: row.number)
                        if row.id != historyRows.last?.id {
                            Divider().padding(.leading, 31)
                        }
                    }
                }
            }
        }
    }

    private var startButtonTitle: LocalizedStringKey {
        if book.finishedReadingCount > 0 { return "Read Again" }
        if book.readingSessions.isEmpty { return "Start Reading" }
        return "Start Another Reading"
    }

    private var startPrompt: LocalizedStringKey {
        if book.readingSessions.isEmpty {
            return "Track dates and progress without changing the book file."
        }
        return "A new cycle keeps every earlier date and progress entry."
    }

    private var historyCountLabel: String {
        let count = book.readingSessions.count
        return String(localized: "\(count) reading cycles")
    }

    private func saveProgressWhenEditingEnds(_ isEditing: Bool) {
        if !isEditing {
            viewModel.updateReadingProgress(progress, for: book)
        }
    }

    private func changeStatus(to status: ReadingStatus) {
        viewModel.updateReadingProgress(progress, for: book)
        viewModel.setReadingStatus(status, for: [book])
    }
}

private struct ReadingHistoryHeader: View {
    let book: Book

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            BookCoverImageView(book: book)
                .frame(width: 40, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Reading History")
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .textCase(.uppercase)
                Text(book.displayTitle)
                    .font(theme.body(size: 17, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                if let author = book.displayAuthor {
                    Text(author)
                        .font(theme.label(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct ReadingCycleRow: View {
    let session: ReadingSession
    let number: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))
                Image(systemName: session.status.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Reading \(number)")
                        .font(theme.label(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    ReadingStatusBadge(status: session.status)
                    Spacer()
                    Text(session.progress, format: .percent.precision(.fractionLength(0)))
                        .font(theme.label(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .monospacedDigit()
                }

                HStack(spacing: 5) {
                    Text(session.startedAt, format: .dateTime.day().month().year())
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7, weight: .semibold))
                    if let endedAt = session.endedAt {
                        Text(endedAt, format: .dateTime.day().month().year())
                    } else {
                        Text("Present")
                    }
                }
                .font(theme.label(size: 10))
                .foregroundStyle(theme.textTertiary)

                ProgressView(value: session.progress)
                    .tint(statusColor)
                    .controlSize(.small)
                    .accessibilityLabel("Reading progress")
            }
        }
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch session.status {
        case .reading: theme.accent
        case .paused: theme.highlight
        case .finished: theme.success
        case .didNotFinish: theme.destructive
        }
    }
}

private struct ReadingStatusBadge: View {
    let status: ReadingSessionStatus

    @Environment(\.theme) private var theme

    var body: some View {
        Label(status.label, systemImage: status.systemImage)
            .font(theme.label(size: 9, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(theme.surfaceGlass, in: Capsule())
    }
}
