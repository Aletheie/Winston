import SwiftUI

struct LibraryIntegritySheet: View {
    let viewModel: LibraryViewModel
    let onShowBook: (UUID) -> Void
    let onReviewMetadata: () -> Void
    let onOpenRecovery: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var report: LibraryIntegrityReport?
    @State private var selectedCategory: LibraryIntegrityIssueCategory = .catalog
    @State private var isScanning = false
    @State private var isRepairing = false
    @State private var errorMessage: String?
    @State private var showsSafeRepairs = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(
            minWidth: 680,
            idealWidth: 820,
            maxWidth: 1_100,
            minHeight: 560,
            idealHeight: 720,
            maxHeight: .infinity
        )
        .background { ThemedBackground() }
        .task { await scan() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                theme.styledText(
                    terminal: "// library_integrity",
                    native: "Library Integrity"
                )
                .font(theme.display(size: 22, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                Text("Inspect catalog relationships, managed files, and crash-recovery journals.")
                    .font(theme.body(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer(minLength: 16)

            if isScanning || isRepairing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        Text(
                            isRepairing
                                ? String(localized: "Repairing library")
                                : String(localized: "Scanning library")
                        )
                    )
            } else if let report {
                Group {
                    if report.issues.isEmpty {
                        Label("Healthy", systemImage: "checkmark.circle.fill")
                    } else {
                        Label(
                            "\(report.issues.count) findings",
                            systemImage: report.errorCount > 0
                                ? "exclamationmark.triangle.fill"
                                : "info.circle.fill"
                        )
                    }
                }
                .font(theme.label(size: 11, weight: .semibold))
                .foregroundStyle(
                    report.issues.isEmpty
                        ? theme.success
                        : report.errorCount > 0
                            ? theme.destructive
                            : theme.textSecondary
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        if report == nil, isScanning {
            ProgressView("Scanning library…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report {
            VStack(spacing: 0) {
                summary(report)
                if let errorMessage {
                    errorBanner(errorMessage)
                }
                Divider()
                issueList(report)
            }
        } else {
            ContentUnavailableView {
                Label("Integrity scan failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(
                    errorMessage
                        ?? String(localized: "The library could not be inspected.")
                )
            } actions: {
                Button("Try Again") { Task { await scan() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summary(_ report: LibraryIntegrityReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(categoryTitle(for: report))
                        .font(.headline)
                    Text(categoryExplanation(for: report))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if selectedCategory == .catalog,
                   report.repairableTargetCount > 0 {
                    Label(
                        "\(report.repairableTargetCount) safe fixes",
                        systemImage: "wrench.and.screwdriver"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accent)
                }
            }

            Picker("Issue category", selection: $selectedCategory) {
                ForEach(LibraryIntegrityIssueCategory.allCases, id: \.self) { category in
                    Text(
                        "\(category.label) (\(report.issueCount(in: category)))"
                    )
                    .tag(category)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(20)
        .onChange(of: selectedCategory) {
            showsSafeRepairs = false
        }
    }

    @ViewBuilder
    private func issueList(_ report: LibraryIntegrityReport) -> some View {
        let issues = report.issues.filter { $0.category == selectedCategory }
        let safeIssues = issues.filter(\.isAutomaticallyRepairable)
        let reviewIssues = issues.filter { !$0.isAutomaticallyRepairable }
        if issues.isEmpty {
            ContentUnavailableView {
                Label {
                    Text(selectedCategory.emptyTitle)
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            } description: {
                Text(selectedCategory.emptyDetail)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !safeIssues.isEmpty {
                    Section("Safe Automatic Repairs") {
                        DisclosureGroup(isExpanded: $showsSafeRepairs) {
                            ForEach(safeIssues) { issue in
                                issueRow(issue)
                            }
                        } label: {
                            IntegritySafeRepairSummary(count: safeIssues.count)
                        }
                    }
                }
                if !reviewIssues.isEmpty {
                    Section("Needs Your Review") {
                        ForEach(reviewIssues) { issue in
                            issueRow(issue)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func issueRow(_ issue: LibraryIntegrityIssue) -> some View {
        LibraryIntegrityIssueRow(
            issue: issue,
            onShowBook: issue.bookID.map { bookID in
                {
                    dismiss()
                    onShowBook(bookID)
                }
            }
        )
    }

    private func categoryTitle(
        for report: LibraryIntegrityReport
    ) -> LocalizedStringResource {
        let count = report.issueCount(in: selectedCategory)
        if count == 0 { return selectedCategory.emptyTitleResource }
        return switch selectedCategory {
        case .catalog: "\(count) catalog links need attention"
        case .files: "\(count) managed files need attention"
        case .recovery: "\(count) interrupted operations need attention"
        }
    }

    private func categoryExplanation(
        for report: LibraryIntegrityReport
    ) -> LocalizedStringResource {
        switch selectedCategory {
        case .catalog:
            if report.repairableTargetCount > 0 {
                return "Safe repair rebuilds missing catalog links and derived fields. It never merges books or deletes files."
            }
            return "Checks relationships between works, editions, and file records. The scan itself never changes the library."
        case .files:
            return "Checks that Winston can find and read each managed file. The scan never moves or deletes files."
        case .recovery:
            return "Shows file operations interrupted before they could finish. Open Recovery to inspect or resume them."
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(theme.label(size: 11))
            .foregroundStyle(theme.destructive)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if selectedCategory == .recovery {
                Button("Open Recovery…") {
                    dismiss()
                    onOpenRecovery()
                }
            } else if selectedCategory == .catalog,
                      report?.metadataSuggestionCount ?? 0 > 0 {
                Button("Metadata Cleanup…") {
                    dismiss()
                    onReviewMetadata()
                }
            }

            Spacer()

            Button("Rescan") { Task { await scan() } }
                .disabled(isScanning || isRepairing)
            if selectedCategory == .catalog,
               let repairCount = report?.repairableTargetCount,
               repairCount > 0 {
                Button("Repair \(repairCount) Safe Catalog Items") {
                    Task { await repair() }
                }
                .disabled(isScanning || isRepairing)
                .help(
                    "Rebuild catalog links and derived fields without merging books or deleting files."
                )
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .themedChrome(role: .sheetAction)
    }

    private func scan() async {
        guard !isScanning, !isRepairing else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            report = try await viewModel.integrityReport()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func repair() async {
        guard let report, report.hasRepairableCatalogIssues else { return }
        isRepairing = true
        errorMessage = nil
        do {
            _ = try await viewModel.repairCatalogInvariants(from: report)
            isRepairing = false
            await scan()
        } catch is CancellationError {
            isRepairing = false
        } catch {
            isRepairing = false
            errorMessage = String(
                localized: "Repair stopped: \(error.localizedDescription). Rescan to see the durable result."
            )
        }
    }
}

private struct IntegritySafeRepairSummary: View {
    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(theme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(count) items can be repaired automatically")
                    .font(.body.weight(.semibold))
                Text(
                    "Expand to inspect them. Repairing restores catalog structure only; books and files stay in place."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LibraryIntegrityIssueRow: View {
    let issue: LibraryIntegrityIssue
    let onShowBook: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: issue.isAutomaticallyRepairable
                ? "wrench.and.screwdriver"
                : issue.severity == .error
                    ? "xmark.octagon.fill"
                    : "exclamationmark.triangle.fill")
                .foregroundStyle(
                    issue.isAutomaticallyRepairable
                        ? theme.accent
                        : issue.severity == .error
                            ? theme.destructive
                            : .orange
                )
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(theme.body(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(issue.detail)
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if let onShowBook {
                Button("Show", action: onShowBook)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

private extension LibraryIntegrityIssueCategory {
    var label: String {
        switch self {
        case .catalog: String(localized: "Catalog")
        case .files: String(localized: "Files")
        case .recovery: String(localized: "Recovery")
        }
    }

    var emptyDetail: String {
        switch self {
        case .catalog:
            String(localized: "Work, edition, and file-record relationships are consistent.")
        case .files:
            String(localized: "All referenced managed files are readable.")
        case .recovery:
            String(localized: "No managed-file transactions are waiting for recovery.")
        }
    }

    var emptyTitle: String {
        switch self {
        case .catalog:
            String(localized: "No catalog issues")
        case .files:
            String(localized: "No file issues")
        case .recovery:
            String(localized: "No recovery issues")
        }
    }

    var emptyTitleResource: LocalizedStringResource {
        switch self {
        case .catalog: "No catalog issues"
        case .files: "No file issues"
        case .recovery: "No recovery issues"
        }
    }
}

private extension LibraryIntegrityReport {
    var errorCount: Int {
        issues.count { $0.severity == .error }
    }

    var repairableTargetCount: Int {
        repairableBookIDs.count + repairableWorkIDs.count
    }

    func issueCount(in category: LibraryIntegrityIssueCategory) -> Int {
        issues.count { $0.category == category }
    }
}
