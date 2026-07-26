import SwiftUI

extension Array where Element == String {
    func uniquedSorted() -> [String] {
        Array(Set(self)).sorted()
    }
}

nonisolated enum TagMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case add, replace
    var id: Self { self }
    var label: String {
        self == .add ? String(localized: "Add to existing", comment: "Bulk-edit tag mode")
                     : String(localized: "Replace", comment: "Bulk-edit tag mode")
    }
}

nonisolated struct BulkEdit: Hashable, Sendable {
    var author: String?
    var authorIdentityScope: EditionIdentityScope = .editionOnly
    var publisher: String?
    var year: String?
    var series: String?
    var language: String?
    var translator: String?
    var tags: [String]?
    var tagMode: TagMode = .add
    var status: ReadingStatus?
}

struct BulkEditSheet: View {
    let bookIDs: Set<UUID>
    let viewModel: LibraryViewModel
    let onApply: (BulkEdit) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var plan: BulkOperationPlan?
    @State private var applyAuthor = false
    @State private var author = ""
    @State private var authorIdentityScope: EditionIdentityScope = .editionOnly
    @State private var applyPublisher = false
    @State private var publisher = ""
    @State private var applyYear = false
    @State private var year = ""
    @State private var applySeries = false
    @State private var series = ""
    @State private var applyLanguage = false
    @State private var language = ""
    @State private var applyTranslator = false
    @State private var translator = ""
    @State private var applyTags = false
    @State private var tags = ""
    @State private var tagMode: TagMode = .add
    @State private var applyStatus = false
    @State private var status: ReadingStatus = .unread
    @State private var seriesSuggestions: [String] = []

    var body: some View {
        Form {
            BulkOperationPlanSummary(
                selectedCount: bookIDs.count,
                hasChanges: hasChanges,
                plan: plan
            )

            Section("Fields") {
                bulkRow("Author", isOn: $applyAuthor) { TextField("Author", text: $author) }
                if applyAuthor {
                    Picker("Author scope", selection: $authorIdentityScope) {
                        Text("Selected editions").tag(EditionIdentityScope.editionOnly)
                        Text("Works").tag(EditionIdentityScope.workIdentity)
                        Text("All grouped editions").tag(EditionIdentityScope.allEditions)
                    }
                    .pickerStyle(.segmented)
                    Text("Choose whether the author correction belongs only to the selected editions or also to their shared works.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                bulkRow("Publisher", isOn: $applyPublisher) { TextField("Publisher", text: $publisher) }
                bulkRow("Year", isOn: $applyYear) { TextField("Year", text: $year) }
                bulkRow("Series", isOn: $applySeries) {
                    HStack(spacing: 4) {
                        TextField("Series", text: $series)
                            .seriesAutocomplete(text: $series, suggestions: seriesSuggestions)
                        SeriesSuggestionMenu(text: $series, suggestions: seriesSuggestions)
                    }
                }
                bulkRow("Language", isOn: $applyLanguage) { TextField("Language", text: $language) }
                bulkRow("Translator", isOn: $applyTranslator) { TextField("Translator", text: $translator) }
                bulkRow("Status", isOn: $applyStatus) {
                    Picker("", selection: $status) {
                        ForEach(ReadingStatus.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
            }

            Section("Tags") {
                Toggle("Change tags", isOn: $applyTags)
                if applyTags {
                    Picker("Mode", selection: $tagMode) {
                        ForEach(TagMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Comma-separated tags", text: $tags)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 600)
        .frame(maxHeight: 560)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges || (plan?.affectedTargetCount ?? 0) == 0)
            }
            .padding()
            .background(.bar)
        }
        .task {
            let suggestions = await viewModel.seriesSuggestions()
            guard !Task.isCancelled else { return }
            seriesSuggestions = suggestions
        }
        .task(id: previewEdit) {
            guard let edit = previewEdit else {
                plan = nil
                return
            }
            plan = nil
            let proposedPlan = await viewModel.planBulkUpdate(
                bookIDs: bookIDs,
                edit: edit
            )
            guard !Task.isCancelled, previewEdit == edit else { return }
            plan = proposedPlan
        }
    }

    @ViewBuilder
    private func bulkRow<Content: View>(_ label: LocalizedStringKey, isOn: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Toggle(label, isOn: isOn)
                .toggleStyle(.checkbox)
                .frame(width: 110, alignment: .leading)
            content()
                .disabled(!isOn.wrappedValue)
        }
    }

    private var hasChanges: Bool {
        applyAuthor || applyPublisher || applyYear || applySeries || applyLanguage || applyTranslator || applyStatus || applyTags
    }

    private var previewEdit: BulkEdit? {
        hasChanges ? makeEdit() : nil
    }

    private func makeEdit() -> BulkEdit {
        var edit = BulkEdit()
        if applyAuthor {
            edit.author = author
            edit.authorIdentityScope = authorIdentityScope
        }
        if applyPublisher { edit.publisher = publisher }
        if applyYear { edit.year = year }
        if applySeries { edit.series = series }
        if applyLanguage { edit.language = language }
        if applyTranslator { edit.translator = translator }
        if applyStatus { edit.status = status }
        if applyTags {
            edit.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            edit.tagMode = tagMode
        }
        return edit
    }

    private func apply() {
        let edit = makeEdit()
        onApply(edit)
        dismiss()
    }
}

private struct BulkOperationPlanSummary: View {
    let selectedCount: Int
    let hasChanges: Bool
    let plan: BulkOperationPlan?

    var body: some View {
        Section {
            if !hasChanges {
                Text("Select the fields to change for \(selectedCount) books.")
                    .foregroundStyle(.secondary)
            } else if let plan {
                Text("\(plan.affectedTargetCount) books will change.")
                if plan.conflictCount > 0 || plan.unchangedTargetCount > 0 {
                    Text(
                        "\(plan.conflictCount) conflicts, \(plan.unchangedTargetCount) unchanged."
                    )
                    .foregroundStyle(
                        plan.conflictCount > 0 ? Color.orange : Color.secondary
                    )
                }
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Validating selected books\u{2026}")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Only switched-on fields are changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
