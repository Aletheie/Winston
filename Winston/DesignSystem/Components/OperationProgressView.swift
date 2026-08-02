import SwiftUI

struct OperationProgressView: View {
    let title: Text
    let detail: Text?
    let value: Double
    let completedCount: Int
    let totalCount: Int
    let accessibilityLabel: Text
    let accessibilityValue: Text
    let cancelLabel: Text?
    let canCancel: Bool
    let onCancel: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: WinstonLayout.space3) {
            VStack(alignment: .leading, spacing: WinstonLayout.space1) {
                HStack(spacing: WinstonLayout.space2) {
                    title
                        .font(theme.body(size: 11, weight: .semibold))
                    Spacer(minLength: WinstonLayout.space2)
                    Text("\(completedCount) of \(totalCount)")
                        .font(theme.label(size: 10))
                        .foregroundStyle(theme.textSecondary)
                        .monospacedDigit()
                }
                ProgressView(value: min(1, max(0, value)), total: 1)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityValue(accessibilityValue)
                if let detail {
                    detail
                        .font(theme.label(size: 9))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            if let cancelLabel, let onCancel {
                Button(action: onCancel) { cancelLabel }
                    .disabled(!canCancel)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
