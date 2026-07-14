import SwiftUI

struct EditionReviewSheet: View {
    let books: [Book]
    let service: EditionService

    @Environment(\.dismiss) private var dismiss
    @State private var booksByUUID: [UUID: Book] = [:]
    @State private var isScanning = false

    var body: some View {
        let proposals = service.pendingProposals

        VStack(spacing: 0) {
            EditionReviewHeader(isScanning: isScanning)
            Divider()
            if proposals.isEmpty, !isScanning {
                EditionReviewEmptyState()
            } else {
                EditionProposalList(
                    proposals: proposals,
                    booksByUUID: booksByUUID,
                    service: service
                )
            }
            Divider()
            EditionReviewFooter(
                exactProposals: proposals.filter { $0.confidence == .high },
                isScanning: isScanning,
                service: service,
                onRescan: { Task { await scan() } },
                onDone: { dismiss() }
            )
        }
        .frame(minWidth: 620, idealWidth: 760, maxWidth: 1050, minHeight: 560, idealHeight: 720)
        .onChange(of: LibraryMutationLog.shared.revision, initial: true) {
            rebuildBookIndex()
        }
        .task { await scan() }
    }

    private func rebuildBookIndex() {
        booksByUUID = Dictionary(books.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func scan() async {
        guard !isScanning else { return }
        isScanning = true
        await service.scanLibrary()
        isScanning = false
    }
}

private struct EditionReviewHeader: View {
    let isScanning: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.usesTerminalCopy ? "// edition_review" : "Edition Suggestions")
                    .font(theme.body(size: 15, weight: .bold))
                Text("Winston proposes groupings; nothing is merged without your approval.")
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

private struct EditionReviewEmptyState: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ContentUnavailableView {
            Label(
                theme.usesTerminalCopy ? "// no_suggestions" : "No edition suggestions",
                systemImage: "checkmark.circle"
            )
        } description: {
            Text("New imports and library scans will appear here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EditionProposalList: View {
    let proposals: [EditionMatchProposal]
    let booksByUUID: [UUID: Book]
    let service: EditionService

    private var groupedProposals: [EditionVerdict: [EditionMatchProposal]] {
        Dictionary(grouping: proposals, by: \.verdict)
    }

    var body: some View {
        List {
            ForEach(EditionVerdict.allCases, id: \.self) { verdict in
                if let matches = groupedProposals[verdict], !matches.isEmpty {
                    Section {
                        ForEach(matches) { proposal in
                            EditionProposalRow(
                                proposal: proposal,
                                books: proposal.memberUUIDs.compactMap { booksByUUID[$0] },
                                service: service
                            )
                        }
                    } header: {
                        EditionVerdictHeader(verdict: verdict, proposals: matches, service: service)
                    }
                }
            }
        }
    }
}

private struct EditionVerdictHeader: View {
    let verdict: EditionVerdict
    let proposals: [EditionMatchProposal]
    let service: EditionService

    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            switch verdict {
            case .duplicateFile:
                theme.styledText(terminal: "// duplicate_files", native: "Duplicate Files")
            case .sameEditionOtherFormat:
                theme.styledText(terminal: "// same_edition_other_format", native: "Same Edition, Other Format")
            case .sameWorkOtherEdition:
                theme.styledText(terminal: "// other_editions", native: "Other Editions of One Work")
            }
            Spacer()
            Button("Approve Group") {
                for proposal in proposals { _ = service.approve(proposal) }
            }
            .buttonStyle(.borderless)
            Button("Dismiss Group") { service.dismiss(proposals) }
                .buttonStyle(.borderless)
        }
    }
}

private struct EditionReviewFooter: View {
    let exactProposals: [EditionMatchProposal]
    let isScanning: Bool
    let service: EditionService
    let onRescan: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack {
            Button("Approve All Exact Matches") {
                for proposal in exactProposals { _ = service.approve(proposal) }
            }
            .disabled(exactProposals.isEmpty)
            Spacer()
            Button("Rescan", action: onRescan)
                .disabled(isScanning)
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}

private struct EditionProposalRow: View {
    let proposal: EditionMatchProposal
    let books: [Book]
    let service: EditionService

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: -8) {
                ForEach(books) { book in
                    BookCoverImageView(book: book, tier: .thumb)
                        .frame(width: 34, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(theme.backgroundAlt, lineWidth: 2)
                        }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(books.map(\.displayTitle).joined(separator: " ↔ "))
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
            Button("Dismiss") { service.dismiss(proposal) }
                .buttonStyle(.borderless)
            Button("Approve") { _ = service.approve(proposal) }
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 5)
    }

    private var confidenceColor: Color {
        switch proposal.confidence {
        case .high: theme.success
        case .likely: theme.accent
        case .uncertain: theme.highlight
        }
    }
}
