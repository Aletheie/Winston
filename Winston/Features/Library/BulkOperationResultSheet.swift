import SwiftUI

struct BulkOperationResultSheet: View {
    let report: BulkOperationPresentationReport
    let onRetry: () -> Void
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(report.items) { item in
                BulkOperationResultRow(item: item)
            }
            if let failure = failureText {
                Divider()
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(theme.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider()
            HStack {
                Text(resultSummary)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                if report.canRetry {
                    Button("Retry Remaining") {
                        onRetry()
                        dismiss()
                    }
                }
                Button("Done") {
                    onClose()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(.bar)
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(operationTitle)
                .font(theme.body(size: 15, weight: .bold))
            Text(completionTitle)
                .font(theme.label(size: 11))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var operationTitle: LocalizedStringResource {
        switch report.operation {
        case .metadataEdit: "Metadata Update Results"
        case .catalogDelete: "Delete Results"
        case .collectionAdd: "Add to Collection Results"
        case .collectionRemove: "Remove from Collection Results"
        case .deviceSend: "Kindle Delivery Results"
        case .deviceDelete: "Kindle Removal Results"
        }
    }

    private var completionTitle: LocalizedStringResource {
        switch report.outcomeKind {
        case .success: "All planned changes completed."
        case .partialSuccess: "Some changes completed and some require attention."
        case .cancelled: "The operation stopped between safe commit boundaries."
        case .conflict: "No unsafe changes were applied to conflicting items."
        case .failure: "The operation could not complete."
        }
    }

    private var resultSummary: LocalizedStringResource {
        "\(report.appliedChangeCount) changes, \(report.conflictCount) conflicts, \(report.warningCount) warnings, \(report.pendingCount) remaining"
    }

    private var failureText: String? {
        if let detail = report.durableFailureDetail, !detail.isEmpty { return detail }
        guard let code = report.durableFailureCode else { return nil }
        return switch code {
        case .catalogSave: String(localized: "The catalog could not be saved.")
        case .fileTransaction: String(localized: "A managed-file transaction could not finish.")
        case .deviceDisconnected: String(localized: "The Kindle disconnected.")
        case .operationInProgress: String(localized: "Another operation is already in progress.")
        case .executionFailed: String(localized: "The operation failed before all items were processed.")
        }
    }
}

private struct BulkOperationResultRow: View {
    let item: BulkOperationPresentationItem

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(2)
                Text(outcomeTitle)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(theme.textTertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(item.title), \(String(localized: outcomeTitle))"))
    }

    private var outcomeTitle: LocalizedStringResource {
        switch item.outcome {
        case .applied: "Applied"
        case .unchanged: "Already up to date"
        case .warning(.publicationPending): "Applied; file publication pending"
        case .warning(.postProcessingFailed): "Applied; post-processing needs attention"
        case .conflict(.missingTarget): "Skipped; item no longer exists"
        case .conflict(.invalidTarget): "Skipped; item is not valid for this action"
        case .conflict(.unavailable): "Skipped; item is unavailable"
        case .conflict(.drmProtected): "Skipped; item is DRM protected"
        case .conflict(.destinationCollision): "Skipped; destination already exists"
        case .conflict(.sourceChanged): "Skipped; source changed"
        case .conflict(.itemFailed): "Failed"
        case .pending: "Not processed"
        }
    }

    private var symbol: String {
        switch item.outcome {
        case .applied: "checkmark.circle.fill"
        case .unchanged: "equal.circle"
        case .warning: "exclamationmark.circle.fill"
        case .conflict: "xmark.circle.fill"
        case .pending: "clock"
        }
    }

    private var color: Color {
        switch item.outcome {
        case .applied: theme.success
        case .unchanged, .pending: theme.textSecondary
        case .warning: theme.highlight
        case .conflict: theme.destructive
        }
    }
}
