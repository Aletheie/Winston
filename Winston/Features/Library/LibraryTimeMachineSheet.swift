import Observation
import SwiftData
import SwiftUI

nonisolated enum LibraryTimeMachineBookFilter: String, CaseIterable, Identifiable, Sendable {
    case changed
    case restorable
    case all

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .changed: "Changed"
        case .restorable: "Restorable"
        case .all: "All Books"
        }
    }
}

nonisolated struct LibraryTimeMachineBackupInfo: Equatable, Sendable, Identifiable {
    let id: URL
    let date: Date?

    var fileName: String { id.lastPathComponent }
}

struct LibraryTimeMachinePendingRestore: Identifiable {
    let scope: LibraryTimeMachineRestoreScope
    let snapshot: LibraryTimeMachineBookSnapshot
    let sourceBackup: URL

    var id: String { "\(snapshot.id.uuidString)-\(scope.rawValue)" }
}

struct LibraryTimeMachineRestoreNotice: Equatable {
    let result: LibraryTimeMachineRestoreResult
    let bookTitle: String
}

@MainActor
@Observable
final class LibraryTimeMachineViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var selectedBackupID: URL?
    var selectedBookID: UUID?
    var filter: LibraryTimeMachineBookFilter = .changed {
        didSet {
            guard filter != oldValue else { return }
            recomputeVisibleDiffs()
        }
    }
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            recomputeVisibleDiffs()
        }
    }
    var isConfirmingRestore = false

    private(set) var backups: [LibraryTimeMachineBackupInfo] = []
    private(set) var visibleDiffs: [LibraryTimeMachineBookDiff] = []
    private(set) var phase: Phase = .idle
    private(set) var pendingRestore: LibraryTimeMachinePendingRestore?
    private(set) var isRestoring = false
    private(set) var restoreNotice: LibraryTimeMachineRestoreNotice?
    private(set) var restoreError: String?
    private(set) var changedCount = 0
    private(set) var restorableCount = 0

    @ObservationIgnored private var loadedSnapshot: LibraryTimeMachineSnapshot?
    @ObservationIgnored private var allDiffs: [LibraryTimeMachineBookDiff] = []

    var selectedDiff: LibraryTimeMachineBookDiff? {
        guard let selectedBookID else { return nil }
        return allDiffs.first { $0.id == selectedBookID }
    }

    func reloadBackups(in folder: URL) {
        let previousSelection = selectedBackupID
        backups = LibraryBackup.availableBackups(in: folder).map {
            LibraryTimeMachineBackupInfo(id: $0, date: LibraryBackup.date(of: $0))
        }
        if let previousSelection, backups.contains(where: { $0.id == previousSelection }) {
            selectedBackupID = previousSelection
        } else {
            selectedBackupID = backups.first?.id
        }
        if backups.isEmpty {
            loadedSnapshot = nil
            allDiffs = []
            visibleDiffs = []
            selectedBookID = nil
            changedCount = 0
            restorableCount = 0
            phase = .idle
        }
    }

    func loadSelectedBackup(currentBooks: [Book]) async {
        guard let backupURL = selectedBackupID else { return }
        phase = .loading
        restoreError = nil
        restoreNotice = nil
        await Task.yield()

        do {
            let snapshot = try LibraryTimeMachineReader.load(backupURL)
            guard selectedBackupID == backupURL, !Task.isCancelled else { return }
            loadedSnapshot = snapshot
            rebuildDiff(currentBooks: currentBooks)
            phase = .loaded
        } catch {
            guard selectedBackupID == backupURL, !Task.isCancelled else { return }
            loadedSnapshot = nil
            allDiffs = []
            visibleDiffs = []
            selectedBookID = nil
            changedCount = 0
            restorableCount = 0
            phase = .failed(error.localizedDescription)
        }
    }

    func rebuildDiff(currentBooks: [Book]) {
        guard let loadedSnapshot else { return }
        allDiffs = LibraryTimeMachineDiffBuilder.compare(
            backup: loadedSnapshot,
            currentBooks: currentBooks
        )
        changedCount = allDiffs.count { $0.kind != .unchanged }
        restorableCount = allDiffs.count(where: \.canRestore)
        recomputeVisibleDiffs()
    }

    func requestRestore(
        scope: LibraryTimeMachineRestoreScope,
        diff: LibraryTimeMachineBookDiff
    ) {
        guard let snapshot = diff.backup, let sourceBackup = selectedBackupID else { return }
        pendingRestore = LibraryTimeMachinePendingRestore(
            scope: scope,
            snapshot: snapshot,
            sourceBackup: sourceBackup
        )
        isConfirmingRestore = true
    }

    func cancelRestore() {
        isConfirmingRestore = false
        pendingRestore = nil
    }

    func restorePending(
        modelContext: ModelContext,
        backupFolder: URL,
        onBackupsChanged: () -> Void
    ) async {
        guard let pendingRestore, !isRestoring else { return }
        isConfirmingRestore = false
        self.pendingRestore = nil
        isRestoring = true
        restoreError = nil
        restoreNotice = nil
        defer { isRestoring = false }

        do {
            let result = try await LibraryTimeMachineRestorer(modelContext: modelContext).restore(
                pendingRestore.snapshot,
                scope: pendingRestore.scope,
                from: pendingRestore.sourceBackup
            )
            restoreNotice = LibraryTimeMachineRestoreNotice(
                result: result,
                bookTitle: pendingRestore.snapshot.displayTitle
            )
            rebuildDiff(currentBooks: modelContext.allBooks())
            reloadBackups(in: backupFolder)
            onBackupsChanged()
        } catch {
            restoreError = error.localizedDescription
        }
    }

    func clearRestoreMessage() {
        restoreNotice = nil
        restoreError = nil
    }

    private func recomputeVisibleDiffs() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleDiffs = allDiffs.filter { diff in
            let matchesFilter = switch filter {
            case .changed: diff.kind != .unchanged
            case .restorable: diff.canRestore
            case .all: true
            }
            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }
            return diff.displayTitle.localizedCaseInsensitiveContains(query)
                || diff.displayAuthor?.localizedCaseInsensitiveContains(query) == true
        }

        if let selectedBookID, visibleDiffs.contains(where: { $0.id == selectedBookID }) {
            return
        }
        selectedBookID = visibleDiffs.first?.id
    }
}

struct LibraryTimeMachineSheet: View {
    let backupFolder: URL
    let onBackupsChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
    @State private var model = LibraryTimeMachineViewModel()

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            LibraryTimeMachineHeader(
                backupCount: model.backups.count,
                changedCount: model.changedCount,
                isLoading: model.phase == .loading
            )
            Divider()
            HSplitView {
                LibraryTimeMachineBackupPane(
                    backups: model.backups,
                    selection: $model.selectedBackupID
                )
                .frame(minWidth: 205, idealWidth: 225, maxWidth: 270)

                LibraryTimeMachineBookPane(
                    diffs: model.visibleDiffs,
                    phase: model.phase,
                    filter: $model.filter,
                    searchText: $model.searchText,
                    selection: $model.selectedBookID,
                    resultCount: model.visibleDiffs.count,
                    onRetry: {
                        Task { await model.loadSelectedBackup(currentBooks: books) }
                    }
                )
                .frame(minWidth: 285, idealWidth: 320, maxWidth: 390)

                LibraryTimeMachineDetailPane(
                    diff: model.selectedDiff,
                    phase: model.phase,
                    isRestoring: model.isRestoring,
                    onRestore: { scope, diff in
                        model.requestRestore(scope: scope, diff: diff)
                    }
                )
                .frame(minWidth: 440, idealWidth: 520, maxWidth: .infinity)
            }
            Divider()
            LibraryTimeMachineFooter(
                notice: model.restoreNotice,
                error: model.restoreError,
                isRestoring: model.isRestoring,
                onClearMessage: model.clearRestoreMessage,
                onDone: { dismiss() }
            )
        }
        .frame(minWidth: 980, idealWidth: 1080, maxWidth: 1320, minHeight: 620, idealHeight: 720)
        .background { ThemedBackground() }
        .task {
            model.reloadBackups(in: backupFolder)
        }
        .task(id: model.selectedBackupID) {
            await model.loadSelectedBackup(currentBooks: books)
        }
        .onChange(of: LibraryMutationLog.shared.revision) {
            model.rebuildDiff(currentBooks: books)
        }
        .confirmationDialog(
            model.pendingRestore?.scope.confirmationTitle ?? "Restore from Backup?",
            isPresented: $model.isConfirmingRestore,
            presenting: model.pendingRestore
        ) { pending in
            Button(pending.scope.title, role: .destructive) {
                Task {
                    await model.restorePending(
                        modelContext: modelContext,
                        backupFolder: backupFolder,
                        onBackupsChanged: onBackupsChanged
                    )
                }
            }
            Button("Cancel", role: .cancel) { model.cancelRestore() }
        } message: { pending in
            Text(pending.scope.confirmationMessage)
        }
        .accessibilityIdentifier("libraryTimeMachine.sheet")
    }
}

private struct LibraryTimeMachineHeader: View {
    let backupCount: Int
    let changedCount: Int
    let isLoading: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Library Time Machine")
                    .font(theme.display(size: 22, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                Text("Compare snapshots and restore only the book data you need.")
                    .font(theme.body(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 16)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Opening backup")
            } else if backupCount > 0 {
                Text(
                    "\(backupCount) backups · \(changedCount) changes",
                    comment: "Time Machine summary; first value is backup count, second is changed book count."
                )
                .font(theme.label(size: 10, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

private struct LibraryTimeMachineBackupPane: View {
    let backups: [LibraryTimeMachineBackupInfo]
    @Binding var selection: URL?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Text("Backups")
                .font(theme.body(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            if backups.isEmpty {
                ContentUnavailableView {
                    Label("No Backups", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("Create a backup first, then return here to compare it.")
                }
            } else {
                List(backups, selection: $selection) { backup in
                    LibraryTimeMachineBackupRow(
                        backup: backup,
                        isNewest: backup.id == backups.first?.id
                    )
                    .tag(backup.id)
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("libraryTimeMachine.backups")
            }
        }
    }
}

private struct LibraryTimeMachineBackupRow: View {
    let backup: LibraryTimeMachineBackupInfo
    let isNewest: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let date = backup.date {
                    Text(date, format: .dateTime.day().month(.abbreviated).year())
                        .font(theme.body(size: 11, weight: .medium))
                    Text(date, format: .dateTime.hour().minute())
                        .font(theme.label(size: 9))
                        .foregroundStyle(theme.textSecondary)
                } else {
                    Text(verbatim: backup.fileName)
                        .font(theme.body(size: 10, weight: .medium))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if isNewest {
                Text("Latest")
                    .font(theme.label(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct LibraryTimeMachineBookPane: View {
    let diffs: [LibraryTimeMachineBookDiff]
    let phase: LibraryTimeMachineViewModel.Phase
    @Binding var filter: LibraryTimeMachineBookFilter
    @Binding var searchText: String
    @Binding var selection: UUID?
    let resultCount: Int
    let onRetry: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 7) {
                HStack(spacing: 8) {
                    Picker("Show", selection: $filter) {
                        ForEach(LibraryTimeMachineBookFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Spacer()
                    Text(
                        "\(resultCount) books",
                        comment: "Number of books visible in the selected backup filter."
                    )
                    .font(theme.label(size: 9))
                    .foregroundStyle(theme.textSecondary)
                }

                TextField("Search backup", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("libraryTimeMachine.search")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()

            switch phase {
            case .idle:
                ContentUnavailableView {
                    Label("Choose a Backup", systemImage: "clock")
                } description: {
                    Text("Select a snapshot to compare it with your library.")
                }
            case .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Opening a safe working copy…")
                        .font(theme.body(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Backup Couldn’t Be Opened", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button("Try Again", action: onRetry)
                }
            case .loaded:
                if diffs.isEmpty {
                    ContentUnavailableView {
                        Label("No Matching Books", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Change the filter or search to see more books.")
                    }
                } else {
                    List(diffs, selection: $selection) { diff in
                        LibraryTimeMachineBookRow(diff: diff)
                            .tag(diff.id)
                    }
                    .listStyle(.inset)
                    .accessibilityIdentifier("libraryTimeMachine.books")
                }
            }
        }
    }
}

private struct LibraryTimeMachineBookRow: View {
    let diff: LibraryTimeMachineBookDiff

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: diff.kind.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: diff.displayTitle)
                    .font(theme.body(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(diff.kind.title)
                        .foregroundStyle(statusColor)
                    if let author = diff.displayAuthor {
                        Text(verbatim: author)
                            .lineLimit(1)
                    }
                }
                .font(theme.label(size: 9))
            }
            Spacer(minLength: 4)
            if !diff.changeGroups.isEmpty {
                Text(verbatim: String(diff.changeGroups.count))
                    .font(theme.label(size: 8, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.backgroundAlt, in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch diff.kind {
        case .deletedSinceBackup: theme.highlight
        case .modified: theme.accent
        case .addedSinceBackup: theme.success
        case .unchanged: theme.textTertiary
        }
    }
}

private struct LibraryTimeMachineDetailPane: View {
    let diff: LibraryTimeMachineBookDiff?
    let phase: LibraryTimeMachineViewModel.Phase
    let isRestoring: Bool
    let onRestore: (LibraryTimeMachineRestoreScope, LibraryTimeMachineBookDiff) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if phase == .loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diff {
                LibraryTimeMachineBookDetail(
                    diff: diff,
                    isRestoring: isRestoring,
                    onRestore: onRestore
                )
            } else {
                ContentUnavailableView {
                    Label("Select a Book", systemImage: "book.closed")
                } description: {
                    Text("Choose a book to inspect exactly what changed.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("libraryTimeMachine.detail")
    }
}

private struct LibraryTimeMachineBookDetail: View {
    let diff: LibraryTimeMachineBookDiff
    let isRestoring: Bool
    let onRestore: (LibraryTimeMachineRestoreScope, LibraryTimeMachineBookDiff) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LibraryTimeMachineBookHero(diff: diff)
                if !diff.changeGroups.isEmpty {
                    LibraryTimeMachineChangedAreas(groups: diff.changeGroups)
                }
                LibraryTimeMachineRestoreActions(
                    diff: diff,
                    isRestoring: isRestoring,
                    onRestore: onRestore
                )
                if !diff.fieldChanges.isEmpty {
                    LibraryTimeMachineFieldDiffSection(changes: diff.fieldChanges)
                }
                LibraryTimeMachineStoredDataSection(diff: diff)
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

private struct LibraryTimeMachineChangedAreas: View {
    let groups: [LibraryTimeMachineChangeGroup]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Changed Areas")
                .font(theme.body(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)],
                alignment: .leading,
                spacing: 7
            ) {
                ForEach(groups, id: \.self) { group in
                    Label(group.title, systemImage: group.systemImage)
                        .font(theme.label(size: 9, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(theme.backgroundAlt, in: Capsule())
                        .accessibilityElement(children: .combine)
                }
            }
            if groups.contains(.fileRecord) {
                Label(
                    "Book file records are compared but never restored.",
                    systemImage: "lock.fill"
                )
                .font(theme.label(size: 9))
                .foregroundStyle(theme.textSecondary)
            }
        }
    }
}

private struct LibraryTimeMachineBookHero: View {
    let diff: LibraryTimeMachineBookDiff

    @Environment(\.theme) private var theme

    private var snapshot: LibraryTimeMachineBookSnapshot? {
        diff.backup ?? diff.current
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            LibraryTimeMachineCoverPreview(url: snapshot?.coverURL)
                .frame(width: 82, height: 123)
                .clipShape(RoundedRectangle(cornerRadius: WinstonLayout.cornerSmall, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: diff.displayTitle)
                    .font(theme.display(size: 22, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let author = diff.displayAuthor {
                    Text(verbatim: author)
                        .font(theme.body(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                Label(diff.kind.title, systemImage: diff.kind.systemImage)
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(statusDescription)
                    .font(theme.body(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if diff.kind == .deletedSinceBackup, snapshot?.bookFileExists == false {
                    Label(
                        "The book file is no longer present and will need to be relinked.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(theme.label(size: 10))
                    .foregroundStyle(.orange)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusDescription: LocalizedStringResource {
        switch diff.kind {
        case .deletedSinceBackup:
            "This book existed in the backup but is no longer in the current catalog."
        case .modified:
            "The backup and current catalog contain different data for this book."
        case .addedSinceBackup:
            "This book was added after the selected backup and cannot be restored from it."
        case .unchanged:
            "This book matches the selected backup."
        }
    }
}

private struct LibraryTimeMachineCoverPreview: View {
    let url: URL?

    @Environment(\.theme) private var theme
    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    BookCoverArt(accent1: theme.accent, accent2: theme.highlight)
                }
            }
            .clipped()
            .task(id: url) {
                image = nil
                guard let url else { return }
                let data = await Task.detached(priority: .utility) {
                    try? Data(contentsOf: url)
                }.value
                guard !Task.isCancelled else { return }
                image = data.flatMap(NSImage.init(data:))
            }
    }
}

private struct LibraryTimeMachineRestoreActions: View {
    let diff: LibraryTimeMachineBookDiff
    let isRestoring: Bool
    let onRestore: (LibraryTimeMachineRestoreScope, LibraryTimeMachineBookDiff) -> Void

    private var canRestoreMetadata: Bool {
        diff.current != nil && diff.changeGroups.contains(.metadata)
    }

    private var canRestoreCover: Bool {
        diff.current != nil
            && diff.changeGroups.contains(.cover)
            && diff.backup?.hasCover == true
    }

    private var canRestoreBook: Bool { diff.canRestore }

    var body: some View {
        ViewThatFits {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button {
            onRestore(.metadata, diff)
        } label: {
            Label("Restore Metadata…", systemImage: "text.badge.checkmark")
        }
        .accessibilityIdentifier("libraryTimeMachine.restoreMetadata")
        .disabled(!canRestoreMetadata || isRestoring)
        .help(Text(metadataHelp))

        Button {
            onRestore(.cover, diff)
        } label: {
            Label("Restore Cover…", systemImage: "photo")
        }
        .accessibilityIdentifier("libraryTimeMachine.restoreCover")
        .disabled(!canRestoreCover || isRestoring)
        .help(Text(coverHelp))

        Button {
            onRestore(.book, diff)
        } label: {
            if isRestoring {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Restore Book…", systemImage: "arrow.uturn.backward")
            }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("libraryTimeMachine.restoreBook")
        .disabled(!canRestoreBook || isRestoring)
        .help("Restore this book’s catalog data without replacing its EPUB or PDF file")
    }

    private var metadataHelp: LocalizedStringResource {
        if canRestoreMetadata {
            "Restore only bibliographic metadata, ratings, and notes"
        } else {
            "No metadata changes to restore"
        }
    }

    private var coverHelp: LocalizedStringResource {
        if canRestoreCover {
            "Restore only the saved cover"
        } else {
            "No saved backup cover to restore"
        }
    }
}

private struct LibraryTimeMachineFieldDiffSection: View {
    let changes: [LibraryTimeMachineFieldChange]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Changed Fields")
                .font(theme.body(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                GridRow {
                    Text("Field")
                    Text("Current")
                    Text("Backup")
                }
                .font(theme.label(size: 9, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                Divider().gridCellColumns(3)
                ForEach(changes) { change in
                    LibraryTimeMachineFieldChangeRow(change: change)
                }
            }
        }
    }
}

private struct LibraryTimeMachineFieldChangeRow: View {
    let change: LibraryTimeMachineFieldChange

    @Environment(\.theme) private var theme

    var body: some View {
        GridRow(alignment: .top) {
            Text(change.field.title)
                .font(theme.label(size: 10, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            LibraryTimeMachineFieldValueView(value: change.current)
            LibraryTimeMachineFieldValueView(value: change.backup)
                .foregroundStyle(theme.accent)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LibraryTimeMachineFieldValueView: View {
    let value: LibraryTimeMachineFieldValue

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch value {
            case .text(let value):
                if let value, !value.isEmpty {
                    Text(verbatim: value)
                } else {
                    Text("Not set")
                        .foregroundStyle(theme.textTertiary)
                }
            case .integer(let value):
                if let value {
                    Text(value, format: .number)
                } else {
                    Text("Not set")
                        .foregroundStyle(theme.textTertiary)
                }
            case .decimal(let value):
                if let value {
                    Text(value, format: .number.precision(.fractionLength(1)))
                } else {
                    Text("Not set")
                        .foregroundStyle(theme.textTertiary)
                }
            case .date(let value):
                if let value {
                    Text(value, format: .dateTime.day().month(.abbreviated).year())
                } else {
                    Text("Not set")
                        .foregroundStyle(theme.textTertiary)
                }
            case .textList(let values):
                if values.isEmpty {
                    Text("Not set")
                        .foregroundStyle(theme.textTertiary)
                } else {
                    Text(verbatim: values.formatted())
                }
            case .boolean(let value):
                if let value {
                    if value {
                        Text("Yes")
                    } else {
                        Text("No")
                    }
                } else {
                    Text("Not set")
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .font(theme.body(size: 10))
        .foregroundStyle(theme.textPrimary)
        .lineLimit(4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LibraryTimeMachineStoredDataSection: View {
    let diff: LibraryTimeMachineBookDiff

    @Environment(\.theme) private var theme

    private var backup: LibraryTimeMachineBookSnapshot? { diff.backup }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stored With This Book")
                .font(theme.body(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Current")
                    Text("Backup")
                }
                .font(theme.label(size: 9, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                LibraryTimeMachineCountRow(
                    title: "Reading cycles",
                    current: diff.current?.reading.sessions.count,
                    backup: backup?.reading.sessions.count
                )
                LibraryTimeMachineCountRow(
                    title: "Highlights and notes",
                    current: diff.current?.highlights.count,
                    backup: backup?.highlights.count
                )
                LibraryTimeMachineCountRow(
                    title: "Collection memberships",
                    current: diff.current?.collections.count,
                    backup: backup?.collections.count
                )
                GridRow {
                    Text("Saved cover")
                    LibraryTimeMachineAvailabilityValue(value: diff.current.map(\.hasCover))
                    LibraryTimeMachineAvailabilityValue(value: backup.map(\.hasCover))
                }
            }
            .font(theme.body(size: 10))
            .foregroundStyle(theme.textSecondary)
        }
    }
}

private struct LibraryTimeMachineAvailabilityValue: View {
    let value: Bool?

    var body: some View {
        if let value {
            if value {
                Text("Yes")
            } else {
                Text("No")
            }
        } else {
            Text("—")
                .accessibilityLabel("Not available")
        }
    }
}

private struct LibraryTimeMachineCountRow: View {
    let title: LocalizedStringResource
    let current: Int?
    let backup: Int?

    var body: some View {
        GridRow {
            Text(title)
            if let current {
                Text(current, format: .number)
            } else {
                Text("—")
                    .accessibilityLabel("Not available")
            }
            if let backup {
                Text(backup, format: .number)
            } else {
                Text("—")
                    .accessibilityLabel("Not available")
            }
        }
    }
}

private struct LibraryTimeMachineFooter: View {
    let notice: LibraryTimeMachineRestoreNotice?
    let error: String?
    let isRestoring: Bool
    let onClearMessage: () -> Void
    let onDone: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.destructive)
                    .lineLimit(2)
                Button("Dismiss", action: onClearMessage)
                    .buttonStyle(.borderless)
            } else if let notice {
                Label {
                    Text(noticeText(notice))
                } icon: {
                    Image(systemName: noticeIcon(notice))
                }
                .foregroundStyle(noticeColor(notice))
                .lineLimit(2)
                Button("Dismiss", action: onClearMessage)
                    .buttonStyle(.borderless)
            } else {
                Label(
                    "A safety backup is created before every restore. Book files are never replaced.",
                    systemImage: "lock.shield"
                )
                .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 12)
            Button("Done", action: onDone)
                .keyboardShortcut(.cancelAction)
                .disabled(isRestoring)
                .accessibilityIdentifier("libraryTimeMachine.done")
        }
        .font(theme.label(size: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial)
    }

    private func noticeText(_ notice: LibraryTimeMachineRestoreNotice) -> LocalizedStringResource {
        if notice.result.bookFileMissing {
            return LocalizedStringResource(
                "Restored “\(notice.bookTitle)”. Its book file is missing and must be relinked.",
                comment: "Restore result. The interpolated value is the book title."
            )
        }
        if notice.result.skippedCollectionCount > 0 {
            return LocalizedStringResource(
                "Restored “\(notice.bookTitle)”. Some deleted collections could not be reattached.",
                comment: "Restore result. The interpolated value is the book title."
            )
        }
        return LocalizedStringResource(
            "Restored “\(notice.bookTitle)” and saved the previous state as a new backup.",
            comment: "Restore result. The interpolated value is the book title."
        )
    }

    private func noticeIcon(_ notice: LibraryTimeMachineRestoreNotice) -> String {
        notice.result.bookFileMissing || notice.result.skippedCollectionCount > 0
            ? "exclamationmark.triangle.fill"
            : "checkmark.circle.fill"
    }

    private func noticeColor(_ notice: LibraryTimeMachineRestoreNotice) -> Color {
        notice.result.bookFileMissing || notice.result.skippedCollectionCount > 0
            ? .orange
            : theme.success
    }
}
