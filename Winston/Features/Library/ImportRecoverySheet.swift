import SwiftUI

struct ImportRecoverySheet: View {
    let viewModel: LibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var pending = ManagedFilePendingInspection(
        items: [],
        unreadableJournalURLs: [],
        failureMessages: []
    )
    @State private var isLoading = false
    @State private var isRecovering = false
    @State private var statusMessage: String?
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
            minWidth: 660,
            idealWidth: 780,
            maxWidth: 1_020,
            minHeight: 520,
            idealHeight: 680,
            maxHeight: .infinity
        )
        .background { ThemedBackground() }
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "tray.2")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                theme.styledText(
                    terminal: "// import_recovery",
                    native: "Import Review & Recovery"
                )
                .font(theme.display(size: 22, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                Text("Retry actionable source failures and reconcile durable file transactions.")
                    .font(theme.body(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer(minLength: 16)

            if isLoading || isRecovering {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        Text(
                            isRecovering
                                ? String(localized: "Recovering managed files")
                                : String(localized: "Loading recovery state")
                        )
                    )
            } else {
                Text(totalItemCount, format: .number)
                    .font(theme.label(size: 11, weight: .semibold))
                    .foregroundStyle(totalItemCount == 0 ? theme.success : theme.accent)
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(theme.surfaceGlass, in: Capsule())
                    .accessibilityLabel(
                        Text("\(totalItemCount) recovery items")
                    )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, totalItemCount == 0 {
            ProgressView("Loading recovery state…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if totalItemCount == 0,
                  pending.unreadableJournalURLs.isEmpty,
                  errorMessage == nil {
            ContentUnavailableView {
                Label("Nothing needs recovery", systemImage: "checkmark.seal")
            } description: {
                Text("There are no retained import failures or pending managed-file transactions.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.destructive)
                            .font(theme.label(size: 11))
                    }
                }

                if let statusMessage {
                    Section {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(theme.success)
                            .font(theme.label(size: 11))
                    }
                }

                if !pending.items.isEmpty || !pending.unreadableJournalURLs.isEmpty {
                    Section {
                        ForEach(pending.items) { item in
                            PendingManagedFileRow(item: item)
                        }
                        ForEach(pending.unreadableJournalURLs, id: \.self) { url in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "doc.questionmark.fill")
                                    .foregroundStyle(theme.destructive)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Unreadable recovery journal")
                                        .font(theme.body(size: 12, weight: .semibold))
                                    Text(url.lastPathComponent)
                                        .font(theme.label(size: 10))
                                        .foregroundStyle(theme.textSecondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    } header: {
                        Text("Managed-file recovery")
                    } footer: {
                        Text("These entries are authoritative crash-recovery journals. Retry recovery instead of dismissing them.")
                    }
                }

                if !viewModel.importRecoveryItems.isEmpty {
                    Section("Import failures") {
                        ForEach(viewModel.importRecoveryItems) { item in
                            ImportRecoveryItemRow(
                                item: item,
                                onRetry: {
                                    statusMessage = nil
                                    _ = viewModel.retryImportRecoveryItem(id: item.id)
                                },
                                onDismiss: {
                                    Task {
                                        await viewModel.dismissImportRecoveryItems(ids: [item.id])
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !pending.items.isEmpty {
                Button("Retry Managed-file Recovery") {
                    Task { await recoverManagedFiles() }
                }
                .disabled(isLoading || isRecovering)
            }
            Spacer()
            Button("Refresh") { Task { await load() } }
                .disabled(isLoading || isRecovering)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var totalItemCount: Int {
        viewModel.importRecoveryItems.count
            + pending.items.count
            + pending.unreadableJournalURLs.count
    }

    private func load() async {
        guard !isLoading, !isRecovering else { return }
        isLoading = true
        defer { isLoading = false }
        await viewModel.reloadImportRecoveryQueue()
        do {
            pending = try await viewModel.inspectPendingManagedFiles()
            errorMessage = viewModel.importRecoveryQueueError
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recoverManagedFiles() async {
        guard !isRecovering else { return }
        isRecovering = true
        statusMessage = nil
        errorMessage = nil
        let report = await viewModel.recoverManagedFiles()
        isRecovering = false
        if report.hasPendingWork {
            let count = report.failedTransactionIDs.count
                + report.unreadableJournalURLs.count
                + report.failureMessages.count
            errorMessage = String(
                localized: "Recovery still has \(count) items that need attention."
            )
        } else {
            statusMessage = String(localized: "Managed-file recovery completed.")
        }
        await load()
    }
}

private struct PendingManagedFileRow: View {
    let item: ManagedFilePendingItem

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.orange)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.intent.recoveryLabel)
                    .font(theme.body(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(
                    "\(item.stagedFileCount) staged files · \(item.cleanupCount) cleanups · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(theme.label(size: 10))
                .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ImportRecoveryItemRow: View {
    let item: ImportRecoveryItem
    let onRetry: () -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.reason.systemImage)
                .foregroundStyle(.orange)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.sourceURL?.lastPathComponent ?? String(localized: "Unknown import source"))
                    .font(theme.body(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(item.reason.localizedLabel)
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(item.detail)
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.occurredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(theme.label(size: 9))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                if item.canRetry {
                    Button("Retry", action: onRetry)
                        .controlSize(.small)
                }
                Button("Dismiss", action: onDismiss)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

private extension ManagedFileIntent {
    var recoveryLabel: String {
        switch self {
        case .importBook: String(localized: "Book import")
        case .replaceBookFile: String(localized: "Book file replacement")
        case .conversionOutput: String(localized: "Conversion output")
        case .deleteBook: String(localized: "Book removal")
        case .deleteBookFile: String(localized: "Book file removal")
        case .calibreImport: String(localized: "Calibre import")
        case .legacyMigration: String(localized: "Legacy migration")
        case .coverUpdate: String(localized: "Cover update")
        case .restore: String(localized: "Library restore")
        }
    }
}

private extension ImportFailureReason {
    var systemImage: String {
        switch self {
        case .unsupportedFormat: "doc.badge.ellipsis"
        case .unreadableSource: "doc.badge.xmark"
        case .staging: "square.and.arrow.down.badge.xmark"
        case .validation: "checkmark.seal.text.page"
        case .catalog: "books.vertical.circle"
        case .recoveryDeferred: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }
}
