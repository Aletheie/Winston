import Observation
import SwiftData
import SwiftUI

nonisolated enum ReadingHistoryImportFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case ready
    case review
    case unmatched

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .ready: "Ready"
        case .review: "Review"
        case .unmatched: "Unmatched"
        }
    }
}

@MainActor
@Observable
final class ReadingHistoryImportViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case importing
        case completed(ReadingHistoryImportResult)
        case failed(String)
    }

    var filter: ReadingHistoryImportFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            recomputeVisibleRows()
        }
    }
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            recomputeVisibleRows()
        }
    }
    var selectedRowID: String?

    private(set) var document: ReadingHistoryImportDocument?
    private(set) var rows: [ReadingHistoryImportPreviewRow] = []
    private(set) var visibleRows: [ReadingHistoryImportPreviewRow] = []
    private(set) var phase: Phase = .idle

    @ObservationIgnored private var booksByID: [UUID: Book] = [:]

    var selectedRow: ReadingHistoryImportPreviewRow? {
        guard let selectedRowID else { return nil }
        return rows.first { $0.id == selectedRowID }
    }

    var selectedCount: Int { rows.count { $0.isIncluded } }
    var readyCount: Int {
        rows.count {
            $0.matchedBookID != nil && $0.impact?.hasChanges == true && !$0.matchKind.needsReview
        }
    }
    var reviewCount: Int { rows.count { $0.matchKind == .titleOnly || $0.matchKind == .ambiguous } }
    var unmatchedCount: Int { rows.count { $0.matchKind == .unmatched } }
    var canImport: Bool { selectedCount > 0 && phase != .importing }

    subscript(included rowID: String) -> Bool {
        get { rows.first { $0.id == rowID }?.isIncluded ?? false }
        set {
            guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
            if newValue {
                guard rows[index].matchedBookID != nil, rows[index].impact?.hasChanges == true else { return }
            }
            rows[index].isIncluded = newValue
            recomputeVisibleRows()
        }
    }

    subscript(matchFor rowID: String) -> UUID? {
        get { rows.first { $0.id == rowID }?.matchedBookID }
        set {
            guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
            rows[index].matchedBookID = newValue
            if let newValue, let book = booksByID[newValue] {
                rows[index].matchKind = .manual
                rows[index].impact = ReadingHistoryImportImpactBuilder.impact(
                    record: rows[index].record,
                    book: book
                )
                rows[index].isIncluded = rows[index].impact?.hasChanges == true
            } else {
                rows[index].matchKind = rows[index].candidates.isEmpty ? .unmatched : .ambiguous
                rows[index].impact = nil
                rows[index].isIncluded = false
            }
            recomputeVisibleRows()
        }
    }

    func load(fileURL: URL, books: [Book]) async {
        phase = .loading
        document = nil
        rows = []
        visibleRows = []
        selectedRowID = nil
        booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.uuid, $0) })

        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try ReadingHistoryExportParser.parse(url: fileURL)
            }.value
            guard !Task.isCancelled else { return }
            document = loaded
            rows = ReadingHistoryImportMatcher.match(records: loaded.records, books: books)
            recomputeVisibleRows()
            phase = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func selectSafeMatches() {
        for index in rows.indices {
            rows[index].isIncluded = rows[index].matchedBookID != nil
                && rows[index].impact?.hasChanges == true
                && !rows[index].matchKind.needsReview
        }
        recomputeVisibleRows()
    }

    func deselectAll() {
        for index in rows.indices { rows[index].isIncluded = false }
        recomputeVisibleRows()
    }

    func importSelected(modelContext: ModelContext) async {
        guard canImport else { return }
        phase = .importing
        await Task.yield()
        do {
            let result = try ReadingHistoryImporter(modelContext: modelContext).apply(rows)
            phase = .completed(result)
            for index in rows.indices {
                guard let bookID = rows[index].matchedBookID, let book = booksByID[bookID] else { continue }
                rows[index].impact = ReadingHistoryImportImpactBuilder.impact(
                    record: rows[index].record,
                    book: book
                )
                rows[index].isIncluded = false
            }
            recomputeVisibleRows()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func recomputeVisibleRows() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleRows = rows.filter { row in
            let matchesFilter = switch filter {
            case .all:
                true
            case .ready:
                row.matchedBookID != nil && row.impact?.hasChanges == true && !row.matchKind.needsReview
            case .review:
                row.matchKind == .titleOnly || row.matchKind == .ambiguous
            case .unmatched:
                row.matchKind == .unmatched
            }
            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }
            return row.record.title.localizedCaseInsensitiveContains(query)
                || row.record.author?.localizedCaseInsensitiveContains(query) == true
                || row.record.isbn?.localizedCaseInsensitiveContains(query) == true
        }

        if let selectedRowID, visibleRows.contains(where: { $0.id == selectedRowID }) { return }
        selectedRowID = visibleRows.first?.id
    }
}

struct ReadingHistoryImportSheet: View {
    let fileURL: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
    @State private var model = ReadingHistoryImportViewModel()

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ReadingHistoryImportHeader(
                document: model.document,
                readyCount: model.readyCount,
                reviewCount: model.reviewCount,
                unmatchedCount: model.unmatchedCount,
                phase: model.phase
            )
            Divider()
            HSplitView {
                ReadingHistoryImportListPane(
                    rows: model.visibleRows,
                    filter: $model.filter,
                    searchText: $model.searchText,
                    selection: $model.selectedRowID,
                    included: { rowID in $model[included: rowID] },
                    phase: model.phase,
                    onRetry: { Task { await model.load(fileURL: fileURL, books: books) } }
                )
                .frame(minWidth: 340, idealWidth: 390, maxWidth: 460)

                if let row = model.selectedRow {
                    ReadingHistoryImportDetailPane(
                        row: row,
                        matchedBookID: $model[matchFor: row.id]
                    )
                    .frame(minWidth: 480, idealWidth: 570, maxWidth: .infinity)
                } else {
                    ReadingHistoryImportNoSelection(phase: model.phase)
                        .frame(minWidth: 480, idealWidth: 570, maxWidth: .infinity)
                }
            }
            Divider()
            ReadingHistoryImportFooter(
                phase: model.phase,
                selectedCount: model.selectedCount,
                canImport: model.canImport,
                onSelectSafe: model.selectSafeMatches,
                onDeselectAll: model.deselectAll,
                onImport: {
                    Task { await model.importSelected(modelContext: modelContext) }
                },
                onDone: { dismiss() }
            )
        }
        .frame(minWidth: 920, idealWidth: 1040, maxWidth: 1260, minHeight: 620, idealHeight: 700)
        .background { ThemedBackground() }
        .task(id: fileURL) {
            await model.load(fileURL: fileURL, books: books)
        }
        .accessibilityIdentifier("readingHistoryImport.sheet")
    }
}

private struct ReadingHistoryImportHeader: View {
    let document: ReadingHistoryImportDocument?
    let readyCount: Int
    let reviewCount: Int
    let unmatchedCount: Int
    let phase: ReadingHistoryImportViewModel.Phase

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "clock.arrow.trianglehead.2.counterclockwise.rotate.90")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Import Reading History")
                    .font(.title2.weight(.semibold))
                if let document {
                    Text("\(document.source.title) · \(document.fileName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Goodreads, StoryGraph, or Hardcover CSV")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if phase == .loading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Reading export")
            } else if document != nil {
                HStack(spacing: 12) {
                    ReadingHistoryImportSummaryCount(value: readyCount, label: "ready", color: .green)
                    ReadingHistoryImportSummaryCount(value: reviewCount, label: "review", color: .orange)
                    ReadingHistoryImportSummaryCount(value: unmatchedCount, label: "unmatched", color: .secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

private struct ReadingHistoryImportSummaryCount: View {
    let value: Int
    let label: LocalizedStringResource
    let color: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value, format: .number)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ReadingHistoryImportListPane: View {
    let rows: [ReadingHistoryImportPreviewRow]
    @Binding var filter: ReadingHistoryImportFilter
    @Binding var searchText: String
    @Binding var selection: String?
    let included: (String) -> Binding<Bool>
    let phase: ReadingHistoryImportViewModel.Phase
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Picker("Import filter", selection: $filter) {
                    ForEach(ReadingHistoryImportFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                TextField("Search exported books", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("readingHistoryImport.search")
            }
            .padding(12)

            Divider()

            if case .failed(let message) = phase, rows.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t Read Export", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again", action: onRetry)
                }
            } else if phase == .loading || phase == .idle {
                ReadingHistoryImportLoadingRows()
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No Matching Rows",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Try another filter or clear the search field.")
                )
            } else {
                List(rows, selection: $selection) { row in
                    ReadingHistoryImportRow(
                        row: row,
                        isIncluded: included(row.id)
                    )
                    .tag(row.id)
                }
                .listStyle(.inset)
                .accessibilityIdentifier("readingHistoryImport.rows")
            }
        }
    }
}

private struct ReadingHistoryImportLoadingRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.secondary.opacity(0.15))
                        .frame(width: 190, height: 12)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.secondary.opacity(0.1))
                        .frame(width: 125, height: 9)
                }
            }
            Spacer()
        }
        .padding(18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading export")
    }
}

private struct ReadingHistoryImportRow: View {
    let row: ReadingHistoryImportPreviewRow
    @Binding var isIncluded: Bool

    private var canInclude: Bool {
        row.matchedBookID != nil && row.impact?.hasChanges == true
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $isIncluded)
                .labelsHidden()
                .disabled(!canInclude)
                .accessibilityLabel("Include \(row.record.title)")
                .accessibilityIdentifier("readingHistoryImport.include.\(row.id)")
            VStack(alignment: .leading, spacing: 5) {
                Text(row.record.title)
                    .font(.headline)
                    .lineLimit(2)
                if let author = row.record.author {
                    Text(author)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 7) {
                    ReadingHistoryImportMatchBadge(kind: row.matchKind, hasChanges: row.impact?.hasChanges)
                    if let status = row.record.status {
                        Label(status.label, systemImage: status.systemImage)
                            .labelStyle(.titleOnly)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let rating = row.record.rating {
                        Label {
                            Text(rating, format: .number.precision(.fractionLength(0...2)))
                        } icon: {
                            Image(systemName: "star.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct ReadingHistoryImportMatchBadge: View {
    let kind: ReadingHistoryImportMatchKind
    let hasChanges: Bool?

    private var color: Color {
        if hasChanges == false { return .secondary }
        switch kind {
        case .isbn, .titleAndAuthor, .manual: return .green
        case .titleOnly, .ambiguous: return .orange
        case .unmatched: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: hasChanges == false ? "checkmark.circle" : icon)
            if hasChanges == false {
                Text("Already imported")
            } else {
                Text(kind.title)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch kind {
        case .isbn, .titleAndAuthor, .manual: "checkmark.circle.fill"
        case .titleOnly, .ambiguous: "exclamationmark.circle.fill"
        case .unmatched: "questionmark.circle"
        }
    }
}

private struct ReadingHistoryImportDetailPane: View {
    let row: ReadingHistoryImportPreviewRow
    @Binding var matchedBookID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ReadingHistoryImportBookHeader(record: row.record)
                Divider()
                ReadingHistoryImportMatchSection(
                    row: row,
                    matchedBookID: $matchedBookID
                )
                Divider()
                ReadingHistoryImportChangesSection(row: row)
                Divider()
                ReadingHistoryImportSourceDataSection(record: row.record)
                if !row.record.cycles.isEmpty || (row.record.readCount ?? 0) > 0 {
                    Divider()
                    ReadingHistoryImportCyclesSection(record: row.record)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .accessibilityIdentifier("readingHistoryImport.detail")
    }
}

private struct ReadingHistoryImportBookHeader: View {
    let record: ReadingHistoryImportRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            if let author = record.author {
                Text(author)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Export row \(record.rowNumber)", comment: "Detail label; the number is the source CSV row.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ReadingHistoryImportMatchSection: View {
    let row: ReadingHistoryImportPreviewRow
    @Binding var matchedBookID: UUID?

    private var matchedOption: ReadingHistoryBookOption? {
        guard let matchedBookID else { return nil }
        return row.candidates.first { $0.id == matchedBookID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Library Match", systemImage: "books.vertical")
                .font(.headline)

            if row.candidates.count > 1 {
                Picker("Matched library book", selection: $matchedBookID) {
                    Text("Skip — no match").tag(UUID?.none)
                    ForEach(row.candidates) { candidate in
                        Text(candidate.author.map { "\(candidate.title) — \($0)" } ?? candidate.title)
                            .tag(UUID?.some(candidate.id))
                    }
                }
                .accessibilityIdentifier("readingHistoryImport.matchPicker")
                Text("Several library books matched this export row. Choose the correct edition before importing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let matchedOption {
                VStack(alignment: .leading, spacing: 4) {
                    Text(matchedOption.title)
                        .font(.body.weight(.medium))
                    if let author = matchedOption.author {
                        Text(author)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text(row.matchKind.title)
                        .font(.caption)
                        .foregroundStyle(row.matchKind == .titleOnly ? .orange : .secondary)
                }
                if row.matchKind == .titleOnly {
                    Label(
                        "Only the title matched. Review the book, then select its checkbox if it is correct.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } else {
                Label(
                    "No book in this library matched. This row will be skipped; import the book file first.",
                    systemImage: "questionmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ReadingHistoryImportChangesSection: View {
    let row: ReadingHistoryImportPreviewRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Changes to Import", systemImage: "arrow.down.doc")
                .font(.headline)
            if let impact = row.impact {
                if impact.hasChanges {
                    if impact.newCycleCount > 0 {
                        Label(
                            "\(impact.newCycleCount) new reading cycles",
                            systemImage: "clock.badge.plus"
                        )
                    }
                    if impact.changesStatus {
                        Label("Update reading status", systemImage: "bookmark")
                    }
                    if impact.changesRating {
                        Label("Update personal rating", systemImage: "star")
                    }
                } else {
                    Label("This history is already in Winston.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                Text("Choose a library match to preview its changes.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

private struct ReadingHistoryImportSourceDataSection: View {
    let record: ReadingHistoryImportRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Exported Data", systemImage: "tablecells")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Status").foregroundStyle(.secondary)
                    if let status = record.status { Text(status.label) } else { Text("Not provided") }
                }
                GridRow {
                    Text("Rating").foregroundStyle(.secondary)
                    if let rating = record.rating {
                        HStack(spacing: 5) {
                            Text(rating, format: .number.precision(.fractionLength(0...2)))
                            if record.winstonRating.map(Double.init) != rating, let rounded = record.winstonRating {
                                Text("→ \(rounded) in Winston", comment: "Rating conversion; the number is Winston’s whole-star value.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Not provided")
                    }
                }
                GridRow {
                    Text("Started").foregroundStyle(.secondary)
                    ReadingHistoryImportDateValue(date: record.startedAt)
                }
                GridRow {
                    Text("Finished").foregroundStyle(.secondary)
                    ReadingHistoryImportDateValue(date: record.finishedAt)
                }
                GridRow {
                    Text("ISBN").foregroundStyle(.secondary)
                    if let isbn = record.isbn { Text(isbn).textSelection(.enabled) } else { Text("Not provided") }
                }
                GridRow {
                    Text("Read count").foregroundStyle(.secondary)
                    if let count = record.readCount { Text(count, format: .number) } else { Text("Not provided") }
                }
            }
            .font(.callout)
        }
    }
}

private struct ReadingHistoryImportDateValue: View {
    let date: Date?

    var body: some View {
        if let date {
            Text(date, format: .dateTime.day().month().year())
        } else {
            Text("Not provided")
        }
    }
}

private struct ReadingHistoryImportCyclesSection: View {
    let record: ReadingHistoryImportRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Reading Cycles", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            if record.cycles.isEmpty {
                Text("The export contains a status but no dated reading cycle.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(record.cycles) { cycle in
                        ReadingHistoryImportCycleRow(cycle: cycle)
                    }
                }
            }
            if let readCount = record.readCount, readCount > record.cycles.count {
                Label(
                    "The export reports \(readCount) reads, but only \(record.cycles.count) dated cycles can be restored.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ReadingHistoryImportCycleRow: View {
    let cycle: ReadingHistoryImportCycle

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: cycle.status.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(cycle.status.label)
                .font(.callout.weight(.medium))
            Spacer()
            if let startedAt = cycle.startedAt, let endedAt = cycle.endedAt {
                Text("\(startedAt, format: .dateTime.day().month().year()) – \(endedAt, format: .dateTime.day().month().year())")
            } else if let date = cycle.endedAt ?? cycle.startedAt {
                Text(date, format: .dateTime.day().month().year())
            }
        }
        .font(.callout)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct ReadingHistoryImportNoSelection: View {
    let phase: ReadingHistoryImportViewModel.Phase

    var body: some View {
        if phase == .loading || phase == .idle {
            ContentUnavailableView("Reading Export", systemImage: "doc.text.magnifyingglass")
        } else {
            ContentUnavailableView(
                "Select an Exported Book",
                systemImage: "book.closed",
                description: Text("Review its library match and the exact history changes before importing.")
            )
        }
    }
}

private struct ReadingHistoryImportFooter: View {
    let phase: ReadingHistoryImportViewModel.Phase
    let selectedCount: Int
    let canImport: Bool
    let onSelectSafe: () -> Void
    let onDeselectAll: () -> Void
    let onImport: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ReadingHistoryImportFooterMessage(phase: phase)
            Spacer()
            Menu("Selection") {
                Button("Select Safe Matches", action: onSelectSafe)
                Button("Deselect All", action: onDeselectAll)
            }
            .disabled(phase == .loading || phase == .importing)

            Button("Done", action: onDone)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("readingHistoryImport.done")

            if case .completed = phase {
                EmptyView()
            } else {
                Button(action: onImport) {
                    if phase == .importing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Importing…")
                        }
                    } else {
                        Text("Import \(selectedCount) Books", comment: "Import button; the number is selected matched books.")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
                .accessibilityIdentifier("readingHistoryImport.import")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct ReadingHistoryImportFooterMessage: View {
    let phase: ReadingHistoryImportViewModel.Phase

    var body: some View {
        switch phase {
        case .completed(let result):
            Label {
                HStack(spacing: 5) {
                    Text("Import complete")
                    Text("·")
                    Text("\(result.bookCount) books")
                    Text("·")
                    Text("\(result.cycleCount) reading cycles")
                    Text("·")
                    Text("\(result.ratingCount) ratings")
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        default:
            Label(
                "Processed only on this Mac. Existing reading cycles are never deleted.",
                systemImage: "lock.shield"
            )
            .foregroundStyle(.secondary)
        }
    }
}
