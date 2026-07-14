import SwiftUI
import SwiftData

struct DuplicatesSheet: View {
    let viewModel: LibraryViewModel
    let onReviewEditions: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var groups: [DuplicateGroup] = []
    @State private var isScanning = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(theme.usesTerminalCopy ? "// duplicates" : "Duplicate Books")
                    .font(theme.body(size: 15, weight: .bold))
                Spacer()
                if !groups.isEmpty {
                    Text("\(groups.count) groups")
                        .font(theme.label(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(16)

            Divider()

            if isScanning && groups.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView {
                    Label(theme.usesTerminalCopy ? "// no_duplicates" : "No duplicates found",
                          systemImage: "checkmark.circle")
                } description: {
                    Text("Books are matched by title and author.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section(group.books.first?.displayTitle ?? "") {
                            ForEach(group.books) { book in
                                let isRecommended = group.recommendation.bookUUID == book.uuid
                                DuplicateRow(
                                    book: book,
                                    canResolve: group.books.count > 1,
                                    isRecommended: isRecommended,
                                    recommendationReasons: isRecommended ? group.recommendation.reasons : [],
                                    onDelete: { delete(book, from: group) },
                                    onKeep: { keepOnly(book, in: group) }
                                )
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                if viewModel.editions.pendingCount > 0 {
                    Button("Review Edition Suggestions (\(viewModel.editions.pendingCount))") {
                        dismiss()
                        onReviewEditions()
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 680, maxWidth: 1000,
               minHeight: 600, idealHeight: 760, maxHeight: .infinity)
        .task { await rescan() }
    }

    private func rescan() async {
        groups = await viewModel.duplicateGroups()
        isScanning = false
    }

    private func delete(_ book: Book, from group: DuplicateGroup) {
        groups.removeAll { $0.id == group.id }
        viewModel.remove(book)
        Task { await rescan() }
    }

    private func keepOnly(_ book: Book, in group: DuplicateGroup) {
        let others = group.books.filter { $0.id != book.id }
        groups.removeAll { $0.id == group.id }
        viewModel.removeBooks(others)
        Task { await rescan() }
    }
}

private struct DuplicateRow: View {
    let book: Book
    let canResolve: Bool
    let isRecommended: Bool
    let recommendationReasons: [DuplicateRecommendationReason]
    let onDelete: () -> Void
    let onKeep: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            BookCoverImageView(book: book)
                .frame(width: 36, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(book.displayTitle)
                        .font(theme.body(size: 12, weight: .medium))
                        .lineLimit(1)
                    if isRecommended {
                        Text("Recommended")
                            .font(theme.label(size: 9, weight: .bold))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.accent.opacity(0.12), in: Capsule())
                    }
                }
                detail
                    .font(theme.label(size: 10, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
                if isRecommended {
                    DuplicateRecommendationReasons(reasons: recommendationReasons)
                }
            }
            Spacer()
            Button(action: onKeep) {
                Text(keepLabel)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isRecommended ? theme.accent : theme.textPrimary)
            .disabled(!canResolve)
            .help("Keep this copy and delete the others")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!canResolve)
            .help("Delete this copy")
        }
        .padding(.vertical, 4)
    }

    private var keepLabel: LocalizedStringResource {
        isRecommended ? "Keep Recommended" : "Keep"
    }

    private var detail: Text {
        if book.fileSizeBytes > 0 {
            Text("\(book.format) · \(book.fileSizeDisplay) · added \(book.dateAdded, format: .dateTime.year().month().day())")
        } else {
            Text("\(book.format) · added \(book.dateAdded, format: .dateTime.year().month().day())")
        }
    }
}

private struct DuplicateRecommendationReasons: View {
    let reasons: [DuplicateRecommendationReason]

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            ForEach(reasons, id: \.self) { reason in
                Text(reason.label)
                    .font(theme.label(size: 9, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}
