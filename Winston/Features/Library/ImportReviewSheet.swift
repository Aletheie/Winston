import AppKit
import SwiftUI

struct ImportReviewSheet: View {
    let viewModel: LibraryViewModel
    let onShowImportedBooks: ([UUID]) -> Void
    let onReviewIssues: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var rowSelection: Set<UUID> = []
    @State private var focusedItemID: UUID?
    @State private var filter: ImportReviewFilter = .all

    private var batch: PreparedImportBatch? {
        viewModel.preparedImportBatch
    }

    private var selectedItem: PreparedImportItem? {
        guard let focusedItemID else { return visibleItems.first }
        return batch?.items.first { $0.id == focusedItemID }
    }

    private var visibleItems: [PreparedImportItem] {
        batch?.items.filter(filter.includes) ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(
            minWidth: 860,
            idealWidth: 1_040,
            maxWidth: 1_300,
            minHeight: 580,
            idealHeight: 720,
            maxHeight: .infinity
        )
        .background { ThemedBackground() }
        .interactiveDismissDisabled(batchIsActive)
        .onChange(of: batch?.items.map(\.id), initial: true) { _, ids in
            guard let ids else { return }
            rowSelection.formIntersection(ids)
            synchronizeFocus()
        }
        .onChange(of: rowSelection) { oldValue, newValue in
            let added = newValue.subtracting(oldValue)
            if let addedID = added.first {
                focusedItemID = addedID
            } else if let focusedItemID, !newValue.contains(focusedItemID) {
                self.focusedItemID = newValue.first ?? visibleItems.first?.id
            }
        }
        .onChange(of: filter) {
            synchronizeFocus()
        }
    }

    private var batchIsActive: Bool {
        guard let batch else { return false }
        return switch batch.phase {
        case .preparing, .ready, .committing: true
        case .completed, .failed: false
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                theme.styledText(
                    terminal: "// import_review",
                    native: "Review Import"
                )
                .font(theme.display(size: 22, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                Text("Confirm destinations and metadata before Winston changes your library.")
                    .font(theme.body(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer(minLength: 16)

            if let batch {
                ImportReviewCounts(batch: batch)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        if let batch {
            switch batch.phase {
            case .preparing:
                ImportReviewPreparationView(batch: batch)
            case .ready, .committing:
                VStack(spacing: 0) {
                    ImportReviewFilterBar(
                        filter: $filter,
                        visibleCount: visibleItems.count,
                        totalCount: batch.items.count,
                        selectedRowCount: rowSelection.count
                    )
                    Divider()
                    HSplitView {
                        ImportReviewTable(
                            items: visibleItems,
                            selection: $rowSelection,
                            isEnabled: batch.phase == .ready,
                            onSetSelected: viewModel.setImportReviewSelection
                        )
                        .frame(minWidth: 510)

                        if let selectedItem {
                            ImportReviewInspector(
                                item: selectedItem,
                                batchTargetIDs: rowSelection,
                                isEnabled: batch.phase == .ready,
                                onSetAction: {
                                    viewModel.setImportReviewAction(
                                        itemID: selectedItem.id,
                                        action: $0
                                    )
                                },
                                onUpdateMetadata: {
                                    viewModel.updateImportReviewMetadata(
                                        itemID: selectedItem.id,
                                        metadata: $0
                                    )
                                },
                                onApplyMetadataField: { field in
                                    viewModel.applyImportReviewMetadata(
                                        field: field,
                                        sourceItemID: selectedItem.id,
                                        targetItemIDs: rowSelection
                                    )
                                }
                            )
                            .id(selectedItem.id)
                            .frame(minWidth: 300, idealWidth: 360)
                        } else {
                            ContentUnavailableView(
                                "Select an item",
                                systemImage: "doc.text.magnifyingglass"
                            )
                            .frame(minWidth: 300, idealWidth: 360)
                        }
                    }
                }
            case .completed(let summary):
                ImportReviewResultView(
                    summary: summary,
                    items: batch.items,
                    outcomes: batch.itemOutcomes
                )
            case .failed(let message):
                ContentUnavailableView {
                    Label("Import preparation failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let batch {
            HStack(spacing: 8) {
                switch batch.phase {
                case .preparing:
                    ProgressView(
                        value: Double(batch.completedPreparationCount),
                        total: Double(max(1, batch.requestedCount))
                    )
                    .frame(width: 150)
                    Text("Inspecting \(batch.completedPreparationCount) of \(batch.requestedCount)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        viewModel.cancelImportReview()
                    }
                    .keyboardShortcut(.cancelAction)

                case .ready:
                    Text("\(rowSelection.count) rows selected for batch decisions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Select All Visible") {
                        rowSelection.formUnion(visibleItems.map(\.id))
                    }
                    Button("Clear Row Selection") {
                        rowSelection.removeAll()
                    }
                    Menu("Inclusion") {
                        Button("Include All Visible") {
                            viewModel.setImportReviewSelections(
                                itemIDs: Set(visibleItems.map(\.id)),
                                isSelected: true
                            )
                        }
                        Button("Exclude All Visible") {
                            viewModel.setImportReviewSelections(
                                itemIDs: Set(visibleItems.map(\.id)),
                                isSelected: false
                            )
                        }
                    }
                    Menu("Set Decision") {
                        Button("Skip Selected Rows") {
                            viewModel.setImportReviewActions(
                                itemIDs: rowSelection,
                                action: .skip
                            )
                        }
                        Button("Import Selected Rows as New Works") {
                            viewModel.setImportReviewActions(
                                itemIDs: rowSelection,
                                action: .createNewWork
                            )
                        }
                    }
                    .disabled(rowSelection.isEmpty)
                    Spacer()
                    Button("Cancel") {
                        viewModel.cancelImportReview()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Import \(batch.selectedCount) Selected") {
                        viewModel.commitImportReview()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!batch.canCommit)

                case .committing:
                    if let progress = viewModel.standardImportProgress,
                       progress.sessionID == batch.sessionID {
                        ProgressView(value: progress.fraction)
                            .frame(width: 160)
                            .accessibilityLabel("Import commit progress")
                            .accessibilityValue(
                                "\(progress.completedCount) of \(progress.requestedCount) files"
                            )
                        Text(commitProgressTitle(progress))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing the approved import…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") {
                        viewModel.cancelImportReview()
                    }
                    .keyboardShortcut(.cancelAction)

                case .completed(let summary):
                    if summary.hasIssues {
                        Button("Retry Failed…") {
                            closeResult()
                            onReviewIssues()
                        }
                    }
                    Spacer()
                    if !summary.importedBookIDs.isEmpty {
                        Button("Show Imported Books") {
                            let ids = summary.importedBookIDs
                            closeResult()
                            onShowImportedBooks(ids)
                        }
                    }
                    Button("Done") {
                        closeResult()
                    }
                    .keyboardShortcut(.defaultAction)

                case .failed:
                    if !viewModel.importRecoveryItems.isEmpty {
                        Button("Retry Failed…") {
                            closeResult()
                            onReviewIssues()
                        }
                    }
                    Spacer()
                    Button("Close") {
                        closeResult()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func closeResult() {
        viewModel.dismissImportReviewResult()
        dismiss()
    }

    private func synchronizeFocus() {
        let visibleIDs = Set(visibleItems.map(\.id))
        if let focusedItemID, visibleIDs.contains(focusedItemID) { return }
        focusedItemID = visibleItems.first?.id
    }

    private func commitProgressTitle(_ progress: ImportSessionProgress) -> String {
        if progress.isCancelling {
            return String(localized: "Cancelling after the current safe import boundary…")
        }
        if let filename = progress.currentFilename {
            return String(
                localized: "Importing \(progress.completedCount) of \(progress.requestedCount): \(filename)…"
            )
        }
        return String(
            localized: "Importing \(progress.completedCount) of \(progress.requestedCount)…"
        )
    }
}

private struct ImportReviewCounts: View {
    let batch: PreparedImportBatch

    var body: some View {
        HStack(spacing: 6) {
            if batch.reviewCount > 0 {
                Label("\(batch.reviewCount) need decisions", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
            }
            if batch.blockedCount > 0 {
                Label("\(batch.blockedCount) unavailable", systemImage: "nosign")
                    .foregroundStyle(.red)
            }
            Text("\(batch.selectedCount) selected")
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .combine)
    }
}

private struct ImportReviewPreparationView: View {
    let batch: PreparedImportBatch

    var body: some View {
        VStack(spacing: 14) {
            ProgressView(
                value: Double(batch.completedPreparationCount),
                total: Double(max(1, batch.requestedCount))
            )
            .controlSize(.large)
            .frame(width: 280)
            Text("Inspecting files and comparing them with the library…")
                .font(.headline)
            Text("No books or managed-library files are created during this step.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImportReviewFilterBar: View {
    @Binding var filter: ImportReviewFilter
    let visibleCount: Int
    let totalCount: Int
    let selectedRowCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Picker("Import review filter", selection: $filter) {
                ForEach(ImportReviewFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            .accessibilityLabel("Import review filter")
            Text("Showing \(visibleCount) of \(totalCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if selectedRowCount > 0 {
                Text("\(selectedRowCount) rows selected")
                    .font(.caption.weight(.semibold))
            }
            Spacer()
            Label("Checkbox controls inclusion", systemImage: "checkmark.square")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHint("Row selection controls batch decisions; checkboxes control which files will be imported.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ImportReviewTable: View {
    let items: [PreparedImportItem]
    @Binding var selection: Set<UUID>
    let isEnabled: Bool
    let onSetSelected: (UUID, Bool) -> Void

    var body: some View {
        Table(items, selection: $selection) {
            TableColumn("") { item in
                Toggle(
                    "Import \(item.sourceName)",
                    isOn: Binding(
                        get: { item.isSelected },
                        set: { onSetSelected(item.id, $0) }
                    )
                )
                .labelsHidden()
                .disabled(!isEnabled || !item.isSelectable || !item.action.importsFile)
            }
            .width(34)

            TableColumn("Title") { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.metadata.title?.nonemptyImportValue ?? item.sourceName)
                        .lineLimit(1)
                    if let author = item.metadata.author?.nonemptyImportValue {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 180, ideal: 240)

            TableColumn("Format") { item in
                Text(item.format.uppercased())
                    .font(.caption.monospaced())
            }
            .width(62)

            TableColumn("Size") { item in
                Text(
                    item.sizeBytes > 0
                        ? ByteCountFormatter.string(
                            fromByteCount: item.sizeBytes,
                            countStyle: .file
                        )
                        : "—"
                )
                .font(.caption.monospacedDigit())
            }
            .width(80)

            TableColumn("Action") { item in
                Label(
                    item.action.importReviewLabel,
                    systemImage: item.importReviewSystemImage
                )
                .font(.caption)
                .foregroundStyle(item.isSelectable ? .primary : .secondary)
                .lineLimit(1)
            }
            .width(min: 120, ideal: 155)
        }
        .disabled(!isEnabled)
        .accessibilityLabel("Files to review before import")
        .onKeyPress(.space) {
            guard isEnabled,
                  let itemID = selection.first,
                  let item = items.first(where: { $0.id == itemID }),
                  item.isSelectable,
                  item.action.importsFile else {
                return .ignored
            }
            onSetSelected(item.id, !item.isSelected)
            return .handled
        }
    }
}

private struct ImportReviewInspector: View {
    let item: PreparedImportItem
    let batchTargetIDs: Set<UUID>
    let isEnabled: Bool
    let onSetAction: (ImportReviewAction) -> Void
    let onUpdateMetadata: (BookMetadata) -> Void
    let onApplyMetadataField: (ImportReviewMetadataField) -> Void

    @Environment(\.theme) private var theme
    @State private var metadata = BookMetadata()
    @State private var loadedItemID: UUID?
    @State private var pendingBatchField: ImportReviewMetadataField?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cover
                sourceDetails
                catalogSource
                actionPicker
                evidence
                metadataEditor
                batchMetadataActions
            }
            .padding(18)
        }
        .task(id: item.id) {
            metadata = item.metadata
            loadedItemID = item.id
        }
        .onChange(of: metadata) {
            guard loadedItemID == item.id else { return }
            onUpdateMetadata(metadata)
        }
        .confirmationDialog(
            "Overwrite Metadata Field?",
            isPresented: Binding(
                get: { pendingBatchField != nil },
                set: { if !$0 { pendingBatchField = nil } }
            )
        ) {
            if let field = pendingBatchField {
                Button(
                    "Apply \(String(localized: field.label)) to \(batchTargetIDs.count) Rows"
                ) {
                    onApplyMetadataField(field)
                    pendingBatchField = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingBatchField = nil
            }
        } message: {
            if let field = pendingBatchField {
                Text(
                    "The \(String(localized: field.label).lowercased()) from this focused file will replace that field on every selected row. Other metadata fields stay unchanged."
                )
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let data = item.coverPreviewJPEGData,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Cover preview")
        }
    }

    private var sourceDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.sourceName)
                .font(.headline)
                .textSelection(.enabled)
            Text(item.sourceURL.path(percentEncoded: false))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let sha256 = item.sha256 {
                Text("SHA-256 \(sha256)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var catalogSource: some View {
        if let context = item.catalogContext {
            VStack(alignment: .leading, spacing: 8) {
                Text("Catalog proposal")
                    .font(.subheadline.weight(.semibold))
                LabeledContent("Source", value: context.catalogName)
                if let attribution = context.attribution {
                    LabeledContent(
                        "Attribution",
                        value: attribution
                    )
                }
                if !context.contributors.isEmpty {
                    LabeledContent(
                        "Contributors",
                        value: context.contributors.joined(separator: ", ")
                    )
                }
                Link("Open Source", destination: context.sourceURL)
                LabeledContent(
                    "Selected format",
                    value: context.selectedFormat
                )
                LabeledContent(
                    "Acquisition",
                    value: context.acquisitionRelation.localizedLabel
                )
                if item.catalogMetadataDifferences.isEmpty {
                    Text("The catalog proposal agrees with the extracted file metadata.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The extracted file metadata remains authoritative. Review these differences before importing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(item.catalogMetadataDifferences) { difference in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: difference.field)
                                .font(.caption.weight(.semibold))
                            Text(
                                "Catalog: \(difference.catalogValue)"
                            )
                            .font(.caption)
                            Text(
                                "File: \(difference.extractedValue ?? String(localized: "Not provided"))"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(10)
            .background(
                theme.surface.opacity(0.7),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
    }

    private var actionPicker: some View {
        Picker(
            "Import as",
            selection: Binding(
                get: { item.action },
                set: { action in onSetAction(action) }
            )
        ) {
            Text("Skip").tag(ImportReviewAction.skip)
            Text("New work").tag(ImportReviewAction.createNewWork)
            ForEach(item.workTargets) { work in
                Text("New edition of \(work.title)")
                    .tag(ImportReviewAction.createEdition(workID: work.id))
                ForEach(work.editions) { edition in
                    Text("Add format to \(edition.title)")
                        .tag(
                            ImportReviewAction.addFormat(
                                bookID: edition.id,
                                workID: edition.workID
                            )
                        )
                }
            }
        }
        .disabled(!isEnabled || !item.isSelectable)
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.reasons.isEmpty {
                Text("Why Winston suggested this")
                    .font(.subheadline.weight(.semibold))
                ForEach(item.reasons, id: \.self) {
                    Label($0, systemImage: "checkmark.circle")
                        .font(.caption)
                }
            }
            ForEach(item.warnings, id: \.self) {
                Label($0, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var metadataEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata")
                .font(.subheadline.weight(.semibold))
            TextField("Title", text: optional(\.title))
            TextField("Author", text: optional(\.author))
            TextField("Publisher", text: optional(\.publisher))
            HStack {
                TextField("Year", text: optional(\.year))
                TextField("Language", text: optional(\.language))
            }
            TextField("ISBN", text: optional(\.isbn))
            HStack {
                TextField("Series", text: optional(\.series))
                TextField("Index", text: optional(\.seriesIndex))
                    .frame(width: 70)
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(!isEnabled || !item.isSelectable)
    }

    @ViewBuilder
    private var batchMetadataActions: some View {
        if !batchTargetIDs.isEmpty {
            Menu {
                ForEach(ImportReviewMetadataField.allCases) { field in
                    Button("Apply \(String(localized: field.label))") {
                        pendingBatchField = field
                    }
                }
            } label: {
                Label(
                    "Apply One Field to \(batchTargetIDs.count) Selected Rows…",
                    systemImage: "rectangle.stack.badge.plus"
                )
            }
            .disabled(!isEnabled || !item.isSelectable)
            Text("Choose one field explicitly; heterogeneous metadata is never overwritten as a group.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func optional(
        _ keyPath: WritableKeyPath<BookMetadata, String?>
    ) -> Binding<String> {
        Binding(
            get: { metadata[keyPath: keyPath] ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                metadata[keyPath: keyPath] = trimmed.isEmpty ? nil : $0
            }
        )
    }
}

private struct ImportReviewResultView: View {
    let summary: ImportSummary
    let items: [PreparedImportItem]
    let outcomes: [UUID: ImportReviewItemOutcome]

    var body: some View {
        VStack(spacing: 14) {
            ContentUnavailableView {
                Label(
                    summary.hasIssues ? "Import completed with issues" : "Import complete",
                    systemImage: summary.hasIssues
                        ? "exclamationmark.circle"
                        : "checkmark.circle"
                )
            } description: {
                Text(ImportSummaryPresentation(summary: summary).message)
            }
            .frame(maxWidth: .infinity)

            if !outcomes.isEmpty {
                List(items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: outcomeSymbol(outcomes[item.id]))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.sourceName)
                                .lineLimit(1)
                            Text(outcomeLabel(outcomes[item.id]))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                }
                .frame(maxWidth: 720, maxHeight: 280)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func outcomeLabel(
        _ outcome: ImportReviewItemOutcome?
    ) -> LocalizedStringResource {
        switch outcome {
        case .imported: "Imported"
        case .skipped: "Skipped"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case nil: "Not processed"
        }
    }

    private func outcomeSymbol(_ outcome: ImportReviewItemOutcome?) -> String {
        switch outcome {
        case .imported: "checkmark.circle.fill"
        case .skipped: "forward.end.circle"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "pause.circle.fill"
        case nil: "questionmark.circle"
        }
    }
}

private extension PreparedImportItem {
    var importReviewSystemImage: String {
        if !isSelectable { return "nosign" }
        if !warnings.isEmpty { return "exclamationmark.triangle" }
        return switch action {
        case .skip: "forward.end"
        case .createNewWork: "book.closed"
        case .createEdition: "books.vertical"
        case .addFormat: "doc.badge.plus"
        }
    }
}

private extension ImportReviewAction {
    var importReviewLabel: String {
        switch self {
        case .skip: String(localized: "Skip")
        case .createNewWork: String(localized: "New work")
        case .createEdition: String(localized: "New edition")
        case .addFormat: String(localized: "Add format")
        }
    }
}

private extension String {
    var nonemptyImportValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
