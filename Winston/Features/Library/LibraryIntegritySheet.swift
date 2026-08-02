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
                            "\(report.issues.count) issues",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }
                }
                .font(theme.label(size: 11, weight: .semibold))
                .foregroundStyle(report.issues.isEmpty ? theme.success : .orange)
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
                Picker("Issue category", selection: $selectedCategory) {
                    ForEach(LibraryIntegrityIssueCategory.allCases, id: \.self) { category in
                        Text(category.label)
                            .tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

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
        HStack(spacing: 10) {
            IntegritySummaryCard(
                title: "Catalog",
                value: report.catalogIssueCount,
                detail: Text(
                    "\(report.bookCount) books · \(report.workCount) works"
                ),
                systemImage: "books.vertical",
                tint: report.catalogIssueCount == 0 ? theme.success : .orange
            )
            IntegritySummaryCard(
                title: "Files",
                value: report.fileIssueCount,
                detail: Text("\(report.assetCount) managed records"),
                systemImage: "doc.badge.gearshape",
                tint: report.fileIssueCount == 0 ? theme.success : theme.destructive
            )
            IntegritySummaryCard(
                title: "Recovery",
                value: report.recoveryIssueCount,
                detail: Text("Durable journal"),
                systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                tint: report.recoveryIssueCount == 0 ? theme.success : .orange
            )
            IntegritySummaryCard(
                title: "Metadata",
                value: report.metadataSuggestionCount,
                detail: Text("Review suggestions"),
                systemImage: "wand.and.stars",
                tint: report.metadataSuggestionCount == 0 ? theme.success : theme.accent
            )
        }
        .padding(20)
    }

    @ViewBuilder
    private func issueList(_ report: LibraryIntegrityReport) -> some View {
        let issues = report.issues.filter { $0.category == selectedCategory }
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
            List(issues) { issue in
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
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
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
            Button("Import Recovery…") {
                dismiss()
                onOpenRecovery()
            }
            if report?.metadataSuggestionCount ?? 0 > 0 {
                Button("Metadata Cleanup…") {
                    dismiss()
                    onReviewMetadata()
                }
            }

            Spacer()

            Button("Rescan") { Task { await scan() } }
                .disabled(isScanning || isRepairing)
            Button("Repair Safe Issues") { Task { await repair() } }
                .disabled(
                    isScanning
                        || isRepairing
                        || report?.hasRepairableCatalogIssues != true
                )
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
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

private struct IntegritySummaryCard: View {
    let title: LocalizedStringKey
    let value: Int
    let detail: Text
    let systemImage: String
    let tint: Color

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 4)
                Text(value, format: .number)
                    .font(theme.body(size: 17, weight: .bold))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            detail
                .font(theme.label(size: 9))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.surface.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.borderSubtle, lineWidth: 1)
        }
    }
}

private struct LibraryIntegrityIssueRow: View {
    let issue: LibraryIntegrityIssue
    let onShowBook: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: issue.severity == .error
                ? "xmark.octagon.fill"
                : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .error ? theme.destructive : .orange)
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
}
