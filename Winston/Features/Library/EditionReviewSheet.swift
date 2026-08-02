import SwiftUI

struct EditionReviewSheet: View {
    let books: [Book]
    let service: CatalogReconciliationService

    @Environment(\.dismiss) private var dismiss
    @State private var booksByUUID: [UUID: Book] = [:]
    @State private var isScanning = false
    @State private var selectedPairKeys: Set<String> = []
    @State private var focusedPairKey: String?
    @State private var verdictFilter: EditionVerdict?
    @State private var confidenceFilter: MatchConfidence?
    @State private var batchController = ReconciliationBatchController()

    private var visibleProposals: [EditionMatchProposal] {
        service.pendingProposals.filter { proposal in
            (verdictFilter == nil || proposal.verdict == verdictFilter)
                && (confidenceFilter == nil || proposal.confidence == confidenceFilter)
        }
    }

    private var focusedProposal: EditionMatchProposal? {
        guard let focusedPairKey else { return nil }
        return service.pendingProposals.first { $0.pairKey == focusedPairKey }
    }

    var body: some View {
        let proposals = service.pendingProposals

        VStack(spacing: 0) {
            ReconciliationHeader(isScanning: isScanning)
            Divider()
            if proposals.isEmpty, !isScanning {
                ReconciliationEmptyState()
            } else {
                ReconciliationFilterBar(
                    verdict: $verdictFilter,
                    confidence: $confidenceFilter,
                    visibleCount: visibleProposals.count,
                    totalCount: proposals.count
                )
                Divider()
                HSplitView {
                    EditionProposalList(
                        proposals: visibleProposals,
                        booksByUUID: booksByUUID,
                        selection: $selectedPairKeys,
                        focus: $focusedPairKey,
                        isEnabled: !batchController.isRunning,
                        onDismiss: dismissProposal
                    )
                    .frame(minWidth: 300, idealWidth: 360)

                    ReconciliationWorkspaceDetail(
                        proposal: focusedProposal,
                        booksByUUID: booksByUUID,
                        service: service,
                        isBatchRunning: batchController.isRunning,
                        onPrevious: focusPreviousProposal,
                        onNext: focusNextProposal,
                        onResolved: proposalWasResolved
                    )
                    .id(focusedProposal?.pairKey)
                    .frame(minWidth: 340, idealWidth: 460)
                }
            }
            if let progress = batchController.progress {
                Divider()
                ReconciliationBatchProgressView(
                    progress: progress,
                    isCancelling: batchController.isCancelling,
                    onCancel: batchController.cancel
                )
            } else if let result = batchController.result {
                Divider()
                ReconciliationBatchResultView(
                    result: result,
                    booksByUUID: booksByUUID,
                    onRetry: retryBatch,
                    onDismiss: batchController.clearResult
                )
            }
            Divider()
            ReconciliationWorkspaceCommandBar(
                isScanning: isScanning,
                selectedCount: selectedPairKeys.count,
                hiddenSelectedCount: selectedPairKeys.subtracting(
                    Set(visibleProposals.map(\.pairKey))
                ).count,
                visibleCount: visibleProposals.count,
                canApply: visibleProposals.contains {
                    selectedPairKeys.contains($0.pairKey) && $0.canApply
                },
                isRunning: batchController.isRunning,
                onSelectAllVisible: selectAllVisible,
                onClearSelection: { selectedPairKeys.removeAll() },
                onKeepSeparate: { startBatch(.dismiss) },
                onApply: { startBatch(.apply) },
                onRescan: { Task { await scan() } },
                onDone: { dismiss() }
            )
        }
        .frame(minWidth: 620, idealWidth: 760, maxWidth: 1050, minHeight: 560, idealHeight: 720)
        .onChange(of: LibraryMutationLog.shared.revision, initial: true) {
            rebuildBookIndex()
        }
        .onChange(of: visibleProposals.map(\.pairKey), initial: true) { _, pairKeys in
            synchronizeWorkspace(with: pairKeys)
        }
        .onChange(of: batchController.result?.id) {
            guard let result = batchController.result else { return }
            selectedPairKeys = result.retryablePairKeys
            synchronizeWorkspace(with: visibleProposals.map(\.pairKey))
        }
        .task { await scan() }
        .interactiveDismissDisabled(batchController.isRunning)
    }

    private func rebuildBookIndex() {
        booksByUUID = Dictionary(books.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func dismissProposal(_ proposal: EditionMatchProposal) {
        service.dismiss(proposal)
        selectedPairKeys.remove(proposal.pairKey)
        proposalWasResolved(proposal.pairKey)
    }

    private func selectAllVisible() {
        selectedPairKeys.formUnion(visibleProposals.map(\.pairKey))
    }

    private func startBatch(_ action: ReconciliationBatchAction) {
        batchController.start(
            action: action,
            pairKeys: selectedPairKeys,
            service: service
        )
    }

    private func retryBatch() {
        guard let result = batchController.result,
              !result.retryablePairKeys.isEmpty else { return }
        batchController.clearResult()
        batchController.start(
            action: result.action,
            pairKeys: result.retryablePairKeys,
            service: service
        )
    }

    private func synchronizeWorkspace(with visiblePairKeys: [String]) {
        let pendingKeys = Set(service.pendingProposals.map(\.pairKey))
        selectedPairKeys.formIntersection(pendingKeys)
        if let focusedPairKey, pendingKeys.contains(focusedPairKey) { return }
        focusedPairKey = visiblePairKeys.first
    }

    private func proposalWasResolved(_ pairKey: String) {
        selectedPairKeys.remove(pairKey)
        let remaining = visibleProposals.map(\.pairKey).filter { $0 != pairKey }
        focusedPairKey = remaining.first
    }

    private func focusPreviousProposal() {
        moveFocus(by: -1)
    }

    private func focusNextProposal() {
        moveFocus(by: 1)
    }

    private func moveFocus(by offset: Int) {
        let keys = visibleProposals.map(\.pairKey)
        guard !keys.isEmpty else {
            focusedPairKey = nil
            return
        }
        guard let focusedPairKey,
              let index = keys.firstIndex(of: focusedPairKey) else {
            self.focusedPairKey = keys.first
            return
        }
        self.focusedPairKey = keys[min(max(index + offset, 0), keys.count - 1)]
    }

    private func scan() async {
        guard !isScanning else { return }
        isScanning = true
        await service.scanLibrary()
        isScanning = false
    }
}

private struct ReconciliationReviewRequest: Identifiable {
    let proposal: EditionMatchProposal
    let books: [Book]
    let survivorUUID: UUID?

    var id: String { proposal.pairKey }
}

private struct ReconciliationHeader: View {
    let isScanning: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.usesTerminalCopy ? "// reconcile_books" : "Book Reconciliation")
                    .font(theme.body(size: 15, weight: .bold))
                Text("Every proposal requires review. Only byte-identical files may be removed.")
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            if isScanning {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(16)
    }
}

private struct ReconciliationEmptyState: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ContentUnavailableView {
            Label(
                theme.usesTerminalCopy ? "// no_suggestions" : "No reconciliation suggestions",
                systemImage: "checkmark.circle"
            )
        } description: {
            Text("Exact file matches, related editions, and similar books will appear here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReconciliationFilterBar: View {
    @Binding var verdict: EditionVerdict?
    @Binding var confidence: MatchConfidence?
    let visibleCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Picker("Proposal type", selection: $verdict) {
                Text("All Types").tag(nil as EditionVerdict?)
                ForEach(EditionVerdict.allCases, id: \.self) { value in
                    Text(verdictTitle(value)).tag(value as EditionVerdict?)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .accessibilityLabel("Proposal type filter")

            Picker("Confidence", selection: $confidence) {
                Text("All Confidence Levels").tag(nil as MatchConfidence?)
                ForEach(MatchConfidence.allCases, id: \.self) { value in
                    Text(value.label).tag(value as MatchConfidence?)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 190)
            .accessibilityLabel("Confidence filter")

            Spacer()
            Text("Showing \(visibleCount) of \(totalCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Showing \(visibleCount) of \(totalCount) proposals")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedChrome(role: .toolbar)
    }

    private func verdictTitle(_ verdict: EditionVerdict) -> LocalizedStringResource {
        switch verdict {
        case .duplicateFile: "Identical Files"
        case .sameEditionOtherFormat: "Same Edition"
        case .sameWorkOtherEdition: "Other Editions"
        case .similarItem: "Similar Only"
        }
    }
}

private struct ReconciliationWorkspaceDetail: View {
    let proposal: EditionMatchProposal?
    let booksByUUID: [UUID: Book]
    let service: CatalogReconciliationService
    let isBatchRunning: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onResolved: (String) -> Void

    @State private var applyController = ReconciliationApplyController()

    var body: some View {
        if let proposal {
            let books = proposal.memberUUIDs.compactMap { booksByUUID[$0] }
            VStack(spacing: 0) {
                HStack {
                    ReconciliationReviewHeader(proposal: proposal)
                    Spacer()
                    Button(action: onPrevious) {
                        Label("Previous Proposal", systemImage: "chevron.up")
                            .labelStyle(.iconOnly)
                    }
                    .help("Previous Proposal")
                    Button(action: onNext) {
                        Label("Next Proposal", systemImage: "chevron.down")
                            .labelStyle(.iconOnly)
                    }
                    .help("Next Proposal")
                }
                Divider()
                if books.count == proposal.memberUUIDs.count {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ReconciliationBookComparison(books: books)
                            ReconciliationPlanView(
                                proposal: proposal,
                                books: books,
                                survivorUUID: service.mergeSurvivor(among: books)?.uuid
                            )
                            if applyController.phase != .reviewing {
                                ReconciliationApplyStatus(phase: applyController.phase)
                            }
                        }
                        .padding(16)
                    }
                } else {
                    ContentUnavailableView(
                        "Proposal Changed",
                        systemImage: "arrow.clockwise",
                        description: Text("Rescan to review the current catalog state.")
                    )
                }
                Divider()
                actions(for: proposal)
            }
            .onChange(of: applyController.phase) { _, phase in
                guard phase == .completed else { return }
                onResolved(proposal.pairKey)
            }
            .onDisappear {
                applyController.cancelIfPossible()
            }
        } else {
            ContentUnavailableView(
                "Select a Proposal",
                systemImage: "books.vertical",
                description: Text("Choose a proposal to inspect its evidence and planned changes.")
            )
        }
    }

    private func actions(for proposal: EditionMatchProposal) -> some View {
        HStack {
            if applyController.phase == .committing {
                Label("Finishing protected changes…", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if applyController.canCancel {
                Button("Cancel Operation", action: applyController.cancel)
            }
            Button("Keep Separate") {
                service.dismiss(proposal)
                onResolved(proposal.pairKey)
            }
            .disabled(applyController.isRunning || isBatchRunning)
            if proposal.canApply {
                Button(actionLabel(for: proposal)) {
                    applyController.start(proposal: proposal, service: service)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!applyController.canApply || isBatchRunning)
            }
        }
        .padding(12)
        .themedChrome(role: .sheetAction)
    }

    private func actionLabel(
        for proposal: EditionMatchProposal
    ) -> LocalizedStringResource {
        if case .failed = applyController.phase { return "Try Again" }
        if applyController.phase == .cancelled { return "Try Again" }
        return switch proposal.verdict {
        case .duplicateFile: "Merge Identical Copies"
        case .sameEditionOtherFormat: "Merge Edition Records"
        case .sameWorkOtherEdition: "Group Editions"
        case .similarItem: "Keep Separate"
        }
    }
}

private struct ReconciliationBatchProgressView: View {
    let progress: ReconciliationBatchProgress
    let isCancelling: Bool
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: progress.fraction)
                .frame(width: 150)
                .accessibilityLabel("Batch reconciliation progress")
                .accessibilityValue(
                    "\(progress.completedCount) of \(progress.totalCount) proposals"
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                Text("\(progress.completedCount) of \(progress.totalCount) proposals completed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if progress.canCancel {
                Button(isCancelling ? "Cancelling…" : "Cancel Batch", action: onCancel)
                    .disabled(isCancelling)
            } else {
                Label("Protected commit", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .themedChrome(role: .sheetAction)
    }

    private var statusTitle: LocalizedStringResource {
        if isCancelling { return "Stopping after the current safe boundary…" }
        return switch progress.phase {
        case .validating: "Revalidating selected proposals…"
        case .committing: "Applying the current proposal…"
        case .cancelling: "Stopping the batch…"
        }
    }
}

private struct ReconciliationBatchResultView: View {
    let result: ReconciliationBatchResult
    let booksByUUID: [UUID: Book]
    let onRetry: () -> Void
    let onDismiss: () -> Void

    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(summary, systemImage: result.wasCancelled
                    ? "pause.circle.fill"
                    : "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(showsDetails ? "Hide Details" : "Details") {
                    showsDetails.toggle()
                }
                .buttonStyle(.link)
                if !result.retryablePairKeys.isEmpty {
                    Button("Retry Remaining", action: onRetry)
                }
                Button("Dismiss", action: onDismiss)
            }
            if showsDetails {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(result.items) { item in
                            HStack {
                                Image(systemName: symbol(for: item.outcome))
                                    .accessibilityHidden(true)
                                Text(itemTitle(item))
                                    .lineLimit(1)
                                Spacer()
                                Text(outcomeTitle(item.outcome))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption2)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
        }
        .padding(10)
        .themedChrome(role: .sheetAction)
    }

    private var summary: LocalizedStringResource {
        "\(result.appliedCount) applied, \(result.dismissedCount) kept separate, \(result.staleCount) stale, \(result.conflictCount) conflicts, \(result.failedCount) failed, \(result.pendingCount) pending"
    }

    private func itemTitle(_ item: ReconciliationBatchResultItem) -> String {
        let titles = item.memberUUIDs.compactMap { booksByUUID[$0]?.displayTitle }
        return titles.isEmpty ? item.pairKey : titles.formatted()
    }

    private func outcomeTitle(
        _ outcome: ReconciliationBatchItemOutcome
    ) -> LocalizedStringResource {
        switch outcome {
        case .applied: "Applied"
        case .dismissed: "Kept separate"
        case .stale: "Stale"
        case .conflicting(.overlappingProposal): "Overlapping proposal"
        case .conflicting(.missingProposal): "Missing proposal"
        case .conflicting(.notApplicable): "Review only"
        case .conflicting(.sourceChanged): "Source changed"
        case .failed: "Failed"
        case .pending: "Pending"
        }
    }

    private func symbol(for outcome: ReconciliationBatchItemOutcome) -> String {
        switch outcome {
        case .applied, .dismissed: "checkmark.circle.fill"
        case .stale, .conflicting: "exclamationmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .pending: "clock"
        }
    }
}

private struct ReconciliationWorkspaceCommandBar: View {
    let isScanning: Bool
    let selectedCount: Int
    let hiddenSelectedCount: Int
    let visibleCount: Int
    let canApply: Bool
    let isRunning: Bool
    let onSelectAllVisible: () -> Void
    let onClearSelection: () -> Void
    let onKeepSeparate: () -> Void
    let onApply: () -> Void
    let onRescan: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            if selectedCount > 0 {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(selectedCount) Selected")
                        .font(.caption.weight(.semibold))
                    if hiddenSelectedCount > 0 {
                        Text("\(hiddenSelectedCount) hidden by filters")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Select All Visible", action: onSelectAllVisible)
                    .disabled(visibleCount == 0 || isRunning)
                Button("Clear", action: onClearSelection)
                    .disabled(isRunning)
                Button("Keep Separate Selected", action: onKeepSeparate)
                    .disabled(isRunning)
                Button("Apply Selected", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply || isRunning)
            } else {
                Text("Select proposals to apply or keep separate as a safe serial batch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rescan", action: onRescan)
                .disabled(isScanning || isRunning)
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning)
        }
        .padding(12)
        .themedChrome(role: .sheetAction)
    }
}

private struct EditionProposalSection: Identifiable {
    let verdict: EditionVerdict
    let proposals: [EditionMatchProposal]

    var id: EditionVerdict { verdict }
}

private struct EditionProposalList: View {
    let proposals: [EditionMatchProposal]
    let booksByUUID: [UUID: Book]
    @Binding var selection: Set<String>
    @Binding var focus: String?
    let isEnabled: Bool
    let onDismiss: (EditionMatchProposal) -> Void

    private var sections: [EditionProposalSection] {
        let grouped = Dictionary(grouping: proposals, by: \.verdict)
        return EditionVerdict.allCases.compactMap { verdict in
            guard let proposals = grouped[verdict], !proposals.isEmpty else { return nil }
            return EditionProposalSection(verdict: verdict, proposals: proposals)
        }
    }

    var body: some View {
        List(selection: $focus) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.proposals) { proposal in
                        EditionProposalRow(
                            proposal: proposal,
                            books: proposal.memberUUIDs.compactMap { booksByUUID[$0] },
                            isSelected: selection.contains(proposal.pairKey),
                            isEnabled: isEnabled,
                            onToggleSelection: {
                                if selection.contains(proposal.pairKey) {
                                    selection.remove(proposal.pairKey)
                                } else {
                                    selection.insert(proposal.pairKey)
                                }
                            },
                            onDismiss: { onDismiss(proposal) },
                            onFocus: { focus = proposal.pairKey }
                        )
                        .tag(proposal.pairKey)
                    }
                } header: {
                    EditionVerdictHeader(verdict: section.verdict)
                }
            }
        }
    }
}

private struct EditionVerdictHeader: View {
    let verdict: EditionVerdict

    @Environment(\.theme) private var theme

    var body: some View {
        switch verdict {
        case .duplicateFile:
            theme.styledText(terminal: "// identical_files", native: "Identical Files")
        case .sameEditionOtherFormat:
            theme.styledText(terminal: "// same_edition_other_format", native: "Same Edition, Other Format")
        case .sameWorkOtherEdition:
            theme.styledText(terminal: "// other_editions", native: "Other Editions of One Work")
        case .similarItem:
            theme.styledText(terminal: "// similar_only", native: "Similar — Review Only")
        }
    }
}

private struct ReconciliationFooter: View {
    let isScanning: Bool
    let onRescan: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack {
            Text("No bulk merge is available; review each proposal before changing the catalog.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Rescan", action: onRescan)
                .disabled(isScanning)
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .themedChrome(role: .sheetAction)
    }
}

private struct EditionProposalRow: View {
    let proposal: EditionMatchProposal
    let books: [Book]
    let isSelected: Bool
    let isEnabled: Bool
    let onToggleSelection: () -> Void
    let onDismiss: () -> Void
    let onFocus: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: Binding(
                get: { isSelected },
                set: { _ in onToggleSelection() }
            )) {
                Text("Select proposal")
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!isEnabled)
            .accessibilityLabel("Select proposal")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            HStack(spacing: -8) {
                ForEach(books) { book in
                    BookCoverImageView(book: book, tier: .thumb)
                        .frame(width: 34, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: WinstonLayout.cornerSmall))
                        .overlay {
                            RoundedRectangle(cornerRadius: WinstonLayout.cornerSmall)
                                .stroke(theme.backgroundAlt, lineWidth: 2)
                        }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(books.map(\.displayTitle).formatted())
                    .font(theme.body(size: 12, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Group {
                        if theme.usesTerminalCopy {
                            Text(verbatim: proposal.confidence.terminalLabel)
                        } else {
                            Text(proposal.confidence.label)
                        }
                    }
                    .font(theme.label(size: 9, weight: .bold))
                    .foregroundStyle(confidenceColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(confidenceColor.opacity(0.12), in: Capsule())
                    ForEach(proposal.signals, id: \.self) { signal in
                        Group {
                            if theme.usesTerminalCopy {
                                Text(verbatim: signal.terminalLabel)
                            } else {
                                Text(signal.label)
                            }
                        }
                        .font(theme.label(size: 9))
                        .foregroundStyle(theme.textSecondary)
                    }
                }
            }
            Spacer()
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.borderless)
                .disabled(!isEnabled)
            Button("View", action: onFocus)
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 5)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var confidenceColor: Color {
        switch proposal.confidence {
        case .high: theme.success
        case .likely: theme.accent
        case .uncertain: theme.highlight
        }
    }
}

private struct ReconciliationReviewSheet: View {
    let request: ReconciliationReviewRequest
    let service: CatalogReconciliationService

    @Environment(\.dismiss) private var dismiss
    @State private var applyController = ReconciliationApplyController()

    var body: some View {
        VStack(spacing: 0) {
            ReconciliationReviewHeader(proposal: request.proposal)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ReconciliationBookComparison(books: request.books)
                    ReconciliationPlanView(
                        proposal: request.proposal,
                        books: request.books,
                        survivorUUID: request.survivorUUID
                    )
                    if applyController.phase != .reviewing {
                        ReconciliationApplyStatus(phase: applyController.phase)
                    }
                }
                .padding(20)
            }
            Divider()
            ReconciliationReviewActions(
                proposal: request.proposal,
                controller: applyController,
                onClose: { dismiss() },
                onCancelOperation: applyController.cancel,
                onKeepSeparate: keepSeparate,
                onApply: apply
            )
        }
        .frame(minWidth: 620, idealWidth: 720, maxWidth: 900, minHeight: 520, idealHeight: 650)
        .interactiveDismissDisabled(applyController.blocksDismissal)
        .onChange(of: applyController.phase) { _, phase in
            guard phase == .completed else { return }
            dismiss()
        }
        .onDisappear {
            applyController.cancelIfPossible()
        }
    }

    private func keepSeparate() {
        service.dismiss(request.proposal)
        dismiss()
    }

    private func apply() {
        guard request.proposal.canApply else { return }
        applyController.start(proposal: request.proposal, service: service)
    }
}

private struct ReconciliationApplyStatus: View {
    let phase: ReconciliationApplyController.Phase

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isProgressVisible {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                statusTitle
                    .font(theme.body(size: 11, weight: .semibold))
                Text(detail)
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
        }
        .padding(12)
        .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: WinstonLayout.cornerMedium))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var statusTitle: some View {
        switch phase {
        case .reviewing:
            EmptyView()
        case .validating:
            theme.styledText(terminal: "// validating_reconciliation", native: "Validating current library state")
        case .cancelling:
            theme.styledText(terminal: "// cancelling_reconciliation", native: "Cancelling before changes are applied")
        case .committing:
            theme.styledText(terminal: "// committing_reconciliation", native: "Applying catalog and file changes")
        case .completed:
            theme.styledText(terminal: "// reconciliation_complete", native: "Reconciliation complete")
        case .cancelled:
            theme.styledText(terminal: "// reconciliation_cancelled", native: "Reconciliation cancelled")
        case .failed(.stale):
            theme.styledText(terminal: "// reconciliation_stale", native: "The proposal is no longer current")
        case .failed(.notApplicable):
            theme.styledText(terminal: "// reconciliation_not_applicable", native: "This proposal cannot be applied")
        case .failed:
            theme.styledText(terminal: "// reconciliation_failed", native: "Reconciliation could not be completed")
        }
    }

    private var detail: LocalizedStringResource {
        switch phase {
        case .reviewing:
            "Review the planned changes before continuing."
        case .validating:
            "Checking current metadata and file identities. You can still cancel."
        case .cancelling:
            "Waiting for validation work to stop. No catalog changes have started."
        case .committing:
            "This protected commit step cannot be cancelled."
        case .completed:
            "The catalog and managed files were updated."
        case .cancelled:
            "No catalog changes were applied. You can try again."
        case .failed(.stale):
            "The books changed while this review was open. Close the review and rescan."
        case .failed(.notApplicable):
            "Keep the books separate or close this review."
        case .failed:
            "The library could not save the changes. You can try again."
        }
    }

    private var accessibilityLabel: Text {
        Text(detail)
    }

    private var isProgressVisible: Bool {
        switch phase {
        case .validating, .cancelling, .committing:
            true
        case .reviewing, .completed, .cancelled, .failed:
            false
        }
    }

    private var systemImage: String {
        switch phase {
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .reviewing: "doc.text.magnifyingglass"
        case .validating, .cancelling, .committing: "clock"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch phase {
        case .completed: theme.success
        case .cancelled, .reviewing: theme.textSecondary
        case .validating, .cancelling, .committing: theme.accent
        case .failed: theme.highlight
        }
    }
}

private struct ReconciliationReviewHeader: View {
    let proposal: EditionMatchProposal

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review Reconciliation")
                .font(theme.body(size: 15, weight: .bold))
            Text(summary)
                .font(theme.label(size: 11))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var summary: LocalizedStringResource {
        switch proposal.verdict {
        case .duplicateFile: "The files have identical content hashes."
        case .sameEditionOtherFormat: "Edition identifiers match, but the files are different."
        case .sameWorkOtherEdition: "The books appear to be distinct editions of one work."
        case .similarItem: "The available evidence is too weak to merge or group these books."
        }
    }
}

private struct ReconciliationBookComparison: View {
    let books: [Book]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Books being compared")
                .font(theme.body(size: 13, weight: .semibold))
            ForEach(books) { book in
                ReconciliationBookCard(book: book)
            }
        }
    }
}

private struct ReconciliationBookCard: View {
    let book: Book

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BookCoverImageView(book: book, tier: .thumb)
                .frame(width: 42, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: WinstonLayout.cornerSmall))
            VStack(alignment: .leading, spacing: 3) {
                Text(book.displayTitle)
                    .font(theme.body(size: 12, weight: .semibold))
                Text(book.displayAuthor ?? String(localized: "Unknown author"))
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textSecondary)
                Text(metadataSummary)
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(10)
        .background(theme.backgroundAlt, in: RoundedRectangle(cornerRadius: WinstonLayout.cornerMedium))
    }

    private var metadataSummary: String {
        var values = book.assetFormats
        if let language = nonempty(book.language) { values.append(language) }
        if let translator = nonempty(book.translator) {
            values.append(String(localized: "Translator: \(translator)"))
        }
        if let isbn = nonempty(book.isbn) { values.append("ISBN \(isbn)") }
        if let publisher = nonempty(book.publisher) { values.append(publisher) }
        if let year = nonempty(book.year) { values.append(year) }
        return values.formatted()
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private struct ReconciliationPlanView: View {
    let proposal: EditionMatchProposal
    let books: [Book]
    let survivorUUID: UUID?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Planned changes")
                .font(theme.body(size: 13, weight: .semibold))
            Label(primaryPlan, systemImage: planIcon)
                .font(theme.body(size: 11, weight: .medium))
            ReconciliationPreservationRow(
                title: "Files",
                detail: filesDetail,
                systemImage: "doc.on.doc"
            )
            ReconciliationAssetPlan(
                proposal: proposal,
                books: books,
                survivorUUID: survivorUUID
            )
            ReconciliationPreservationRow(
                title: "Metadata",
                detail: metadataDetail,
                systemImage: "text.badge.checkmark"
            )
            ReconciliationPreservationRow(
                title: "Reading history",
                detail: "All \(readingSessionCount) reading sessions and the strongest status are preserved.",
                systemImage: "clock.arrow.circlepath"
            )
            ReconciliationPreservationRow(
                title: "Highlights",
                detail: "All \(highlightCount) highlights and notes are preserved.",
                systemImage: "highlighter"
            )
            ReconciliationPreservationRow(
                title: "Collections",
                detail: "Membership in \(collectionCount) collections is preserved.",
                systemImage: "folder"
            )
            if proposal.isExactContentDuplicate {
                Label(
                    "Only files whose SHA-256 hash already exists on the retained record may be deleted.",
                    systemImage: "exclamationmark.shield"
                )
                .font(theme.label(size: 10, weight: .medium))
                .foregroundStyle(.orange)
            }
        }
    }

    private var survivor: Book? {
        books.first { $0.uuid == survivorUUID }
    }

    private var primaryPlan: LocalizedStringResource {
        switch proposal.verdict {
        case .duplicateFile:
            if let survivor {
                "Merge the catalog records and keep “\(survivor.displayTitle)” as the retained record."
            } else {
                "Merge the catalog records after selecting a retained record."
            }
        case .sameEditionOtherFormat:
            "Merge the edition records while retaining every nonidentical format."
        case .sameWorkOtherEdition:
            "Keep both editions and group them under one work."
        case .similarItem:
            "Make no catalog or file changes and keep the books separate."
        }
    }

    private var planIcon: String {
        switch proposal.verdict {
        case .duplicateFile: "doc.badge.minus"
        case .sameEditionOtherFormat: "square.stack.3d.up"
        case .sameWorkOtherEdition: "books.vertical"
        case .similarItem: "eye"
        }
    }

    private var filesDetail: LocalizedStringResource {
        switch proposal.changePlan.assetPolicy {
        case .removeExactContentDuplicates:
            "Keep \(max(assetCount - removableAssetCount, 0)) unique assets and remove \(removableAssetCount) byte-identical redundant assets."
        case .retainAll:
            "Retain all \(assetCount) assets and formats."
        case .unchanged, .reviewOnly:
            "Retain all \(assetCount) assets without modification."
        }
    }

    private var metadataDetail: LocalizedStringResource {
        if proposal.changePlan.mergesEditionRecords {
            "Keep existing values on the retained record and fill only empty fields from the other record."
        } else {
            "Keep edition-specific metadata on each book unchanged."
        }
    }

    private var assetCount: Int { books.reduce(0) { $0 + $1.assets.count } }
    private var readingSessionCount: Int { books.reduce(0) { $0 + $1.readingSessions.count } }
    private var highlightCount: Int { books.reduce(0) { $0 + $1.highlights.count } }
    private var collectionCount: Int { Set(books.flatMap(\.collections).map(\.id)).count }

    private var removableAssetCount: Int {
        guard proposal.isExactContentDuplicate, let survivor else { return 0 }
        let retainedHashes = Set(survivor.assets.compactMap(\.contentHash))
        return books.lazy
            .filter { $0.uuid != survivor.uuid }
            .flatMap(\.assets)
            .count { asset in
                guard let hash = asset.contentHash else { return false }
                return retainedHashes.contains(hash)
            }
    }
}

private struct ReconciliationAssetPlan: View {
    let proposal: EditionMatchProposal
    let books: [Book]
    let survivorUUID: UUID?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(books) { book in
                ForEach(book.assets, id: \.uuid) { asset in
                    HStack(spacing: 7) {
                        Image(systemName: isRemovalCandidate(asset, in: book)
                            ? "checkmark.shield"
                            : "checkmark.circle")
                            .foregroundStyle(isRemovalCandidate(asset, in: book) ? .orange : theme.success)
                        Text(asset.fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(disposition(asset, in: book))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .font(theme.label(size: 9))
                }
            }
        }
        .padding(.leading, 26)
    }

    private var retainedHashes: Set<String> {
        guard let survivorUUID,
              let survivor = books.first(where: { $0.uuid == survivorUUID }) else { return [] }
        return Set(survivor.assets.compactMap { $0.contentHash?.lowercased() })
    }

    private func isRemovalCandidate(_ asset: BookAsset, in book: Book) -> Bool {
        guard proposal.isExactContentDuplicate,
              book.uuid != survivorUUID,
              let hash = asset.contentHash?.lowercased() else { return false }
        return retainedHashes.contains(hash)
    }

    private func disposition(_ asset: BookAsset, in book: Book) -> LocalizedStringResource {
        isRemovalCandidate(asset, in: book)
            ? "Remove only after SHA-256 revalidation"
            : "Retain"
    }
}

private struct ReconciliationPreservationRow: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let systemImage: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(theme.body(size: 11, weight: .semibold))
                Text(detail)
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }
}

private struct ReconciliationReviewActions: View {
    let proposal: EditionMatchProposal
    let controller: ReconciliationApplyController
    let onClose: () -> Void
    let onCancelOperation: () -> Void
    let onKeepSeparate: () -> Void
    let onApply: () -> Void

    var body: some View {
        HStack {
            if controller.phase == .committing {
                Text("Finishing protected changes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.canCancel {
                Button("Cancel Operation", action: onCancelOperation)
            } else if controller.phase == .cancelling {
                Button("Cancelling…", action: {})
                    .disabled(true)
            } else {
                Button("Close", action: onClose)
                    .disabled(controller.blocksDismissal)
            }
            if proposal.canApply {
                Button(actionLabel, action: onApply)
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canApply)
            } else {
                Button("Keep Separate", action: onKeepSeparate)
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isRunning)
            }
        }
        .padding(12)
    }

    private var actionLabel: LocalizedStringResource {
        if case .failed = controller.phase { return "Try Again" }
        if controller.phase == .cancelled { return "Try Again" }
        return switch proposal.verdict {
        case .duplicateFile: "Merge Identical Copies"
        case .sameEditionOtherFormat: "Merge Edition Records"
        case .sameWorkOtherEdition: "Group Editions"
        case .similarItem: "Keep Separate"
        }
    }
}
