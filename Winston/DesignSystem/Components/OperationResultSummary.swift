import SwiftUI

nonisolated struct OperationResultMetric: Identifiable, Equatable, Sendable {
    let id: String
    let value: Int
    let label: LocalizedStringResource
    let kind: InlineStatusKind
}

struct OperationResultSummary: View {
    let metrics: [OperationResultMetric]

    @Environment(\.theme) private var theme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: WinstonLayout.space4) { metricViews }
            VStack(alignment: .leading, spacing: WinstonLayout.space2) { metricViews }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var metricViews: some View {
        ForEach(metrics) { metric in
            HStack(spacing: WinstonLayout.space1) {
                Text(metric.value, format: .number)
                    .font(theme.label(size: 11, weight: .bold))
                    .foregroundStyle(color(for: metric.kind))
                    .monospacedDigit()
                Text(metric.label)
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func color(for kind: InlineStatusKind) -> Color {
        switch kind {
        case .information: theme.interaction.information
        case .warning: theme.interaction.warning
        case .error: theme.destructive
        case .success: theme.success
        }
    }
}
