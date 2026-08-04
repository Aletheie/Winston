import SwiftUI

struct OperationsCenterView: View {
    let store: OperationReportStore
    let onAction: (OperationReport, OperationReportAction) -> Void

    @State private var filter: OperationReportStatus = .review
    @State private var expandedReportIDs: Set<UUID> = []

    private var visibleReports: [OperationReport] {
        store.reports(status: filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            OperationsCenterHeader(
                filter: $filter,
                unresolvedCount: store.unresolvedCount
            )
            Divider()
            if visibleReports.isEmpty {
                OperationsEmptyState(status: filter)
            } else {
                OperationsReportList(
                    reports: visibleReports,
                    expandedReportIDs: $expandedReportIDs,
                    onAction: onAction
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { ThemedBackground() }
        .navigationTitle("Review & Operations")
        .accessibilityIdentifier("operationsCenter")
    }
}

private struct OperationsCenterHeader: View {
    @Binding var filter: OperationReportStatus
    let unresolvedCount: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: WinstonLayout.space5) {
                OperationsCenterTitle(unresolvedCount: unresolvedCount)
                Spacer(minLength: WinstonLayout.space5)
                OperationsStatusPicker(filter: $filter)
                    .frame(width: 420)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: WinstonLayout.space3) {
                OperationsCenterTitle(unresolvedCount: unresolvedCount)
                OperationsStatusPicker(filter: $filter)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WinstonLayout.space4)
        .padding(.vertical, WinstonLayout.space3)
    }
}

private struct OperationsCenterTitle: View {
    let unresolvedCount: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: WinstonLayout.space3) {
            Image(systemName: "checklist.checked")
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                theme.styledText(
                    terminal: "// review_and_operations",
                    native: "Review & Operations"
                )
                .font(.headline)
                Text("Review results and retry anything that still needs attention.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if unresolvedCount > 0 {
                Text(unresolvedCount, format: .number)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("\(unresolvedCount) unresolved operations")
            }
        }
    }
}

private struct OperationsStatusPicker: View {
    @Binding var filter: OperationReportStatus

    var body: some View {
        Picker("Operation Status", selection: $filter) {
            ForEach(OperationReportStatus.allCases, id: \.self) { status in
                Text(status.title)
                    .tag(status)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Operation Status")
        .accessibilityIdentifier("operations.filter")
    }
}

private struct OperationsReportList: View {
    let reports: [OperationReport]
    @Binding var expandedReportIDs: Set<UUID>
    let onAction: (OperationReport, OperationReportAction) -> Void

    var body: some View {
        List(reports) { report in
            OperationReportRow(
                report: report,
                isExpanded: $expandedReportIDs[contains: report.id],
                onAction: { onAction(report, $0) }
            )
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
    }
}

private struct OperationsEmptyState: View {
    let status: OperationReportStatus

    var body: some View {
        ContentUnavailableView {
            Label(status.emptyTitle, systemImage: status.emptySystemImage)
        } description: {
            Text(status.emptyDescription)
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
                        .font(.callout.weight(.semibold))
                    HStack(spacing: WinstonLayout.space2) {
                        Text(report.status.title)
                        Text(report.updatedAt, format: .relative(presentation: .named))
                        if report.persistence == .durableRecovery {
                            Label("Recovery on Disk", systemImage: "externaldrive.badge.checkmark")
                        } else {
                            Text("This Session")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(report.counts.completed)/\(report.counts.total)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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

private extension Set {
    subscript(contains element: Element) -> Bool {
        get { contains(element) }
        set {
            if newValue {
                insert(element)
            } else {
                remove(element)
            }
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
