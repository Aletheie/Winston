import Observation
import SwiftData
import SwiftUI

nonisolated struct SmartShelfEditorRequest: Identifiable, Sendable {
    let id = UUID()
    let collectionID: UUID?
    let initialName: String
    let initialDefinition: SmartShelfDefinition

    var isEditing: Bool { collectionID != nil }

    static func create() -> SmartShelfEditorRequest {
        SmartShelfEditorRequest(
            collectionID: nil,
            initialName: "",
            initialDefinition: SmartShelfPreset.unread.definition
        )
    }

    static func edit(_ collection: BookCollection) -> SmartShelfEditorRequest? {
        guard let definition = collection.smartShelfDefinition else { return nil }
        return SmartShelfEditorRequest(
            collectionID: collection.id,
            initialName: collection.name,
            initialDefinition: definition
        )
    }
}

@MainActor
@Observable
private final class SmartShelfEditorModel {
    var name: String
    var definition: SmartShelfDefinition
    private(set) var previewBooks: [Book] = []
    private(set) var previewCount = 0

    init(request: SmartShelfEditorRequest) {
        name = request.initialName
        definition = request.initialDefinition
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && definition.isValid
    }

    func addRule() {
        definition.rules.append(SmartShelfRule())
    }

    func removeRule(id: UUID) {
        definition.rules.removeAll { $0.id == id }
    }

    func apply(_ preset: SmartShelfPreset) {
        definition = preset.definition
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = String(localized: preset.label)
        }
    }

    func refreshPreview(
        books: [Book],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) {
        let matching = LibraryQuery.applySmartShelf(
            to: books,
            definition: definition,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected,
            sort: []
        )
        previewCount = matching.count
        previewBooks = Array(matching.prefix(10))
    }
}

struct SmartShelfEditorSheet: View {
    let request: SmartShelfEditorRequest
    let books: [Book]
    let formats: [String]
    let deviceFileNames: Set<String>
    let deviceIsConnected: Bool
    let onSave: (String, SmartShelfDefinition) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var model: SmartShelfEditorModel

    init(
        request: SmartShelfEditorRequest,
        books: [Book],
        formats: [String],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool,
        onSave: @escaping (String, SmartShelfDefinition) -> Bool
    ) {
        self.request = request
        self.books = books
        self.formats = formats
        self.deviceFileNames = deviceFileNames
        self.deviceIsConnected = deviceIsConnected
        self.onSave = onSave
        _model = State(initialValue: SmartShelfEditorModel(request: request))
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            SmartShelfEditorHeader(isEditing: request.isEditing)
            Divider()
            HSplitView {
                SmartShelfRulesPane(
                    name: $model.name,
                    definition: $model.definition,
                    formats: formats,
                    onAddRule: model.addRule,
                    onRemoveRule: model.removeRule,
                    onApplyPreset: model.apply
                )
                .frame(minWidth: 440, idealWidth: 520)

                SmartShelfPreviewPane(
                    matchCount: model.previewCount,
                    books: model.previewBooks,
                    usesDeviceRule: model.definition.rules.contains { $0.field == .onDevice },
                    deviceIsConnected: deviceIsConnected
                )
                .frame(minWidth: 280, idealWidth: 340)
            }
            Divider()
            SmartShelfEditorFooter(
                isEditing: request.isEditing,
                canSave: model.canSave,
                onCancel: { dismiss() },
                onSave: save
            )
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 540, idealHeight: 640)
        .background { ThemedBackground() }
        .task(id: previewRevision) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            model.refreshPreview(
                books: books,
                deviceFileNames: deviceFileNames,
                deviceIsConnected: deviceIsConnected
            )
        }
    }

    private var previewRevision: SmartShelfPreviewRevision {
        SmartShelfPreviewRevision(
            definition: model.definition,
            libraryRevision: LibraryMutationLog.shared.revision,
            bookCount: books.count,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected
        )
    }

    private func save() {
        guard model.canSave else { return }
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let definition = model.definition
        if onSave(name, definition) {
            dismiss()
        }
    }
}

private struct SmartShelfPreviewRevision: Hashable {
    let definition: SmartShelfDefinition
    let libraryRevision: Int
    let bookCount: Int
    let deviceFileNames: Set<String>
    let deviceIsConnected: Bool
}

private struct SmartShelfEditorHeader: View {
    let isEditing: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(theme.display(size: 20, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                Text("Build a shelf that updates when your library or Kindle changes.")
                    .font(theme.body(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    private var title: LocalizedStringResource {
        isEditing ? "Edit Smart Shelf" : "New Smart Shelf"
    }
}

private struct SmartShelfRulesPane: View {
    @Binding var name: String
    @Binding var definition: SmartShelfDefinition
    let formats: [String]
    let onAddRule: () -> Void
    let onRemoveRule: (UUID) -> Void
    let onApplyPreset: (SmartShelfPreset) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SmartShelfNameSection(name: $name)
                Divider()
                SmartShelfRuleBuilder(
                    definition: $definition,
                    formats: availableFormats,
                    onAddRule: onAddRule,
                    onRemoveRule: onRemoveRule,
                    onApplyPreset: onApplyPreset
                )
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.backgroundAlt.opacity(0.28))
    }

    private var availableFormats: [String] {
        Array(Set(formats + ["EPUB", "PDF", "MOBI", "AZW3", "AZW"])).sorted()
    }
}

private struct SmartShelfNameSection: View {
    @Binding var name: String

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Shelf name")
                .font(theme.label(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            TextField("For example: Short Czech books", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(theme.body(size: 13))
        }
    }
}

private struct SmartShelfRuleBuilder: View {
    @Binding var definition: SmartShelfDefinition
    let formats: [String]
    let onAddRule: () -> Void
    let onRemoveRule: (UUID) -> Void
    let onApplyPreset: (SmartShelfPreset) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rules")
                        .font(theme.body(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Choose whether every rule or at least one rule must match.")
                        .font(theme.label(size: 10))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Menu {
                    ForEach(SmartShelfPreset.allCases) { preset in
                        Button {
                            onApplyPreset(preset)
                        } label: {
                            Label {
                                Text(preset.label)
                            } icon: {
                                Image(systemName: preset.systemImage)
                            }
                        }
                    }
                } label: {
                    Label("Use Preset", systemImage: "wand.and.stars")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Picker("Match", selection: $definition.matchMode) {
                ForEach(SmartShelfDefinition.MatchMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 230)

            if definition.rules.isEmpty {
                ContentUnavailableView {
                    Label("No Rules", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Add at least one rule to define this shelf.")
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                VStack(spacing: 8) {
                    ForEach($definition.rules) { $rule in
                        SmartShelfRuleRow(
                            rule: $rule,
                            formats: formats,
                            onDelete: { onRemoveRule(rule.id) }
                        )
                    }
                }
            }

            Button(action: onAddRule) {
                Label("Add Rule", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct SmartShelfRuleRow: View {
    @Binding var rule: SmartShelfRule
    let formats: [String]
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Picker("Field", selection: $rule.field) {
                ForEach(SmartShelfRule.Field.allCases) { field in
                    Label {
                        Text(field.label)
                    } icon: {
                        Image(systemName: field.systemImage)
                    }
                    .tag(field)
                }
            }
            .labelsHidden()
            .frame(minWidth: 125, idealWidth: 145)

            Picker("Condition", selection: $rule.comparison) {
                ForEach(rule.field.comparisons) { comparison in
                    Text(comparison.label).tag(comparison)
                }
            }
            .labelsHidden()
            .frame(minWidth: 105, idealWidth: 125)

            SmartShelfRuleValueEditor(rule: $rule, formats: formats)
                .frame(minWidth: 90, maxWidth: .infinity)

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove Rule")
            .accessibilityLabel("Remove Rule")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(theme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.borderSubtle, lineWidth: 1)
        }
        .onChange(of: rule.field) { oldField, newField in
            guard oldField != newField else { return }
            rule.reset(for: newField)
        }
    }
}

private struct SmartShelfRuleValueEditor: View {
    @Binding var rule: SmartShelfRule
    let formats: [String]

    var body: some View {
        HStack {
            if !rule.comparison.requiresValue {
                Spacer(minLength: 0)
            } else if rule.field.usesStatusValue {
                Picker("Value", selection: $rule.value) {
                    ForEach(ReadingStatus.allCases) { status in
                        Text(status.label).tag(status.rawValue)
                    }
                }
                .labelsHidden()
            } else if rule.field.usesFormatValue {
                Picker("Value", selection: $rule.value) {
                    ForEach(formats, id: \.self) { format in
                        Text(verbatim: format).tag(format)
                    }
                }
                .labelsHidden()
            } else {
                TextField(valuePrompt, text: $rule.value)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text(rule.field.label))
            }
        }
    }

    private var valuePrompt: LocalizedStringResource {
        rule.field.usesNumberValue ? "Number" : "Value"
    }
}

private struct SmartShelfPreviewPane: View {
    let matchCount: Int
    let books: [Book]
    let usesDeviceRule: Bool
    let deviceIsConnected: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live Preview")
                        .font(theme.body(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Matches: \(matchCount)")
                        .font(theme.label(size: 11, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .monospacedDigit()
                }
                Spacer()
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(16)

            Divider()

            if usesDeviceRule && !deviceIsConnected {
                Label("Connect Kindle to evaluate device rules.", systemImage: "ipad.landscape.badge.exclamationmark")
                    .font(theme.label(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }

            if books.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Books", systemImage: "books.vertical")
                } description: {
                    Text(emptyDescription)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(books) { book in
                            SmartShelfPreviewRow(
                                title: book.displayTitle,
                                author: book.displayAuthor,
                                format: book.format
                            )
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .background(theme.surface.opacity(0.32))
    }

    private var emptyDescription: LocalizedStringResource {
        if usesDeviceRule && !deviceIsConnected {
            "Device rules stay inactive until a Kindle is connected."
        } else {
            "Adjust the rules to include books from your library."
        }
    }
}

private struct SmartShelfPreviewRow: View {
    let title: String
    let author: String?
    let format: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed")
                .foregroundStyle(theme.accent)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.body(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                if let author {
                    Text(author)
                        .font(theme.label(size: 10))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: format)
                .font(theme.label(size: 9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.vertical, 9)
    }
}

private struct SmartShelfEditorFooter: View {
    let isEditing: Bool
    let canSave: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Label("Smart shelves update automatically.", systemImage: "sparkles")
                .font(theme.label(size: 11))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(actionTitle, action: onSave)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var actionTitle: LocalizedStringResource {
        isEditing ? "Save Changes" : "Create Smart Shelf"
    }
}

#Preview("Smart Shelf Builder") {
    let container = PersistenceController.inMemory()
    let first = Book(fileName: "duna.epub", originalFileName: "Duna.epub")
    first.title = "Duna"
    first.author = "Frank Herbert"
    first.language = "cs"
    first.pageCount = 280
    let second = Book(fileName: "solaris.epub", originalFileName: "Solaris.epub")
    second.title = "Solaris"
    second.author = "Stanisław Lem"
    second.language = "cs"
    second.pageCount = 204

    return SmartShelfEditorSheet(
        request: .create(),
        books: [first, second],
        formats: ["EPUB"],
        deviceFileNames: [],
        deviceIsConnected: false,
        onSave: { _, _ in true }
    )
    .modelContainer(container)
    .frame(width: 900, height: 640)
}
