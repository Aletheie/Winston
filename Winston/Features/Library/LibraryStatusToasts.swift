import SwiftUI

struct LibraryStatusToasts: View {
    let viewModel: LibraryViewModel
    let maintenance: MaintenanceScheduler
    let onReviewEditions: () -> Void
    let onReviewImport: () -> Void
    let onReviewBulkOperation: () -> Void
    let onResolveDigitalFile: (UUID) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(TransferQueue.self) private var transferQueue
    @Environment(DeviceMonitor.self) private var deviceMonitor

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            VStack(alignment: .trailing, spacing: 8) {
                if let progress = viewModel.activeBulkOperationProgress {
                    ProgressToastCard(
                        title: bulkOperationTitle(progress),
                        progress: progress.fraction,
                        isCancelling: viewModel.isCancellingBulkOperation,
                        onCancel: viewModel.cancelBulkOperation
                    )
                    .transition(toastTransition)
                } else if let report = viewModel.bulkOperationReport {
                    BulkOperationResultToastCard(
                        report: report,
                        onDetails: onReviewBulkOperation,
                        onDismiss: viewModel.dismissBulkOperationReport
                    )
                    .transition(toastTransition)
                }
                if let progress = viewModel.standardImportProgress {
                    ProgressToastCard(
                        title: standardImportTitle(progress),
                        progress: progress.fraction,
                        isCancelling: progress.isCancelling,
                        onCancel: {
                            viewModel.cancelImportSession(id: progress.sessionID)
                        }
                    )
                    .transition(toastTransition)
                }
                if transferQueue.isTransferring {
                    ProgressToastCard(title: transferTitle,
                                      progress: transferQueue.overallProgress,
                                      isCancelling: transferQueue.activeItem?.stage == .cancelling,
                                      onCancel: { transferQueue.cancel() })
                        .transition(toastTransition)
                }
                if let progress = deviceMonitor.deviceDeleteProgress {
                    ProgressToastCard(
                        title: deviceMonitor.isCancellingDeviceDelete
                            ? String(localized: "Cancelling Kindle removal…")
                            : String(
                                localized: "Removing \(progress.completedTargetCount) of \(progress.totalTargetCount) from the Kindle…"
                            ),
                        progress: progress.fraction,
                        isCancelling: deviceMonitor.isCancellingDeviceDelete,
                        onCancel: { deviceMonitor.cancelDeviceDelete() }
                    )
                    .transition(toastTransition)
                }
                if viewModel.isImportingCalibre {
                    ProgressToastCard(
                        title: viewModel.calibreImportProgressText
                            ?? String(localized: "Importing from Calibre\u{2026}"),
                        progress: viewModel.calibreImportFraction ?? 0,
                        isCancelling: viewModel.isCancellingCalibreImport,
                        onCancel: { viewModel.cancelCalibreImport() }
                    )
                        .transition(toastTransition)
                }
                ForEach(activeToasts) { toast in
                    ToastCard(
                        toast: toast,
                        onAction: { handleAction(toast) },
                        onDismiss: {
                            guard let id = toast.messageID else { return }
                            toastCenter.dismiss(id)
                        }
                    )
                        .transition(toastTransition)
                }
            }
        }
        .padding(16)
        .animation(toastAnimation, value: activeToasts.map(\.id))
        .animation(toastAnimation, value: viewModel.activeBulkOperationProgress)
        .animation(toastAnimation, value: viewModel.bulkOperationReport?.id)
        .animation(toastAnimation, value: viewModel.standardImportProgress)
        .animation(toastAnimation, value: transferQueue.isTransferring)
        .animation(toastAnimation, value: deviceMonitor.deviceDeleteProgress)
        .animation(toastAnimation, value: viewModel.isImportingCalibre)
    }

    private var toastTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    private var toastAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.35, dampingFraction: 0.85)
    }

    private var transferTitle: String {
        if transferQueue.activeItem?.stage == .cancelling {
            return String(localized: "Cancelling…")
        }
        if transferQueue.activeItem?.stage == .converting {
            return String(localized: "Converting\u{2026}")
        }
        if let plan = transferQueue.activePlan, plan.conflictCount > 0 {
            return String(
                localized: "Sending \(plan.affectedTargetCount) changes to Kindle (\(plan.conflictCount) conflicts)\u{2026}"
            )
        }
        let base = String(localized: "Sending to Kindle\u{2026}")
        let total = transferQueue.items.count
        guard total > 1 else { return base }
        let current = min(transferQueue.items.filter { $0.stage == .done }.count + 1, total)
        return "\(base) (\(current)/\(total))"
    }

    private func standardImportTitle(_ progress: ImportSessionProgress) -> String {
        if progress.isCancelling {
            return String(localized: "Cancelling import…")
        }
        let step = progress.step.localizedProgressLabel
        if let filename = progress.currentFilename {
            return String(
                localized: "Importing \(progress.completedCount) of \(progress.requestedCount): \(filename) — \(step)…"
            )
        }
        return String(
            localized: "Importing \(progress.completedCount) of \(progress.requestedCount) — \(step)…"
        )
    }

    private func bulkOperationTitle(_ progress: BulkOperationProgress) -> String {
        if viewModel.isCancellingBulkOperation {
            return String(localized: "Cancelling bulk operation…")
        }
        return String(
            localized: "Applying \(progress.completedTargetCount) of \(progress.totalTargetCount) library items…"
        )
    }

    private var activeToasts: [Toast] {
        var toasts: [Toast] = []

        if let progress = viewModel.managedFileProgress {
            toasts.append(Toast(
                id: "managed-files",
                style: .progress,
                message: managedFileMessage(
                    for: progress,
                    operationCount: viewModel.managedFileOperationCount
                ),
                progress: progress.overallFraction
            ))
        }

        switch maintenance.phase {
        case .running(let progress):
            toasts.append(Toast(
                id: "maintenance",
                style: .progress,
                message: maintenanceMessage(for: progress.job),
                progress: progress.fraction
            ))
        case .paused:
            // Pausing background maintenance is expected (especially in Low
            // Power Mode), so it should not occupy a permanent toast slot.
            break
        case .failed(let job, _):
            toasts.append(Toast(
                id: "maintenance",
                style: .error,
                message: String(
                    localized: "Library maintenance paused during \(maintenanceJobName(job))."
                )
            ))
        case .idle, .completed:
            break
        }

        if !viewModel.isImportingCalibre, let summary = viewModel.calibreImportSummary {
            let style: Toast.Style = switch viewModel.calibreImportSummaryStyle {
            case .success: .success
            case .info: .info
            case .error: .error
            }
            toasts.append(Toast(id: "calibre", style: style, message: summary))
        }

        if viewModel.isExtracting, viewModel.standardImportProgress == nil {
            toasts.append(Toast(id: "extract", style: .progress,
                                message: theme.copy.extracting(remaining: viewModel.pendingMetadataCount)))
        }

        if viewModel.isFetchingOnline {
            toasts.append(Toast(id: "online", style: .progress,
                                message: theme.usesTerminalCopy ? "fetching_metadata..." : String(localized: "Fetching metadata online\u{2026}")))
        } else if let summary = viewModel.metadataFetchSummary {
            toasts.append(Toast(id: "online", style: .success, message: summary))
        }

        let converting = viewModel.convertingUUIDs.count
        if converting > 0 {
            toasts.append(Toast(id: "convert", style: .progress,
                                message: theme.usesTerminalCopy ? "converting \(converting)..." : String(localized: "Converting \(converting)\u{2026}")))
        }

        for message in toastCenter.messages {
            let style: Toast.Style
            switch message.style {
            case .info:    style = .info
            case .success: style = .success
            case .error:   style = .error
            }
            toasts.append(Toast(
                id: message.id.uuidString,
                style: style,
                message: message.text,
                action: message.action,
                messageID: message.id
            ))
        }

        return toasts
    }

    private func managedFileMessage(
        for progress: ManagedFileProgress,
        operationCount: Int
    ) -> String {
        if operationCount > 1 {
            return String(localized: "Updating book files…")
        }
        switch progress.intent {
        case .importBook:
            return String(localized: "Adding book file…")
        case .replaceBookFile:
            return String(localized: "Replacing book file…")
        case .conversionOutput:
            return String(localized: "Installing converted file…")
        case .deleteBook:
            return String(localized: "Removing book files…")
        case .deleteBookFile:
            return String(localized: "Removing book file…")
        case .calibreImport:
            return String(localized: "Installing Calibre files…")
        case .legacyMigration:
            return String(localized: "Migrating book files…")
        case .coverUpdate:
            return String(localized: "Updating cover file…")
        case .restore:
            return String(localized: "Restoring book files…")
        }
    }

    private func maintenanceMessage(for job: MaintenanceJob) -> String {
        String(localized: "Library maintenance: \(maintenanceJobName(job))…")
    }

    private func maintenanceJobName(_ job: MaintenanceJob) -> String {
        switch job {
        case .legacyLibrary:
            String(localized: "migrating the legacy catalog")
        case .catalogStructure:
            String(localized: "updating catalog records")
        case .catalogCleanup:
            String(localized: "cleaning catalog records")
        case .assetInspection:
            String(localized: "inspecting book files")
        case .metadataExtraction:
            String(localized: "extracting metadata")
        case .editionDiscovery:
            String(localized: "finding related editions")
        case .automaticBackup:
            String(localized: "creating a backup")
        }
    }

    private func handleAction(_ toast: Toast) {
        guard let action = toast.action else { return }
        switch action {
        case .reviewEditionProposals:
            onReviewEditions()
        case .reviewImport:
            onReviewImport()
        case .relinkBook(let bookID), .attachDigitalFile(let bookID):
            onResolveDigitalFile(bookID)
        }
        if let id = toast.messageID { toastCenter.dismiss(id) }
    }
}

extension ImportSessionStep {
    var localizedProgressLabel: String {
        switch self {
        case .sourceDiscovery:
            String(localized: "discovering sources")
        case .staging:
            String(localized: "staging files")
        case .inspection:
            String(localized: "inspecting files")
        case .reconciliation:
            String(localized: "reconciling editions")
        case .modelProposal:
            String(localized: "preparing catalog changes")
        case .chunkCommit:
            String(localized: "saving imported books")
        case .publishing:
            String(localized: "publishing library changes")
        case .derivedJobs:
            String(localized: "scheduling metadata work")
        case .cancelling:
            String(localized: "cancelling")
        case .cancelled:
            String(localized: "cancelled")
        case .failed:
            String(localized: "failed")
        case .completed:
            String(localized: "completed")
        }
    }
}

// MARK: - Model

private struct Toast: Identifiable, Equatable {
    enum Style: Equatable { case progress, success, error, info }

    let id: String
    var style: Style
    var message: String
    var progress: Double?
    var action: ToastCenter.Message.Action?
    var messageID: UUID?

    init(
        id: String,
        style: Style,
        message: String,
        progress: Double? = nil,
        action: ToastCenter.Message.Action? = nil,
        messageID: UUID? = nil
    ) {
        self.id = id
        self.style = style
        self.message = message
        self.progress = progress
        self.action = action
        self.messageID = messageID
    }
}

// MARK: - Card

private struct ToastCard: View {
    let toast: Toast
    let onAction: () -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: toast.message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = toast.progress {
                    ToastProgressBar(fraction: progress)
                }
                if toast.action != nil {
                    Button(actionTitle, action: onAction)
                        .buttonStyle(.link)
                        .font(.caption.weight(.semibold))
                }
            }
            if toast.messageID != nil {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss notification")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 280, alignment: .leading)
        .glassEffect(
            .regular,
            in: RoundedRectangle(
                cornerRadius: WinstonLayout.cornerLarge,
                style: .continuous
            )
        )
    }

    private var actionTitle: LocalizedStringResource {
        switch toast.action {
        case .reviewEditionProposals: "Review"
        case .reviewImport: "Review"
        case .relinkBook: "Relink"
        case .attachDigitalFile: "Attach"
        case nil: "Open"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch toast.style {
        case .progress:
            ProgressView()
                .controlSize(.small)
                .tint(theme.accent)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(theme.success)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(theme.destructive)
        case .info:
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(theme.accent)
        }
    }
}

// MARK: - Progress card (interactive, with Cancel)

private struct ProgressToastCard: View {
    let title: String
    let progress: Double
    let isCancelling: Bool
    let onCancel: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(theme.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                ToastProgressBar(fraction: progress)
                    .accessibilityLabel("Progress")
                    .accessibilityValue(
                        Text("\(Int((max(0, min(1, progress)) * 100).rounded())) percent")
                    )
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.borderless)
            .disabled(isCancelling)
            .help("Cancel")
            .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 280, alignment: .leading)
        .glassEffect(
            .regular,
            in: RoundedRectangle(
                cornerRadius: WinstonLayout.cornerLarge,
                style: .continuous
            )
        )
    }
}

private struct BulkOperationResultToastCard: View {
    let report: BulkOperationPresentationReport
    let onDetails: () -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(summary)
                    .font(.callout)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Button("Details", action: onDetails)
                        .buttonStyle(.link)
                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(.link)
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 300, alignment: .leading)
        .glassEffect(
            .regular,
            in: RoundedRectangle(
                cornerRadius: WinstonLayout.cornerLarge,
                style: .continuous
            )
        )
        .accessibilityElement(children: .contain)
    }

    private var summary: String {
        switch report.outcomeKind {
        case .success:
            String(localized: "Bulk operation completed with \(report.appliedChangeCount) changes.")
        case .partialSuccess:
            String(localized: "Bulk operation partially completed; \(report.pendingCount) items remain.")
        case .cancelled:
            String(localized: "Bulk operation cancelled; \(report.pendingCount) items remain.")
        case .conflict:
            String(localized: "Bulk operation found \(report.conflictCount) conflicts.")
        case .failure:
            String(localized: "Bulk operation failed; \(report.pendingCount) items remain.")
        }
    }

    private var systemImage: String {
        switch report.outcomeKind {
        case .success: "checkmark.circle.fill"
        case .partialSuccess, .cancelled, .conflict: "exclamationmark.circle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch report.outcomeKind {
        case .success: theme.success
        case .partialSuccess, .cancelled, .conflict: theme.highlight
        case .failure: theme.destructive
        }
    }
}

// MARK: - Determinate bar

private struct ToastProgressBar: View {
    let fraction: Double

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.borderSubtle.opacity(0.5))
                Capsule().fill(theme.accent)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 3)
        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: fraction)
    }
}
