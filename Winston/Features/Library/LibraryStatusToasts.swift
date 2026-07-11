import SwiftUI

struct LibraryStatusToasts: View {
    let viewModel: LibraryViewModel

    @Environment(\.theme) private var theme
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(TransferQueue.self) private var transferQueue

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if transferQueue.isTransferring {
                TransferToastCard(title: transferTitle,
                                  progress: transferQueue.overallProgress,
                                  onCancel: { transferQueue.cancel() })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(activeToasts) { toast in
                    ToastCard(toast: toast)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .allowsHitTesting(false)
        }
        .padding(16)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: activeToasts)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: transferQueue.isTransferring)
    }

    private var transferTitle: String {
        if transferQueue.activeItem?.stage == .converting {
            return String(localized: "Converting\u{2026}")
        }
        let base = String(localized: "Sending to Kindle\u{2026}")
        let total = transferQueue.items.count
        guard total > 1 else { return base }
        let current = min(transferQueue.items.filter { $0.stage == .done }.count + 1, total)
        return "\(base) (\(current)/\(total))"
    }

    private var activeToasts: [Toast] {
        var toasts: [Toast] = []

        if viewModel.isImportingCalibre {
            toasts.append(Toast(id: "calibre", style: .progress,
                                message: viewModel.calibreImportProgressText ?? String(localized: "Importing from Calibre\u{2026}"),
                                progress: viewModel.calibreImportFraction))
        } else if let summary = viewModel.calibreImportSummary {
            toasts.append(Toast(id: "calibre", style: .success, message: summary))
        }

        if viewModel.isExtracting {
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
            toasts.append(Toast(id: message.id.uuidString, style: style, message: message.text))
        }

        return toasts
    }
}

// MARK: - Model

private struct Toast: Identifiable, Equatable {
    enum Style: Equatable { case progress, success, error, info }

    let id: String
    var style: Style
    var message: String
    var progress: Double?
}

// MARK: - Card

private struct ToastCard: View {
    let toast: Toast

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: toast.message)
                    .font(theme.label(size: 11, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = toast.progress {
                    ToastProgressBar(fraction: progress)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.borderSubtle, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
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

// MARK: - Transfer card (interactive, with Cancel)

private struct TransferToastCard: View {
    let title: String
    let progress: Double
    let onCancel: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(theme.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title)
                    .font(theme.label(size: 11, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                ToastProgressBar(fraction: progress)
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.borderSubtle, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

// MARK: - Determinate bar

private struct ToastProgressBar: View {
    let fraction: Double

    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.borderSubtle.opacity(0.5))
                Capsule().fill(theme.accent)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 3)
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}
