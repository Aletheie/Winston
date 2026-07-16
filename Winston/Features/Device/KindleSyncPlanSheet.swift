import SwiftUI
import Observation

@MainActor
@Observable
private final class KindleSyncPlanSelection {
    var selectedIDs: Set<KindleSyncPlanItem.ID> = []
    var removalIDs: Set<KindleSyncPlanItem.ID> = []

    subscript(contains id: KindleSyncPlanItem.ID) -> Bool {
        get { selectedIDs.contains(id) }
        set {
            if newValue {
                selectedIDs.insert(id)
            } else {
                selectedIDs.remove(id)
            }
        }
    }
}

private struct KindleSyncPlanSectionData: Identifiable, Equatable {
    let action: KindleSyncAction
    let items: [KindleSyncPlanItem]

    var id: KindleSyncAction { action }
}

private enum KindleProfileEditorMode {
    case create
    case rename(profileID: UUID)
}

struct KindleSyncPlanSheet: View {
    let books: [Book]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(DeviceMonitor.self) private var monitor
    @Environment(TransferQueue.self) private var transferQueue
    @Environment(KindleSyncProfileStore.self) private var profileStore
    @Environment(ToastCenter.self) private var toasts

    @State private var plan: KindleSyncPlan?
    @State private var sections: [KindleSyncPlanSectionData] = []
    @State private var selection = KindleSyncPlanSelection()
    @State private var isApplying = false
    @State private var applyTask: Task<Void, Never>?
    @State private var showsRemovalConfirmation = false
    @State private var showsProfileEditor = false
    @State private var profileEditorMode: KindleProfileEditorMode = .create
    @State private var profileName = ""

    var body: some View {
        VStack(spacing: 0) {
            KindleSyncPlanHeader(
                deviceName: monitor.info?.name ?? String(localized: "Kindle"),
                profileName: plan?.profileName,
                profiles: profileStore.profiles,
                activeProfileID: plan?.profileID,
                isApplying: isApplying,
                onSelectProfile: selectProfile,
                onCreateProfile: beginCreatingProfile,
                onRenameProfile: beginRenamingProfile
            )

            Divider()

            if let plan {
                KindleSyncPlanSummary(plan: plan)
                Divider()
                if plan.items.isEmpty {
                    KindleSyncPlanEmptyState()
                } else {
                    KindleSyncPlanList(
                        sections: sections,
                        selection: selection,
                        isEnabled: !isApplying
                    )
                }
            } else {
                ProgressView("Building sync plan…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            KindleSyncPlanFooter(
                selectedCount: selection.selectedIDs.count,
                isApplying: isApplying,
                canApply: monitor.isConnected
                    && !transferQueue.isTransferring
                    && !selection.selectedIDs.isEmpty,
                onRefresh: { rebuildPlan(resetSelection: true) },
                onCancel: { dismiss() },
                onCancelApply: cancelApply,
                onApply: requestApply
            )
        }
        .frame(minWidth: 760, idealWidth: 840, minHeight: 560, idealHeight: 680)
        .background(theme.background)
        .interactiveDismissDisabled(isApplying)
        .task { rebuildPlan(resetSelection: true) }
        .onChange(of: monitor.books) { rebuildPlan(resetSelection: false) }
        .onChange(of: monitor.info) { rebuildPlan(resetSelection: true) }
        .alert(profileEditorTitle, isPresented: $showsProfileEditor) {
            TextField("Profile Name", text: $profileName)
            if profileEditorMode.isCreate {
                Button("Create") { commitProfileEdit() }
            } else {
                Button("Rename") { commitProfileEdit() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Each profile remembers what was last sent to one Kindle.")
        }
        .alert("Remove \(selectedRemovalCount) books from Kindle?", isPresented: $showsRemovalConfirmation) {
            Button("Remove and Apply", role: .destructive) {
                startApplying()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only the selected device copies will be removed. Your Winston library is unchanged.")
        }
    }

    private var selectedItems: [KindleSyncPlanItem] {
        guard let plan else { return [] }
        return plan.items.filter { selection.selectedIDs.contains($0.id) && $0.isSelectable }
    }

    private var selectedRemovalCount: Int {
        selection.selectedIDs.intersection(selection.removalIDs).count
    }

    private var profileEditorTitle: LocalizedStringKey {
        profileEditorMode.isCreate ? "New Kindle Profile" : "Rename Kindle Profile"
    }

    private func rebuildPlan(resetSelection: Bool) {
        guard let info = monitor.info else {
            plan = nil
            sections = []
            selection.selectedIDs = []
            selection.removalIDs = []
            return
        }
        let profile = profileStore.ensureProfile(for: info)
        let candidates = books.map(KindleSendPreparation.candidate)
        let newPlan = KindleSyncPlanner.makePlan(
            candidates: candidates,
            deviceBooks: monitor.books,
            profile: profile
        )
        plan = newPlan
        sections = Self.makeSections(from: newPlan.items)
        selection.removalIDs = Set(newPlan.items.filter { $0.action == .remove }.map(\.id))
        if resetSelection {
            selection.selectedIDs = newPlan.selectedByDefault
        } else {
            let validIDs = Set(newPlan.items.filter(\.isSelectable).map(\.id))
            selection.selectedIDs.formIntersection(validIDs)
        }
    }

    private static func makeSections(from items: [KindleSyncPlanItem]) -> [KindleSyncPlanSectionData] {
        let order: [KindleSyncAction] = [.update, .add, .repairCover, .remove, .blocked, .keep]
        let grouped = Dictionary(grouping: items, by: \.action)
        return order.compactMap { action in
            guard let actionItems = grouped[action], !actionItems.isEmpty else { return nil }
            return KindleSyncPlanSectionData(action: action, items: actionItems)
        }
    }

    private func requestApply() {
        if selectedRemovalCount > 0 {
            showsRemovalConfirmation = true
        } else {
            startApplying()
        }
    }

    private func startApplying() {
        guard applyTask == nil else { return }
        applyTask = Task {
            await applySelectedItems()
            applyTask = nil
        }
    }

    private func cancelApply() {
        applyTask?.cancel()
        transferQueue.cancel()
    }

    private func applySelectedItems() async {
        guard !isApplying, !transferQueue.isTransferring,
              let info = monitor.info,
              let connection = monitor.connection else { return }
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        isApplying = true
        defer { isApplying = false }

        var failureCount = 0
        var completedCount = 0

        let removalIDs = Set(selected.filter { $0.action == .remove }.compactMap(\.deviceBookID))
        let removals = monitor.books.filter { removalIDs.contains($0.id) }
        var removedIDs: Set<DeviceBook.ID> = []
        var removedNames: Set<String> = []
        for deviceBook in removals {
            guard !Task.isCancelled else { break }
            do {
                try await connection.delete(deviceBook)
                removedIDs.insert(deviceBook.id)
                removedNames.insert(deviceBook.fileName)
                completedCount += 1
            } catch {
                failureCount += 1
            }
        }
        monitor.removeBooksLocally(removedIDs)
        profileStore.recordRemoval(fileNames: removedNames, from: info)

        let booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.uuid, $0) })
        let sendIDs = selected
            .filter { $0.action == .add || $0.action == .update }
            .compactMap(\.bookID)
        let booksToSend = sendIDs.compactMap { booksByID[$0] }
        failureCount += max(0, sendIDs.count - booksToSend.count)
        if !Task.isCancelled, !booksToSend.isEmpty {
            await transferQueue.send(books: booksToSend, via: monitor, announcesResult: false)
            failureCount += transferQueue.failedCount
            completedCount += transferQueue.items.count - transferQueue.failedCount
        }

        let coverItems = selected.filter { $0.action == .repairCover }
        for item in coverItems where !Task.isCancelled {
            guard let bookID = item.bookID,
                  let deviceBookID = item.deviceBookID,
                  let book = booksByID[bookID],
                  let deviceBook = monitor.books.first(where: { $0.id == deviceBookID }) else {
                failureCount += 1
                continue
            }
            if await transferQueue.repairCover(
                for: book,
                deviceBook: deviceBook,
                via: monitor,
                announcesResult: false
            ) {
                completedCount += 1
            } else {
                failureCount += 1
            }
        }

        if monitor.isConnected {
            await monitor.refreshBooks()
            await monitor.refreshInfo()
        }
        if Task.isCancelled {
            toasts.info(String(localized: "Kindle sync cancelled."))
            rebuildPlan(resetSelection: true)
            return
        }
        if failureCount == 0 {
            toasts.success(String(localized: "Applied \(completedCount) Kindle sync changes."))
            dismiss()
        } else {
            toasts.error(String(localized: "Kindle sync finished with \(failureCount) failed changes."))
            rebuildPlan(resetSelection: true)
        }
    }

    private func selectProfile(_ profileID: UUID) {
        guard let info = monitor.info else { return }
        profileStore.assign(profileID: profileID, to: info)
        rebuildPlan(resetSelection: true)
    }

    private func beginCreatingProfile() {
        profileEditorMode = .create
        profileName = monitor.info?.name ?? "Kindle"
        showsProfileEditor = true
    }

    private func beginRenamingProfile() {
        guard let plan else { return }
        profileEditorMode = .rename(profileID: plan.profileID)
        profileName = plan.profileName
        showsProfileEditor = true
    }

    private func commitProfileEdit() {
        guard let info = monitor.info else { return }
        switch profileEditorMode {
        case .create:
            _ = profileStore.createProfile(named: profileName, for: info)
        case .rename(let profileID):
            profileStore.rename(profileID: profileID, to: profileName)
        }
        rebuildPlan(resetSelection: true)
    }
}

private extension KindleProfileEditorMode {
    var isCreate: Bool {
        if case .create = self { return true }
        return false
    }
}

private struct KindleSyncPlanHeader: View {
    let deviceName: String
    let profileName: String?
    let profiles: [KindleSyncProfile]
    let activeProfileID: UUID?
    let isApplying: Bool
    let onSelectProfile: (UUID) -> Void
    let onCreateProfile: () -> Void
    let onRenameProfile: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: 3) {
                theme.styledText(terminal: "// kindle_sync_plan", native: "Kindle Sync Plan")
                    .font(theme.body(size: 17, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                Text("Review exactly what will change on \(deviceName).")
                    .font(theme.label(size: 11, weight: .regular))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer()

            Menu {
                ForEach(profiles) { profile in
                    Button {
                        onSelectProfile(profile.id)
                    } label: {
                        if profile.id == activeProfileID {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
                Divider()
                Button("New Profile…", action: onCreateProfile)
                Button("Rename Current Profile…", action: onRenameProfile)
                    .disabled(activeProfileID == nil)
            } label: {
                Label(profileName ?? String(localized: "Profile"), systemImage: "person.crop.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isApplying)
            .help("Use a separate sync history for each Kindle.")
        }
        .padding(18)
        .background(.ultraThinMaterial)
    }
}

private struct KindleSyncPlanSummary: View {
    let plan: KindleSyncPlan

    @Environment(\.theme) private var theme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                KindleSyncSummaryMetric(value: plan.count(for: .add), label: "Add", color: theme.accent)
                Divider().frame(height: 26)
                KindleSyncSummaryMetric(value: plan.count(for: .update), label: "Update", color: theme.accentSecondary)
                Divider().frame(height: 26)
                KindleSyncSummaryMetric(value: plan.count(for: .repairCover), label: "Covers", color: theme.accentTertiary)
                Divider().frame(height: 26)
                KindleSyncSummaryMetric(value: plan.count(for: .remove), label: "Optional removals", color: theme.destructive)
                Divider().frame(height: 26)
                KindleSyncSummaryMetric(value: plan.count(for: .keep), label: "Keep", color: theme.success)
            }
            HStack(spacing: 14) {
                Text("\(plan.items.count) planned items")
                Text("\(plan.count(for: .add) + plan.count(for: .update) + plan.count(for: .repairCover)) changes")
            }
            .font(theme.label(size: 10))
            .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(theme.backgroundAlt.opacity(0.7))
    }
}

private struct KindleSyncSummaryMetric: View {
    let value: Int
    let label: LocalizedStringResource
    let color: Color

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(value, format: .number)
                .font(theme.label(size: 12, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(theme.label(size: 10, weight: .regular))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }
}

private struct KindleSyncPlanList: View {
    let sections: [KindleSyncPlanSectionData]
    let selection: KindleSyncPlanSelection
    let isEnabled: Bool

    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        KindleSyncPlanRow(item: item, selection: selection, isEnabled: isEnabled)
                    }
                } header: {
                    HStack(spacing: 5) {
                        Text(section.action.title)
                        Text(section.items.count, format: .number)
                            .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

private struct KindleSyncPlanRow: View {
    let item: KindleSyncPlanItem
    let selection: KindleSyncPlanSelection
    let isEnabled: Bool

    var body: some View {
        @Bindable var selection = selection
        VStack {
            if item.isSelectable {
                Toggle(isOn: $selection[contains: item.id]) {
                    KindleSyncPlanRowLabel(item: item)
                }
                    .toggleStyle(.checkbox)
                    .disabled(!isEnabled)
            } else {
                KindleSyncPlanRowLabel(item: item)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct KindleSyncPlanRowLabel: View {
    let item: KindleSyncPlanItem

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {

            Image(systemName: item.action.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(item.action.color(in: theme))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(theme.body(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if let author = item.author {
                        Text(author)
                            .font(theme.label(size: 10, weight: .regular))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Text(item.reason.explanation)
                    .font(theme.label(size: 10, weight: .regular))
                    .foregroundStyle(item.action == .remove ? theme.destructive : theme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            if let format = item.formatSummary {
                Text(verbatim: format)
                    .font(theme.label(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }
}

private struct KindleSyncPlanEmptyState: View {
    var body: some View {
        ContentUnavailableView {
            Label("Nothing to Sync", systemImage: "checkmark.circle")
        } description: {
            Text("This Kindle and the current library profile are both empty.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct KindleSyncPlanFooter: View {
    let selectedCount: Int
    let isApplying: Bool
    let canApply: Bool
    let onRefresh: () -> Void
    let onCancel: () -> Void
    let onCancelApply: () -> Void
    let onApply: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onRefresh) {
                Label("Refresh Plan", systemImage: "arrow.clockwise")
            }
            .disabled(isApplying)

            Spacer()

            if isApplying {
                ProgressView()
                    .controlSize(.small)
                Text("Applying changes…")
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textSecondary)
            } else {
                Text("\(selectedCount) changes selected")
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
            }

            if isApplying {
                Button("Cancel Sync", action: onCancelApply)
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            Button("Apply \(selectedCount) Changes", action: onApply)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply || isApplying)
        }
        .padding(14)
        .background(.ultraThinMaterial)
    }
}

private extension KindleSyncAction {
    var title: LocalizedStringResource {
        switch self {
        case .add: "Add"
        case .update: "Update"
        case .repairCover: "Repair Covers"
        case .keep: "Keep"
        case .remove: "Optional Removal"
        case .blocked: "Needs Attention"
        }
    }

    var systemImage: String {
        switch self {
        case .add: "plus.circle.fill"
        case .update: "arrow.triangle.2.circlepath.circle.fill"
        case .repairCover: "photo.badge.checkmark"
        case .keep: "checkmark.circle.fill"
        case .remove: "trash.circle.fill"
        case .blocked: "exclamationmark.lock.fill"
        }
    }

    func color(in theme: Theme) -> Color {
        switch self {
        case .add: theme.accent
        case .update: theme.accentSecondary
        case .repairCover: theme.accentTertiary
        case .keep: theme.success
        case .remove: theme.destructive
        case .blocked: theme.textTertiary
        }
    }
}

private extension KindleSyncReason {
    var explanation: LocalizedStringResource {
        switch self {
        case .notOnDevice: "Not on this Kindle yet."
        case .sourceChanged: "The library file changed since the last transfer."
        case .outdatedConversion: "The Kindle conversion is older than its source file and will be regenerated."
        case .formatChanged: "A different Kindle format is now preferred; the old variant will be replaced."
        case .coverChanged: "The library cover changed since the last transfer."
        case .upToDate: "Already matches this profile; it will be left untouched."
        case .onlyOnDevice: "Only on the Kindle. Removal is optional and off by default."
        case .duplicateVariant: "An extra format for the same title. Removal is optional and off by default."
        case .drmProtected: "DRM-protected books cannot be sent over USB."
        case .fileUnavailable: "The local book file is missing or damaged."
        case .fileNameCollision: "Multiple library books would use the same Kindle filename. Re-import one with a different filename before syncing."
        }
    }
}

private extension KindleSyncPlanItem {
    var formatSummary: String? {
        switch (sourceFormat, targetFormat) {
        case let (source?, target?) where source.caseInsensitiveCompare(target) != .orderedSame:
            "\(source) → \(target)"
        case let (_, target?):
            target
        case let (source?, nil):
            source
        default:
            nil
        }
    }
}
