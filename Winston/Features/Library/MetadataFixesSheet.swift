import SwiftUI

struct MetadataFixesSheet: View {
    let viewModel: LibraryViewModel
    let scope: MetadataCleanupScope

    @Environment(\.dismiss) private var dismiss
    @State private var analysis: MetadataCleanupAnalysis?
    @State private var selectedChangeIDs: Set<String> = []
    @State private var preferredTextByGroupID: [String: String] = [:]
    @State private var expandedGroupIDs: Set<String> = []
    @State private var isApplying = false
    @State private var result: MetadataCleanupApplyResult?
    @State private var showsConflictDetails = false
    @State private var errorMessage: String?

    init(
        viewModel: LibraryViewModel,
        scope: MetadataCleanupScope = .wholeLibrary
    ) {
        self.viewModel = viewModel
        self.scope = scope
    }

    var body: some View {
        VStack(spacing: 0) {
            MetadataCleanupHeader(
                scopeLabel: scope.label,
                changeCount: analysis?.changeCount
            )
            Divider()
            content
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            Divider()
            footer
        }
        .frame(
            minWidth: 720,
            idealWidth: 860,
            maxWidth: 1_100,
            minHeight: 620,
            idealHeight: 760,
            maxHeight: .infinity
        )
        .background { ThemedBackground() }
        .task(id: scope) { await loadAnalysis() }
        .onDisappear {
            viewModel.cancelMetadataCleanupAnalysis()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let progress = viewModel.metadataCleanupProgress,
           analysis == nil {
            VStack(spacing: 14) {
                ProgressView(value: progress.fraction)
                    .frame(width: 260)
                Text("Analyzing \(progress.completedCount) of \(progress.totalCount) books…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    viewModel.cancelMetadataCleanupAnalysis()
                    dismiss()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result {
            MetadataCleanupResultContent(
                result: result,
                showsConflicts: showsConflictDetails
            )
        } else if let analysis, analysis.groups.isEmpty {
            ContentUnavailableView {
                Label("Nothing to clean up", systemImage: "checkmark.seal")
            } description: {
                Text("Winston found no safe normalizations, review suggestions, or informational metadata issues in this scope.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let analysis {
            List {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                ForEach(MetadataCleanupRisk.allCases, id: \.self) { risk in
                    let groups = analysis.groups.filter { $0.risk == risk }
                    if !groups.isEmpty {
                        MetadataCleanupRiskSection(
                            risk: risk,
                            groups: groups,
                            selectedChangeIDs: $selectedChangeIDs,
                            preferredTextByGroupID: $preferredTextByGroupID,
                            expandedGroupIDs: $expandedGroupIDs,
                            isEnabled: !isApplying
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
        } else {
            ProgressView("Preparing metadata analysis…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let result {
                if result.conflictCount > 0, !showsConflictDetails {
                    Button("Review \(result.conflictCount) Conflicts") {
                        showsConflictDetails = true
                    }
                }
                if !result.appliedBookIDs.isEmpty {
                    Button("Show Affected Books") {
                        let ids = Array(result.appliedBookIDs)
                        dismiss()
                        Task { @MainActor in
                            await Task.yield()
                            NotificationCenter.default.post(
                                name: .showImportedBooks,
                                object: nil,
                                userInfo: ["bookIDs": ids]
                            )
                        }
                    }
                }
                Spacer()
                if viewModel.canUndoMetadataCleanup {
                    Button("Undo Cleanup") { undo() }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                if viewModel.canUndoMetadataCleanup {
                    Button("Undo Last Cleanup") { undo() }
                }
                Spacer()
                Button("Cancel") {
                    viewModel.cancelMetadataCleanupAnalysis()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Apply \(selectedChangeIDs.count) Changes") {
                    applySelected()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    selectedChangeIDs.isEmpty
                        || isApplying
                        || analysis == nil
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func loadAnalysis() async {
        analysis = nil
        result = nil
        showsConflictDetails = false
        errorMessage = nil
        let loaded = await viewModel.metadataCleanup(scope: scope)
        guard !Task.isCancelled else { return }
        analysis = loaded
        selectedChangeIDs = Set(
            loaded.groups
                .filter { $0.risk == .safe }
                .flatMap(\.changes)
                .map(\.id)
        )
        expandedGroupIDs = Set(
            loaded.groups.prefix(1).map(\.id)
        )
    }

    private func applySelected() {
        guard !isApplying, let analysis else { return }
        let changes = analysis.groups.flatMap { group -> [MetadataCleanupChange] in
            let effective = preferredTextByGroupID[group.id].map {
                group.replacingPreferredText($0)
            } ?? group
            return zip(group.changes, effective.changes).compactMap {
                original, replacement in
                selectedChangeIDs.contains(original.id) ? replacement : nil
            }
        }
        guard !changes.isEmpty else { return }
        isApplying = true
        errorMessage = nil
        switch viewModel.applyMetadataCleanup(changes) {
        case .success(let result):
            self.result = result
            showsConflictDetails = false
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
        isApplying = false
    }

    private func undo() {
        isApplying = true
        errorMessage = nil
        switch viewModel.undoLastMetadataCleanup() {
        case .success(let result):
            self.result = result
            showsConflictDetails = false
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
        isApplying = false
    }
}

private struct MetadataCleanupHeader: View {
    let scopeLabel: String
    let changeCount: Int?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "wand.and.sparkles")
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 38, height: 38)
                .background(
                    theme.accent.opacity(0.12),
                    in: RoundedRectangle(
                        cornerRadius: WinstonLayout.cornerMedium,
                        style: .continuous
                    )
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                theme.styledText(
                    terminal: "// metadata_cleanup",
                    native: "Metadata Cleanup"
                )
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

                Text("Review exact before-and-after changes for \(scopeLabel).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            if let changeCount {
                Label("\(changeCount) changes", systemImage: "checklist")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }
}

private struct MetadataCleanupRiskSection: View {
    let risk: MetadataCleanupRisk
    let groups: [MetadataCleanupGroup]
    @Binding var selectedChangeIDs: Set<String>
    @Binding var preferredTextByGroupID: [String: String]
    @Binding var expandedGroupIDs: Set<String>
    let isEnabled: Bool

    var body: some View {
        Section {
            ForEach(groups) { group in
                MetadataCleanupGroupRow(
                    group: group,
                    selectedChangeIDs: $selectedChangeIDs,
                    preferredText: preferredTextBinding(for: group),
                    isExpanded: expandedBinding(for: group),
                    isEnabled: isEnabled
                )
            }
        } header: {
            Label(risk.label, systemImage: risk.systemImage)
        } footer: {
            Text(risk.explanation)
        }
    }

    private func preferredTextBinding(
        for group: MetadataCleanupGroup
    ) -> Binding<String> {
        Binding(
            get: {
                preferredTextByGroupID[group.id]
                    ?? group.changes.first?.after.displayText
                    ?? ""
            },
            set: { preferredTextByGroupID[group.id] = $0 }
        )
    }

    private func expandedBinding(
        for group: MetadataCleanupGroup
    ) -> Binding<Bool> {
        Binding(
            get: { expandedGroupIDs.contains(group.id) },
            set: {
                if $0 {
                    expandedGroupIDs.insert(group.id)
                } else {
                    expandedGroupIDs.remove(group.id)
                }
            }
        )
    }
}

private struct MetadataCleanupGroupRow: View {
    let group: MetadataCleanupGroup
    @Binding var selectedChangeIDs: Set<String>
    @Binding var preferredText: String
    @Binding var isExpanded: Bool
    let isEnabled: Bool

    private var selectedCount: Int {
        group.changes.count { selectedChangeIDs.contains($0.id) }
    }

    private var canEditPreferredText: Bool {
        group.isApplicable
            && Set(group.changes.map(\.field)).count == 1
            && group.changes.allSatisfy {
                if case .text = $0.after { return true }
                return false
            }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if canEditPreferredText {
                    LabeledContent("Preferred value") {
                        TextField("Preferred value", text: $preferredText)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 220)
                    }
                }
                ForEach(group.changes) { change in
                    MetadataCleanupChangeRow(
                        change: change,
                        isSelected: Binding(
                            get: { selectedChangeIDs.contains(change.id) },
                            set: { selected in
                                if selected {
                                    selectedChangeIDs.insert(change.id)
                                } else {
                                    selectedChangeIDs.remove(change.id)
                                }
                            }
                        ),
                        isEnabled: isEnabled && group.isApplicable
                    )
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack(spacing: 10) {
                if group.isApplicable {
                    Toggle(
                        "Select all changes in \(group.title)",
                        isOn: Binding(
                            get: {
                                selectedCount == group.changes.count
                                    && !group.changes.isEmpty
                            },
                            set: { selected in
                                for change in group.changes {
                                    if selected {
                                        selectedChangeIDs.insert(change.id)
                                    } else {
                                        selectedChangeIDs.remove(change.id)
                                    }
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .disabled(!isEnabled)
                } else {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.body.weight(.semibold))
                    Text(group.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text("\(group.affectedBookIDs.count) books")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MetadataCleanupChangeRow: View {
    let change: MetadataCleanupChange
    @Binding var isSelected: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(
                "Apply change to \(change.bookTitle)",
                isOn: $isSelected
            )
            .labelsHidden()
            .disabled(!isEnabled)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(change.bookTitle)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(change.field.localizedName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(change.before.displayText)
                        .foregroundStyle(.secondary)
                        .strikethrough()
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(change.after.displayText)
                }
                .font(.caption)
                .textSelection(.enabled)
            }
        }
        .padding(.leading, 4)
    }
}

private struct MetadataCleanupResultContent: View {
    let result: MetadataCleanupApplyResult
    let showsConflicts: Bool

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label(
                    result.conflictCount == 0
                        ? "Metadata cleanup complete"
                        : "Metadata cleanup completed with conflicts",
                    systemImage: result.conflictCount == 0
                        ? "checkmark.circle"
                        : "exclamationmark.circle"
                )
            } description: {
                Text(
                    "Applied \(result.appliedCount) of \(result.requestedChangeCount) changes. \(result.conflictCount) changes were skipped because the book changed or was removed."
                )
            }

            if showsConflicts, !result.conflicts.isEmpty {
                List(result.conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conflict.change.bookTitle)
                            .font(.callout.weight(.semibold))
                        Text(
                            "Expected \(conflict.change.before.displayText), found \(conflict.currentValue?.displayText ?? String(localized: "missing"))."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding()
    }
}

private extension MetadataCleanupRisk {
    var label: String {
        switch self {
        case .safe: String(localized: "Safe to Apply")
        case .review: String(localized: "Needs Review")
        case .informational: String(localized: "Informational")
        }
    }

    var explanation: String {
        switch self {
        case .safe:
            String(localized: "Deterministic normalization that preserves meaning.")
        case .review:
            String(localized: "Suggestions can change how books are identified or grouped; choose them explicitly.")
        case .informational:
            String(localized: "Winston cannot choose a correct replacement automatically.")
        }
    }

    var systemImage: String {
        switch self {
        case .safe: "checkmark.shield"
        case .review: "person.crop.circle.badge.questionmark"
        case .informational: "info.circle"
        }
    }
}
