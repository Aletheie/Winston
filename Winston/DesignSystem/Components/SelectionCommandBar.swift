import SwiftUI

struct SelectionCommandBar<Actions: View, CompactActions: View>: View {
    let selectedCount: Int
    let hiddenCount: Int
    let canSelectAllVisible: Bool
    let onSelectAllVisible: () -> Void
    let onClear: () -> Void
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let compactActions: () -> CompactActions

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                selectionLabel
                    .font(theme.body(size: 11, weight: .semibold))
                if hiddenCount > 0 {
                    hiddenLabel
                        .font(theme.label(size: 9))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 4)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    selectionControls(labelsVisible: true)
                    Divider().frame(height: 18)
                    actions()
                }
                .fixedSize()

                HStack(spacing: 6) {
                    selectionControls(labelsVisible: false)
                    compactActions()
                }
                .fixedSize()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .themedChrome(
            role: .floating,
            cornerRadius: WinstonLayout.radius(.structural)
        )
        .padding(.horizontal, WinstonLayout.space3)
        .padding(.bottom, WinstonLayout.space2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection actions")
    }

    @ViewBuilder
    private func selectionControls(labelsVisible: Bool) -> some View {
        if labelsVisible {
            Button("Select All Visible", action: onSelectAllVisible)
                .disabled(!canSelectAllVisible)
            Button("Clear", action: onClear)
        } else {
            Button(action: onSelectAllVisible) {
                Image(systemName: "checkmark.circle")
            }
            .disabled(!canSelectAllVisible)
            .help("Select All Visible")
            .accessibilityLabel("Select All Visible")
            Button(action: onClear) {
                Image(systemName: "xmark.circle")
            }
            .help("Clear Selection")
            .accessibilityLabel("Clear Selection")
        }
    }

    @ViewBuilder
    private var selectionLabel: some View {
        if theme.usesTerminalCopy {
            Text(verbatim: "selected \(selectedCount)")
        } else {
            Text("\(selectedCount) Selected")
        }
    }

    @ViewBuilder
    private var hiddenLabel: some View {
        if theme.usesTerminalCopy {
            Text(verbatim: "hidden_by_filter \(hiddenCount)")
        } else {
            Text("\(hiddenCount) Hidden by Current Filter")
        }
    }
}
