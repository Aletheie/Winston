import SwiftData
import SwiftUI

struct WorkMergePicker: View {
    let work: Work
    let service: EditionService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Query(sort: \Work.title) private var works: [Work]
    @State private var searchText = ""
    @State private var target: Work?
    @State private var isConfirmingMerge = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.usesTerminalCopy ? "// merge_works" : "Merge Works")
                    .font(theme.body(size: 15, weight: .bold))
                Text("Move another work’s editions into “\(work.displayTitle)”.")
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            List(filteredWorks) { candidate in
                Button {
                    requestMerge(of: candidate)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.displayTitle)
                            .font(theme.body(size: 12, weight: .medium))
                        HStack(spacing: 4) {
                            if let author = candidate.author, !author.isEmpty {
                                Text(author)
                            }
                            Text("\(candidate.editions.count) editions")
                        }
                        .font(theme.label(size: 10))
                        .foregroundStyle(theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $searchText)
            Divider()
            HStack {
                Text("No files are moved or deleted.")
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 440, minHeight: 420)
        .confirmationDialog(
            "Merge these works?",
            isPresented: $isConfirmingMerge,
            presenting: target
        ) { candidate in
            Button("Merge Into This Work") { merge(candidate) }
        } message: { candidate in
            Text("The editions of “\(candidate.displayTitle)” move into “\(work.displayTitle)”. No files are moved or deleted.")
        }
    }

    private var filteredWorks: [Work] {
        let candidates = works.filter { $0.uuid != work.uuid }
        guard !searchText.isEmpty else { return candidates }
        let key = searchText.normalizedMatchKey
        return candidates.filter {
            $0.displayTitle.normalizedMatchKey.contains(key) || ($0.matchKey ?? "").contains(key)
        }
    }

    private func requestMerge(of candidate: Work) {
        target = candidate
        isConfirmingMerge = true
    }

    private func merge(_ candidate: Work) {
        if service.mergeWorks(candidate, into: work) != nil {
            dismiss()
        }
    }
}
