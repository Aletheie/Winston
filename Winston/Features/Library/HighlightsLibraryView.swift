import SwiftData
import SwiftUI

struct HighlightsLibraryView: View {
    let model: HighlightsWorkspaceModel
    let onSelect: (PersistentIdentifier) -> Void
    let onToggleFavorite: (HighlightWorkspaceItem) -> Void
    let onSave: () -> Bool
    let onRetry: () -> Void

    var body: some View {
        if model.isLoading && model.allItems.isEmpty {
            HighlightsLoadingView()
        } else if let error = model.loadError, model.allItems.isEmpty {
            HighlightsLoadErrorView(message: error, onRetry: onRetry)
        } else if model.allItems.isEmpty {
            HighlightsEmptyLibraryView()
        } else if model.visibleItems.isEmpty {
            HighlightsNoMatchesView()
        } else {
            HSplitView {
                HighlightsListPane(
                    groups: model.visibleGroups,
                    selectedID: model.selectedHighlightID,
                    onSelect: onSelect,
                    onToggleFavorite: onToggleFavorite
                )
                .frame(minWidth: 390, idealWidth: 560)

                HighlightInspectorPane(
                    model: model,
                    onToggleFavorite: onToggleFavorite,
                    onSave: onSave
                )
                .frame(minWidth: 310, idealWidth: 390, maxWidth: 520)
            }
        }
    }
}

private struct HighlightsListPane: View {
    let groups: [HighlightBookGroup]
    let selectedID: PersistentIdentifier?
    let onSelect: (PersistentIdentifier) -> Void
    let onToggleFavorite: (HighlightWorkspaceItem) -> Void

    var body: some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        HighlightLibraryRow(
                            item: item,
                            isSelected: selectedID == item.id,
                            onSelect: { onSelect(item.id) },
                            onToggleFavorite: { onToggleFavorite(item) }
                        )
                        .listRowInsets(EdgeInsets(
                            top: WinstonLayout.space2,
                            leading: WinstonLayout.space3,
                            bottom: WinstonLayout.space2,
                            trailing: WinstonLayout.space2
                        ))
                    }
                } header: {
                    HighlightBookGroupHeader(
                        title: group.title,
                        author: group.author,
                        count: group.items.count
                    )
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("highlights.list")
    }
}

private struct HighlightBookGroupHeader: View {
    let title: String
    let author: String?
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WinstonLayout.space2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let author {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(count, format: .number)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.top, WinstonLayout.space2)
    }
}

private struct HighlightLibraryRow: View {
    let item: HighlightWorkspaceItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: WinstonLayout.space2) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: WinstonLayout.space2) {
                    Image(systemName: item.isNote ? "note.text" : "quote.opening")
                        .font(.caption)
                        .foregroundStyle(theme.accent)
                        .frame(width: 16)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: WinstonLayout.space1) {
                        Text(item.text)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        HighlightRowMetadata(item: item)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onToggleFavorite) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(item.isFavorite ? theme.highlight : theme.textTertiary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.vertical, WinstonLayout.space1)
        .listRowBackground(
            isSelected ? theme.interaction.selection : Color.clear
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("highlights.row")
    }
}

private struct HighlightRowMetadata: View {
    let item: HighlightWorkspaceItem

    var body: some View {
        HStack(spacing: 6) {
            if let location = item.location, !location.isEmpty {
                Text("Location \(location)")
            }
            if item.hasReflection {
                Label("Reflection", systemImage: "text.bubble")
                    .labelStyle(.iconOnly)
                    .help("Has reflection")
            }
            ForEach(item.tags.prefix(3), id: \.self) { tag in
                Text(verbatim: tag)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if item.tags.count > 3 {
                Text("+\(item.tags.count - 3)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct HighlightInspectorPane: View {
    let model: HighlightsWorkspaceModel
    let onToggleFavorite: (HighlightWorkspaceItem) -> Void
    let onSave: () -> Bool

    var body: some View {
        if let item = model.selectedItem {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: WinstonLayout.space5) {
                        HighlightInspectorHeader(
                            item: item,
                            onToggleFavorite: { onToggleFavorite(item) }
                        )
                        HighlightSourceBlock(item: item)
                        HighlightEditorFields(model: model)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(WinstonLayout.space4)
                }
                Divider()
                HStack {
                    if model.hasUnsavedChanges {
                        Text("Unsaved changes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revert", action: model.discardDraft)
                        .disabled(!model.hasUnsavedChanges)
                    Button("Save", action: { _ = onSave() })
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!model.hasUnsavedChanges)
                        .accessibilityIdentifier("highlights.save")
                }
                .padding(WinstonLayout.space3)
                .themedChrome(role: .inspector)
            }
            .background(.background.opacity(0.35))
        } else {
            ContentUnavailableView(
                "Select a Highlight",
                systemImage: "quote.bubble",
                description: Text("Choose a saved passage to add tags or a reflection.")
            )
        }
    }
}

struct HighlightInspectorHeader: View {
    let item: HighlightWorkspaceItem
    let onToggleFavorite: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: WinstonLayout.space3) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.bookTitle)
                    .font(.headline)
                    .lineLimit(2)
                if let author = item.bookAuthor {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: onToggleFavorite) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(item.isFavorite ? theme.highlight : theme.textTertiary)
            }
            .buttonStyle(.borderless)
            .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityIdentifier("highlights.favorite")
        }
    }
}

struct HighlightSourceBlock: View {
    let item: HighlightWorkspaceItem

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: WinstonLayout.space3) {
            HStack(spacing: WinstonLayout.space2) {
                Label(
                    item.isNote ? "Kindle Note" : "Highlighted Passage",
                    systemImage: item.isNote ? "note.text" : "quote.opening"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.accent)
                Spacer()
                if let location = item.location, !location.isEmpty {
                    Text("Location \(location)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(item.text)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let date = item.addedDate {
                Text(date, format: .dateTime.day().month().year())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(WinstonLayout.space4)
        .background(theme.surface, in: RoundedRectangle(
            cornerRadius: WinstonLayout.radius(.content),
            style: .continuous
        ))
    }
}

struct HighlightEditorFields: View {
    let model: HighlightsWorkspaceModel

    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: WinstonLayout.space4) {
            VStack(alignment: .leading, spacing: WinstonLayout.space1) {
                Text("Tags")
                    .font(.subheadline.weight(.semibold))
                TextField("Comma-separated tags", text: $model.draftTagsText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("highlights.tags")
                Text("Use your own themes, projects, or ideas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: WinstonLayout.space1) {
                Text("Reflection")
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: $model.draftReflection)
                    .accessibilityLabel("Reflection")
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(WinstonLayout.space2)
                    .frame(minHeight: 130)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(
                        cornerRadius: WinstonLayout.radius(.control),
                        style: .continuous
                    ))
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: WinstonLayout.radius(.control),
                            style: .continuous
                        )
                        .stroke(theme.borderSubtle, lineWidth: 1)
                    }
                    .accessibilityIdentifier("highlights.reflection")
                Text("Add what this passage means to you. The imported text stays unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HighlightsLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: WinstonLayout.space4) {
            ForEach(0..<5, id: \.self) { _ in
                VStack(alignment: .leading, spacing: WinstonLayout.space2) {
                    Text("A saved passage from your library")
                    Text("Book title · Location 100")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
        }
        .padding(WinstonLayout.space5)
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading highlights")
    }
}

private struct HighlightsLoadErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t Load Highlights", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: onRetry)
        }
    }
}

private struct HighlightsEmptyLibraryView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Highlights Yet", systemImage: "quote.bubble")
        } description: {
            Text("Connect a Kindle and import its highlights and notes to begin building this library.")
        }
    }
}

private struct HighlightsNoMatchesView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Matching Highlights", systemImage: "magnifyingglass")
        } description: {
            Text("Try a different search, book, tag, or quick filter.")
        }
    }
}
