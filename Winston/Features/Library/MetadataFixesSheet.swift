import SwiftData
import SwiftUI

struct MetadataFixesSheet: View {
    let viewModel: LibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var authorFixes: [MetadataFix] = []
    @State private var seriesFixes: [MetadataFix] = []
    @State private var seriesAssignmentFixes: [MetadataFix] = []
    @State private var isScanning = true

    var body: some View {
        VStack(spacing: 0) {
            MetadataFixesHeader(
                fixCount: authorFixes.count + seriesFixes.count + seriesAssignmentFixes.count
            )
            Divider()
            MetadataFixesContent(
                authorFixes: authorFixes,
                seriesFixes: seriesFixes,
                seriesAssignmentFixes: seriesAssignmentFixes,
                isScanning: isScanning,
                onApply: apply
            )
            Divider()
            MetadataFixesFooter(
                canApplyAll: !authorFixes.isEmpty || !seriesFixes.isEmpty || !seriesAssignmentFixes.isEmpty,
                onApplyAll: applyAll,
                onDone: { dismiss() }
            )
        }
        .background { ThemedBackground() }
        .frame(
            minWidth: 560,
            idealWidth: 680,
            maxWidth: 1_000,
            minHeight: 600,
            idealHeight: 760,
            maxHeight: .infinity
        )
        .task { await loadFixes() }
    }

    private func loadFixes() async {
        let fixes = await viewModel.metadataFixes()
        guard !Task.isCancelled else { return }
        var authors: [MetadataFix] = []
        var series: [MetadataFix] = []
        var assignments: [MetadataFix] = []
        for fix in fixes {
            switch fix.kind {
            case .author: authors.append(fix)
            case .series: series.append(fix)
            case .seriesAssignment: assignments.append(fix)
            }
        }
        authorFixes = authors
        seriesFixes = series
        seriesAssignmentFixes = assignments
        isScanning = false
    }

    private func apply(_ fix: MetadataFix) {
        switch fix.kind {
        case .author:
            authorFixes.removeAll { $0.id == fix.id }
        case .series:
            seriesFixes.removeAll { $0.id == fix.id }
        case .seriesAssignment:
            seriesAssignmentFixes.removeAll { $0.id == fix.id }
        }
        viewModel.applyMetadataFix(fix)
    }

    private func applyAll() {
        let fixes = authorFixes + seriesFixes + seriesAssignmentFixes
        guard !fixes.isEmpty else { return }
        authorFixes.removeAll()
        seriesFixes.removeAll()
        seriesAssignmentFixes.removeAll()
        viewModel.applyMetadataFixes(fixes)
    }
}

private struct MetadataFixesHeader: View {
    let fixCount: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.accent.gradient)
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .shadow(color: theme.accent.opacity(0.35), radius: 6, y: 3)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                theme.styledText(terminal: "// metadata_fixes", native: "Metadata Fixes")
                    .font(theme.body(size: 18, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                theme.styledText(
                    terminal: "review author + series corrections",
                    native: "Review suggested author, series name, and series membership corrections."
                )
                .font(theme.label(size: 11, weight: .regular))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            }

            Spacer(minLength: 16)

            if fixCount > 0 {
                Text(fixCount, format: .number)
                    .font(theme.label(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(theme.accent.opacity(0.14), in: Capsule())
                    .overlay {
                        Capsule().stroke(theme.accent.opacity(0.25), lineWidth: 1)
                    }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct MetadataFixesContent: View {
    let authorFixes: [MetadataFix]
    let seriesFixes: [MetadataFix]
    let seriesAssignmentFixes: [MetadataFix]
    let isScanning: Bool
    let onApply: (MetadataFix) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        if isScanning && authorFixes.isEmpty && seriesFixes.isEmpty && seriesAssignmentFixes.isEmpty {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if authorFixes.isEmpty && seriesFixes.isEmpty && seriesAssignmentFixes.isEmpty {
            ContentUnavailableView {
                Label {
                    theme.styledText(terminal: "// no_fixes_needed", native: "No fixes needed")
                } icon: {
                    Image(systemName: "checkmark.seal")
                }
            } description: {
                theme.styledText(
                    terminal: "library metadata already looks consistent",
                    native: "Your library metadata already looks consistent."
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !authorFixes.isEmpty {
                    MetadataFixSection(kind: .author, fixes: authorFixes, onApply: onApply)
                }
                if !seriesFixes.isEmpty {
                    MetadataFixSection(kind: .series, fixes: seriesFixes, onApply: onApply)
                }
                if !seriesAssignmentFixes.isEmpty {
                    MetadataFixSection(
                        kind: .seriesAssignment,
                        fixes: seriesAssignmentFixes,
                        onApply: onApply
                    )
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct MetadataFixSection: View {
    let kind: MetadataFix.Kind
    let fixes: [MetadataFix]
    let onApply: (MetadataFix) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Section {
            ForEach(fixes) { fix in
                MetadataFixRowView(fix: fix, onApply: { onApply(fix) })
            }
        } header: {
            switch kind {
            case .author:
                theme.styledText(terminal: "AUTHOR NAMES", native: "Author names")
                    .font(theme.label(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            case .series:
                theme.styledText(terminal: "SERIES NAMES", native: "Series names")
                    .font(theme.label(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            case .seriesAssignment:
                theme.styledText(terminal: "ADD TO SERIES", native: "Add to series")
                    .font(theme.label(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }
}

private struct MetadataFixRowView: View {
    let fix: MetadataFix
    let onApply: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: fix.original)
                    .strikethrough(fix.kind != .seriesAssignment)
                    .foregroundStyle(fix.kind == .seriesAssignment ? theme.textSecondary : theme.textTertiary)
                    .lineLimit(1)
                Image(systemName: fix.kind == .seriesAssignment ? "plus" : "arrow.right")
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
                Text(verbatim: suggestionLabel)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            .font(theme.body(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(fix.bookCount) books")
                .font(theme.label(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(theme.surfaceGlass, in: Capsule())

            Button(action: onApply) {
                theme.styledText(terminal: "apply", native: "Apply")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var suggestionLabel: String {
        guard let index = fix.seriesIndex, fix.kind == .seriesAssignment else {
            return fix.suggestion
        }
        return "\(fix.suggestion) #\(index)"
    }
}

private struct MetadataFixesFooter: View {
    let canApplyAll: Bool
    let onApplyAll: () -> Void
    let onDone: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onApplyAll) {
                theme.styledText(terminal: "apply_all", native: "Apply All")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canApplyAll)
            Spacer()
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func makeMetadataFixesPreviewModel() -> (LibraryViewModel, ModelContainer) {
    let container = PersistenceController.inMemory()
    let context = container.mainContext

    let books = [
        Book(fileName: "dune.epub", originalFileName: "Dune.epub"),
        Book(fileName: "messiah.epub", originalFileName: "Dune Messiah.epub"),
        Book(fileName: "children.epub", originalFileName: "Children of Dune.epub"),
    ]
    books[0].author = "Herbert, Frank"
    books[0].series = "Zaklinac"
    books[1].author = "Herbert, Frank"
    books[1].series = "Zaklínač"
    books[2].author = "Frank Herbert"
    books[2].series = "Zaklínač"
    let assignment = Book(
        fileName: "heart-on-fire.epub",
        originalFileName: "Heart on Fire (The Kingmaker Chronicles Book 3).epub"
    )
    assignment.title = "Heart on Fire (The Kingmaker Chronicles Book 3)"
    let canonical = Book(fileName: "promise-of-fire.epub", originalFileName: "A Promise of Fire.epub")
    canonical.title = "A Promise of Fire"
    canonical.series = "Kingmaker Chronicles"
    canonical.seriesIndex = "1"
    for book in books { context.insert(book) }
    context.insert(assignment)
    context.insert(canonical)
    try? context.save()

    let viewModel = LibraryViewModel(
        modelContext: context,
        settings: AppSettings(),
        toasts: ToastCenter()
    )
    return (viewModel, container)
}

#Preview("Black") {
    let (viewModel, container) = makeMetadataFixesPreviewModel()
    MetadataFixesSheet(viewModel: viewModel)
        .modelContainer(container)
        .environment(\.theme, .black)
        .tint(Theme.black.accent)
        .preferredColorScheme(.dark)
}

#Preview("Purple") {
    let (viewModel, container) = makeMetadataFixesPreviewModel()
    MetadataFixesSheet(viewModel: viewModel)
        .modelContainer(container)
        .environment(\.theme, .purple)
        .tint(Theme.purple.accent)
        .preferredColorScheme(.dark)
}

#Preview("White") {
    let (viewModel, container) = makeMetadataFixesPreviewModel()
    MetadataFixesSheet(viewModel: viewModel)
        .modelContainer(container)
        .environment(\.theme, .white)
        .tint(Theme.white.accent)
        .preferredColorScheme(.light)
}
#endif
