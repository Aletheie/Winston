import SwiftUI

struct EditionReviewSheet: View {
    let books: [Book]
    let service: CatalogReconciliationService

    @Environment(\.dismiss) private var dismiss
    @State private var booksByUUID: [UUID: Book] = [:]
    @State private var isScanning = false
    @State private var reviewRequest: ReconciliationReviewRequest?

    var body: some View {
        let proposals = service.pendingProposals

        VStack(spacing: 0) {
            ReconciliationHeader(isScanning: isScanning)
            Divider()
            if proposals.isEmpty, !isScanning {
                ReconciliationEmptyState()
            } else {
                EditionProposalList(
                    proposals: proposals,
                    booksByUUID: booksByUUID,
                    onDismiss: service.dismiss,
                    onReview: openReview
                )
            }
            Divider()
            ReconciliationFooter(
                isScanning: isScanning,
                onRescan: { Task { await scan() } },
                onDone: { dismiss() }
            )
        }
        .frame(minWidth: 620, idealWidth: 760, maxWidth: 1050, minHeight: 560, idealHeight: 720)
        .onChange(of: LibraryMutationLog.shared.revision, initial: true) {
            rebuildBookIndex()
        }
        .task { await scan() }
        .sheet(item: $reviewRequest) { request in
            ReconciliationReviewSheet(request: request, service: service)
        }
    }

    private func rebuildBookIndex() {
        booksByUUID = Dictionary(books.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func openReview(_ proposal: EditionMatchProposal) {
        let members = proposal.memberUUIDs.compactMap { booksByUUID[$0] }
        guard members.count == proposal.memberUUIDs.count else { return }
        reviewRequest = ReconciliationReviewRequest(
            proposal: proposal,
            books: members,
            survivorUUID: service.mergeSurvivor(among: members)?.uuid
        )
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

private struct EditionProposalSection: Identifiable {
    let verdict: EditionVerdict
    let proposals: [EditionMatchProposal]

    var id: EditionVerdict { verdict }
}

private struct EditionProposalList: View {
    let proposals: [EditionMatchProposal]
    let booksByUUID: [UUID: Book]
    let onDismiss: (EditionMatchProposal) -> Void
    let onReview: (EditionMatchProposal) -> Void

    private var sections: [EditionProposalSection] {
        let grouped = Dictionary(grouping: proposals, by: \.verdict)
        return EditionVerdict.allCases.compactMap { verdict in
            guard let proposals = grouped[verdict], !proposals.isEmpty else { return nil }
            return EditionProposalSection(verdict: verdict, proposals: proposals)
        }
    }

    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.proposals) { proposal in
                        EditionProposalRow(
                            proposal: proposal,
                            books: proposal.memberUUIDs.compactMap { booksByUUID[$0] },
                            onDismiss: { onDismiss(proposal) },
                            onReview: { onReview(proposal) }
                        )
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
    }
}

private struct EditionProposalRow: View {
    let proposal: EditionMatchProposal
    let books: [Book]
    let onDismiss: () -> Void
    let onReview: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
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
            Button("Review", action: onReview)
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

private struct ReconciliationReviewSheet: View {
    let request: ReconciliationReviewRequest
    let service: CatalogReconciliationService

    @Environment(\.dismiss) private var dismiss
    @State private var isApplying = false
    @State private var applyFailed = false

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
                    if applyFailed {
                        Label(
                            "The books changed while this proposal was open, or the library could not save. Rescan before trying again.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }
            Divider()
            ReconciliationReviewActions(
                proposal: request.proposal,
                isApplying: isApplying,
                onCancel: { dismiss() },
                onKeepSeparate: keepSeparate,
                onApply: apply
            )
        }
        .frame(minWidth: 620, idealWidth: 720, maxWidth: 900, minHeight: 520, idealHeight: 650)
    }

    private func keepSeparate() {
        service.dismiss(request.proposal)
        dismiss()
    }

    private func apply() {
        guard request.proposal.canApply, !isApplying else { return }
        isApplying = true
        applyFailed = false
        Task {
            let succeeded = await service.approve(request.proposal)
            isApplying = false
            if succeeded {
                dismiss()
            } else {
                applyFailed = true
            }
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
    let isApplying: Bool
    let onCancel: () -> Void
    let onKeepSeparate: () -> Void
    let onApply: () -> Void

    var body: some View {
        HStack {
            if isApplying {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button("Cancel", action: onCancel)
            if proposal.canApply {
                Button(actionLabel, action: onApply)
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying)
            } else {
                Button("Keep Separate", action: onKeepSeparate)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }

    private var actionLabel: LocalizedStringResource {
        switch proposal.verdict {
        case .duplicateFile: "Merge Identical Copies"
        case .sameEditionOtherFormat: "Merge Edition Records"
        case .sameWorkOtherEdition: "Group Editions"
        case .similarItem: "Keep Separate"
        }
    }
}
