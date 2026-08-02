import SwiftUI

struct OperationsCenterView: View {
    let store: OperationReportStore
    let onAction: (OperationReport, OperationReportAction) -> Void

    @Environment(\.theme) private var theme
    @State private var filter: OperationReportStatus = .review
    @State private var expandedReportIDs: Set<UUID> = []

    private var visibleReports: [OperationReport] {
        store.reports(status: filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            if visibleReports.isEmpty {
                emptyState
            } else {
                List(visibleReports) { report in
                    OperationReportRow(
                        report: report,
                        isExpanded: Binding(
                            get: { expandedReportIDs.contains(report.id) },
                            set: { expanded in
                                if expanded {
                                    expandedReportIDs.insert(report.id)
                                } else {
                                    expandedReportIDs.remove(report.id)
                                }
                            }
                        ),
                        onAction: { onAction(report, $0) }
                    )
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background { ThemedBackground() }
        .navigationTitle("Review & Operations")
        .accessibilityIdentifier("operationsCenter")
    }

    private var header: some View {
        HStack(spacing: WinstonLayout.space3) {
            Image(systemName: "checklist.checked")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WinstonLayout.space1) {
                theme.styledText(
                    terminal: "// review_and_operations",
                    native: "Review & Operations"
                )
                .font(theme.body(size: 17, weight: .bold))
                Text("Session results and links to recovery work that still needs attention.")
                    .font(theme.label(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            if store.unresolvedCount > 0 {
                Text(store.unresolvedCount, format: .number)
                    .font(theme.label(size: 12, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, WinstonLayout.space2)
                    .padding(.vertical, WinstonLayout.space1)
                    .background(theme.interaction.selection, in: Capsule())
                    .accessibilityLabel("\(store.unresolvedCount) unresolved operations")
            }
        }
        .padding(WinstonLayout.space4)
        .themedChrome(role: .toolbar)
    }

    private var filterBar: some View {
        Picker("Operation Status", selection: $filter) {
            ForEach(OperationReportStatus.allCases, id: \.self) { status in
                Text(status.title)
                    .tag(status)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, WinstonLayout.space4)
        .padding(.vertical, WinstonLayout.space2)
        .themedChrome(role: .toolbar)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(filter.emptyTitle, systemImage: filter.emptySystemImage)
        } description: {
            Text(filter.emptyDescription)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OperationReportRow: View {
    let report: OperationReport
    @Binding var isExpanded: Bool
    let onAction: (OperationReportAction) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: WinstonLayout.space3) {
                OperationResultSummary(metrics: report.metrics)
                if let detail = report.detail, !detail.isEmpty {
                    Text(detail)
                        .font(theme.label(size: 10))
                        .foregroundStyle(theme.textSecondary)
                        .textSelection(.enabled)
                }
                if !report.items.isEmpty {
                    VStack(alignment: .leading, spacing: WinstonLayout.space2) {
                        ForEach(report.items) { item in
                            OperationReportItemRow(item: item)
                        }
                    }
                }
                actionBar
            }
            .padding(.top, WinstonLayout.space2)
        } label: {
            HStack(alignment: .top, spacing: WinstonLayout.space3) {
                Image(systemName: report.source.systemImage)
                    .foregroundStyle(report.status.color(in: theme))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.source.title)
                        .font(theme.body(size: 12, weight: .semibold))
                    HStack(spacing: WinstonLayout.space2) {
                        Text(report.status.title)
                        Text(report.updatedAt, format: .relative(presentation: .named))
                        if report.persistence == .durableRecovery {
                            Label("Recovery on Disk", systemImage: "externaldrive.badge.checkmark")
                        } else {
                            Text("This Session")
                        }
                    }
                    .font(theme.label(size: 9))
                    .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Text("\(report.counts.completed)/\(report.counts.total)")
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(String(localized: report.source.title)), \(String(localized: report.status.title)), \(report.counts.completed) of \(report.counts.total) completed"
            )
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        if !report.actions.isEmpty {
            HStack {
                Spacer()
                if report.actions.contains(.open) {
                    Button("Open") { onAction(.open) }
                }
                if report.actions.contains(.retry) {
                    Button("Retry Safe Items") { onAction(.retry) }
                        .disabled(!report.canRetry)
                }
                if report.actions.contains(.dismiss) {
                    Button("Dismiss") { onAction(.dismiss) }
                }
            }
            .controlSize(.small)
        }
    }
}

private struct OperationReportItemRow: View {
    let item: OperationReportItem

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: WinstonLayout.space2) {
            Image(systemName: item.outcome.systemImage)
                .foregroundStyle(item.outcome.color(in: theme))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(theme.body(size: 11))
                Text(item.outcome.title)
                    .font(theme.label(size: 9))
                    .foregroundStyle(theme.textSecondary)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(theme.label(size: 9))
                        .foregroundStyle(theme.textTertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

private extension OperationReport {
    var metrics: [OperationResultMetric] {
        [
            OperationResultMetric(id: "completed", value: counts.completed, label: "Completed", kind: .success),
            OperationResultMetric(id: "failed", value: counts.failed, label: "Failed", kind: .error),
            OperationResultMetric(id: "pending", value: counts.pending, label: "Pending", kind: .information),
            OperationResultMetric(id: "warnings", value: counts.warnings, label: "Warnings", kind: .warning),
        ]
    }
}

private extension OperationReportSource {
    var title: LocalizedStringResource {
        switch self {
        case .reconciliation: "Edition Review"
        case .importReview: "Import Review"
        case .bulkLibrary: "Library Changes"
        case .kindleSync: "Kindle Sync"
        case .conversion: "Book Conversion"
        case .libraryHealth: "Library Health"
        case .importRecovery: "Import Recovery"
        case .transferRecovery: "Kindle Transfer Recovery"
        }
    }

    var systemImage: String {
        switch self {
        case .reconciliation: "rectangle.stack.badge.plus"
        case .importReview: "tray.and.arrow.down"
        case .bulkLibrary: "checklist"
        case .kindleSync: "externaldrive.badge.checkmark"
        case .conversion: "arrow.triangle.2.circlepath"
        case .libraryHealth: "stethoscope"
        case .importRecovery: "arrow.clockwise.circle"
        case .transferRecovery: "externaldrive.badge.exclamationmark"
        }
    }
}

private extension OperationReportStatus {
    var title: LocalizedStringResource {
        switch self {
        case .review: "Review"
        case .running: "Running"
        case .failed: "Failed"
        case .completed: "Completed"
        }
    }

    var emptyTitle: LocalizedStringResource {
        switch self {
        case .review: "Nothing Needs Review"
        case .running: "No Operations Running"
        case .failed: "No Failed Operations"
        case .completed: "No Session History"
        }
    }

    var emptyDescription: LocalizedStringResource {
        switch self {
        case .review: "Edition suggestions and durable recovery work appear here."
        case .running: "Long-running imports, conversions, and library changes appear here while active."
        case .failed: "Partial results stay here until you retry, open, or dismiss them."
        case .completed: "Completed session reports are kept temporarily and can be dismissed."
        }
    }

    var emptySystemImage: String {
        switch self {
        case .review: "checkmark.seal"
        case .running: "pause.circle"
        case .failed: "checkmark.circle"
        case .completed: "clock"
        }
    }

    func color(in theme: Theme) -> Color {
        switch self {
        case .review: theme.interaction.warning
        case .running: theme.accent
        case .failed: theme.destructive
        case .completed: theme.success
        }
    }
}

private extension OperationReportItemOutcome {
    var title: LocalizedStringResource {
        switch self {
        case .succeeded: "Succeeded"
        case .warning: "Completed with a Warning"
        case .failed: "Failed"
        case .pending: "Pending"
        case .skipped: "Skipped"
        case .deliveryUnknown: "Delivery Needs Review"
        }
    }

    var systemImage: String {
        switch self {
        case .succeeded: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .pending: "clock"
        case .skipped: "minus.circle"
        case .deliveryUnknown: "questionmark.diamond.fill"
        }
    }

    func color(in theme: Theme) -> Color {
        switch self {
        case .succeeded: theme.success
        case .warning, .deliveryUnknown: theme.interaction.warning
        case .failed: theme.destructive
        case .pending, .skipped: theme.textSecondary
        }
    }
}
