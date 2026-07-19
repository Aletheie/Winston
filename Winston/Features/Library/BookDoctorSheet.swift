import SwiftUI
import UniformTypeIdentifiers

nonisolated struct BookDoctorRequest: Identifiable, Sendable {
    enum Purpose: Sendable, Equatable {
        case sendToKindle
        case review
    }

    let id = UUID()
    let sources: [BookDoctorSource]
    let purpose: Purpose
}

struct BookDoctorSheet: View {
    let request: BookDoctorRequest
    let onProceed: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var reports: [BookDoctorReport] = []
    @State private var isInspecting = true
    @State private var completedInspectionCount = 0
    @State private var repairingIDs: Set<UUID> = []
    @State private var savedRepairNames: [UUID: String] = [:]
    @State private var repairError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 720, maxWidth: 920, minHeight: 480, idealHeight: 640)
        .background { ThemedBackground() }
        .task(id: request.id) { await inspect() }
        .alert("Repair Failed", isPresented: repairErrorBinding) {
            Button("OK", role: .cancel) { repairError = nil }
        } message: {
            Text(repairError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "stethoscope")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Book Doctor")
                    .font(theme.display(size: 22, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                Text(headerDetail)
                    .font(theme.body(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 12)
            if !isInspecting {
                statusSummary
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if isInspecting {
                BookDoctorInspectionProgress(
                    completed: completedInspectionCount,
                    total: request.sources.count
                )
                Divider()
            }

            if reports.isEmpty {
                Text("Results appear as each book finishes.")
                    .font(theme.body(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(reports) { report in
                    BookDoctorReportSection(
                        report: report,
                        isRepairing: repairingIDs.contains(report.id),
                        savedRepairName: savedRepairNames[report.id],
                        onRepair: { repair(report) }
                    )
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if reports.contains(where: \BookDoctorReport.canRepair) {
                Label("Repairs are saved as new files. Originals stay untouched.", systemImage: "lock.shield")
                    .font(theme.label(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button(cancelButtonTitle) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if request.purpose != .review {
                Button(proceedButtonTitle) {
                    let urls = eligibleReports.map(\.source.url)
                    dismiss()
                    onProceed(urls)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isInspecting || eligibleReports.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var statusSummary: some View {
        let blocked = reports.filter { !isEligible($0) }.count
        let warnings = reports.filter { isEligible($0) && ($0.hasErrors || $0.hasWarnings) }.count
        return HStack(spacing: 12) {
            if blocked > 0 {
                Label("\(blocked) blocked", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(theme.destructive)
            }
            if warnings > 0 {
                Label("\(warnings) need review", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if blocked == 0 && warnings == 0 {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
            }
        }
        .font(theme.label(size: 11, weight: .semibold))
    }

    private var headerDetail: LocalizedStringKey {
        switch request.purpose {
        case .sendToKindle:
            "Review the selected books before sending them to Kindle."
        case .review:
            "A local, read-only inspection of the selected books."
        }
    }

    private var eligibleReports: [BookDoctorReport] {
        reports.filter(isEligible)
    }

    private func isEligible(_ report: BookDoctorReport) -> Bool {
        switch request.purpose {
        case .sendToKindle: report.canSend
        case .review: !report.hasErrors
        }
    }

    private var cancelButtonTitle: LocalizedStringKey {
        request.purpose == .review ? "Done" : "Cancel"
    }

    private var proceedButtonTitle: LocalizedStringKey {
        let count = eligibleReports.count
        return switch request.purpose {
        case .sendToKindle:
            count == request.sources.count ? "Send \(count) to Kindle" : "Send \(count) Ready Books"
        case .review:
            "Done"
        }
    }

    private var repairErrorBinding: Binding<Bool> {
        Binding(
            get: { repairError != nil },
            set: { if !$0 { repairError = nil } }
        )
    }

    private func inspect() async {
        isInspecting = true
        completedInspectionCount = 0
        reports = []
        let sources = request.sources
        let results = await BookDoctorService.inspect(sources) { completed, report in
            await MainActor.run {
                reports.append(report)
                completedInspectionCount = completed
            }
        }
        guard !Task.isCancelled else { return }
        reports = results
        completedInspectionCount = results.count
        isInspecting = false
    }

    private func repair(_ report: BookDoctorReport) {
        let source = report.source.url
        let base = source.deletingPathExtension().lastPathComponent
        Task {
            guard let destination = await FilePanel.saveFile(
                message: String(localized: "Save a repaired copy. Book Doctor will not modify the original."),
                suggestedName: "\(base) — Repaired.epub",
                allowedContentType: .epub
            ) else { return }
            repairingIDs.insert(report.id)
            defer { repairingIDs.remove(report.id) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try BookDoctorService.makeRepairedCopy(of: source, at: destination)
                }.value
                savedRepairNames[report.id] = destination.lastPathComponent
            } catch {
                repairError = error.localizedDescription
            }
        }
    }
}

private struct BookDoctorInspectionProgress: View {
    let completed: Int
    let total: Int

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Checking books…")
                    .font(theme.body(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(
                    "Checked \(completed) of \(total)",
                    comment: "Book Doctor progress; the first value is completed books and the second is the total."
                )
                .font(theme.label(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .monospacedDigit()
            }

            ProgressView(value: Double(completed), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .accessibilityLabel("Book Doctor progress")
                .accessibilityValue("\(completed) of \(total) books checked")

            Text("Checking structure, content, cover, encoding, and DRM…")
                .font(theme.body(size: 11))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct BookDoctorReportSection: View {
    let report: BookDoctorReport
    let isRepairing: Bool
    let savedRepairName: String?
    let onRepair: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Section {
            if report.issues.isEmpty {
                Label("No issues found", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
                    .font(theme.body(size: 12, weight: .medium))
                    .padding(.vertical, 5)
            } else {
                ForEach(report.issues) { issue in
                    BookDoctorIssueRow(issue: issue)
                }
            }

            if report.canRepair {
                HStack(spacing: 10) {
                    if let savedRepairName {
                        Label("Saved “\(savedRepairName)”", systemImage: "checkmark")
                            .font(theme.body(size: 11))
                            .foregroundStyle(theme.success)
                            .lineLimit(1)
                    } else {
                        Text("Automatic repair can remove dead spine references and normalize readable text encoding.")
                            .font(theme.body(size: 11))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Button(action: onRepair) {
                        if isRepairing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save Repaired Copy…")
                        }
                    }
                    .disabled(isRepairing)
                }
                .padding(.vertical, 4)
            }
        } header: {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                Text(verbatim: report.source.title)
                    .font(theme.body(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(report.format)
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                if let pageCount = report.pageCount {
                    Text("About \(pageCount) pages")
                        .font(theme.label(size: 10))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    private var statusIcon: String {
        if report.hasErrors { return "xmark.octagon.fill" }
        if report.hasWarnings { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if report.hasErrors { return theme.destructive }
        if report.hasWarnings { return .orange }
        return theme.success
    }
}

private struct BookDoctorIssueRow: View {
    let issue: BookDoctorIssue

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(theme.body(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(issue.detail)
                    .font(theme.body(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch issue.severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .note: "info.circle.fill"
        }
    }

    private var color: Color {
        switch issue.severity {
        case .error: theme.destructive
        case .warning: .orange
        case .note: theme.accent
        }
    }
}

#if DEBUG
#Preview("Book Doctor") {
    BookDoctorSheet(
        request: BookDoctorRequest(
            sources: [BookDoctorSource(title: "The Left Hand of Darkness", url: URL(fileURLWithPath: "/tmp/book.epub"))],
            purpose: .review
        ),
        onProceed: { _ in }
    )
    .environment(\.theme, .purple)
    .preferredColorScheme(.dark)
}
#endif
