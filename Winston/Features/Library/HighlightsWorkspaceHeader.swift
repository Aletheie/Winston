import SwiftUI

struct HighlightsWorkspaceHeader: View {
    let model: HighlightsWorkspaceModel
    let onSelectMode: (HighlightsWorkspaceMode) -> Void

    var body: some View {
        SheetHeader {
            VStack(alignment: .leading, spacing: WinstonLayout.space3) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WinstonLayout.space5) {
                        HighlightsWorkspaceTitle(totalCount: model.totalCount)
                        Spacer(minLength: WinstonLayout.space5)
                        HighlightsModePicker(
                            selection: model.mode,
                            onSelect: onSelectMode
                        )
                        .frame(width: 220)
                    }

                    VStack(alignment: .leading, spacing: WinstonLayout.space3) {
                        HighlightsWorkspaceTitle(totalCount: model.totalCount)
                        HighlightsModePicker(
                            selection: model.mode,
                            onSelect: onSelectMode
                        )
                        .frame(maxWidth: 280)
                    }
                }

                if model.mode == .library {
                    HighlightsFilterBar(model: model)
                } else {
                    Text("Review uses the search and filters you selected in Library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct HighlightsWorkspaceTitle: View {
    let totalCount: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: WinstonLayout.space3) {
            Image(systemName: "quote.bubble.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.usesTerminalCopy ? "// highlights" : "Highlights")
                    .font(.headline)
                    .accessibilityIdentifier("highlights.workspace")
                Text(
                    "Organize and revisit \(totalCount) saved passages.",
                    comment: "Highlights header subtitle; the value is the total highlight count."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HighlightsModePicker: View {
    let selection: HighlightsWorkspaceMode
    let onSelect: (HighlightsWorkspaceMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HighlightsWorkspaceMode.allCases) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    Text(mode.label)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 5)
                .background(
                    selection == mode ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(
                        cornerRadius: WinstonLayout.radius(.control),
                        style: .continuous
                    )
                )
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
                .accessibilityIdentifier("highlights.mode.\(mode.rawValue)")
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(
            cornerRadius: WinstonLayout.radius(.control),
            style: .continuous
        ))
        .accessibilityElement(children: .contain)
    }
}

private struct HighlightsFilterBar: View {
    let model: HighlightsWorkspaceModel

    var body: some View {
        @Bindable var model = model

        ViewThatFits(in: .horizontal) {
            HStack(spacing: WinstonLayout.space2) {
                HighlightsQuickFilterPicker(selection: $model.quickFilter)
                    .frame(width: 260)
                HighlightsBookFilter(
                    selection: $model.selectedBookID,
                    options: model.bookOptions
                )
                .frame(width: 190)
                HighlightsTagFilter(
                    selection: $model.selectedTag,
                    options: model.tagOptions
                )
                .frame(width: 150)
                HighlightsSearchField(text: $model.searchText)
                    .frame(minWidth: 170, idealWidth: 230)
            }

            VStack(alignment: .leading, spacing: WinstonLayout.space2) {
                HStack(spacing: WinstonLayout.space2) {
                    HighlightsQuickFilterPicker(selection: $model.quickFilter)
                    HighlightsSearchField(text: $model.searchText)
                }
                HStack(spacing: WinstonLayout.space2) {
                    HighlightsBookFilter(
                        selection: $model.selectedBookID,
                        options: model.bookOptions
                    )
                    HighlightsTagFilter(
                        selection: $model.selectedTag,
                        options: model.tagOptions
                    )
                }
            }
        }
    }
}

private struct HighlightsQuickFilterPicker: View {
    @Binding var selection: HighlightQuickFilter

    var body: some View {
        Picker("Highlight filter", selection: $selection) {
            ForEach(HighlightQuickFilter.allCases) { filter in
                Text(filter.label).tag(filter)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityIdentifier("highlights.quickFilter")
    }
}

private struct HighlightsBookFilter: View {
    @Binding var selection: UUID?
    let options: [HighlightBookFilterOption]

    var body: some View {
        Picker("Book", selection: $selection) {
            Text("Any Book").tag(nil as UUID?)
            Divider()
            ForEach(options) { option in
                Text(option.title).tag(Optional(option.id))
            }
        }
        .accessibilityIdentifier("highlights.bookFilter")
    }
}

private struct HighlightsTagFilter: View {
    @Binding var selection: String?
    let options: [String]

    var body: some View {
        Picker("Tag", selection: $selection) {
            Text("Any Tag").tag(nil as String?)
            Divider()
            ForEach(options, id: \.self) { tag in
                Text(verbatim: tag).tag(Optional(tag))
            }
        }
        .accessibilityIdentifier("highlights.tagFilter")
    }
}

private struct HighlightsSearchField: View {
    @Binding var text: String

    var body: some View {
        TextField("Search highlights", text: $text)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("highlights.search")
    }
}
