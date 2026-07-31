import SwiftData
import SwiftUI

struct WorkMergePicker: View {
    let work: Work
    let service: CatalogReconciliationService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @State private var searchText = ""
    @State private var target: Work?
    @State private var isConfirmingMerge = false
    @State private var candidates: [Work] = []
    @State private var isLoading = false
    @State private var loadError: String?

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
            Group {
                if isLoading, candidates.isEmpty {
                    ProgressView("Loading works…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn’t Load Works", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try Again") { Task { await loadCandidates() } }
                    }
                } else {
                    List(candidates) { candidate in
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
                }
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
        .task(id: searchText) {
            if !searchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            await loadCandidates()
        }
    }

    private func loadCandidates() async {
        isLoading = true
        defer { isLoading = false }
        let excludedID = work.uuid
        let key = searchText.normalizedMatchKey
        var descriptor: FetchDescriptor<Work>
        if key.isEmpty {
            descriptor = FetchDescriptor<Work>(
                predicate: #Predicate { $0.uuid != excludedID },
                sortBy: [SortDescriptor(\Work.title)]
            )
        } else {
            descriptor = FetchDescriptor<Work>(
                predicate: #Predicate {
                    $0.uuid != excludedID
                        && ($0.matchKey?.contains(key) == true)
                },
                sortBy: [SortDescriptor(\Work.title)]
            )
        }
        descriptor.fetchLimit = 100
        descriptor.relationshipKeyPathsForPrefetching = [\Work.editions]
        do {
            candidates = try modelContext.fetch(descriptor)
            loadError = nil
        } catch {
            candidates = []
            loadError = error.localizedDescription
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
