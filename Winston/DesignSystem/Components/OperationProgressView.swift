import AppKit
import SwiftUI

nonisolated enum OperationProgressMilestones {
    static func milestone(completedCount: Int, totalCount: Int) -> Int? {
        guard totalCount > 0 else { return nil }
        let boundedCompleted = min(max(0, completedCount), totalCount)
        if boundedCompleted == totalCount { return 100 }
        let percentage = Int(
            floor((Double(boundedCompleted) / Double(totalCount)) * 100)
        )
        return (percentage / 25) * 25
    }
}

struct OperationProgressView: View {
    let title: Text
    let detail: Text?
    let value: Double
    let completedCount: Int
    let totalCount: Int
    let accessibilityLabel: Text
    let accessibilityValue: Text
    let announcementName: String
    let cancelLabel: Text?
    let canCancel: Bool
    let onCancel: (() -> Void)?

    @Environment(\.theme) private var theme
    @State private var lastAnnouncedMilestone: Int?

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
        .onAppear {
            lastAnnouncedMilestone = currentMilestone
        }
        .onChange(of: currentMilestone) { oldValue, newValue in
            guard let newValue,
                  newValue != oldValue,
                  newValue != lastAnnouncedMilestone else { return }
            lastAnnouncedMilestone = newValue
            announce(newValue)
        }
    }

    private var currentMilestone: Int? {
        OperationProgressMilestones.milestone(
            completedCount: completedCount,
            totalCount: totalCount
        )
    }

    private func announce(_ milestone: Int) {
        let message = String(
            localized: "\(announcementName), \(milestone) percent complete"
        )
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}
