import SwiftUI

struct HighlightsReviewView: View {
    let model: HighlightsWorkspaceModel
    let onToggleFavorite: (HighlightWorkspaceItem) -> Void
    let onBack: () -> Void
    let onAdvance: () -> Void
    let onReviewAgain: () -> Void
    let onReturnToLibrary: () -> Void

    var body: some View {
        if model.reviewCompleted {
            HighlightsReviewCompletion(
                reviewedCount: model.reviewedInLastSession,
                onReviewAgain: onReviewAgain,
                onReturnToLibrary: onReturnToLibrary
            )
        } else if let item = model.currentReviewItem {
            HighlightReviewSession(
                item: item,
                model: model,
                onToggleFavorite: { onToggleFavorite(item) },
                onBack: onBack,
                onAdvance: onAdvance
            )
        } else {
            HighlightsReviewEmptyState(
                hasAnyHighlights: model.totalCount > 0,
                onReturnToLibrary: onReturnToLibrary
            )
        }
    }
}

private struct HighlightReviewSession: View {
    let item: HighlightWorkspaceItem
    let model: HighlightsWorkspaceModel
    let onToggleFavorite: () -> Void
    let onBack: () -> Void
    let onAdvance: () -> Void

    private var isLast: Bool {
        model.reviewIndex + 1 == model.reviewItems.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HighlightReviewProgress(
                current: model.reviewProgress.current,
                total: model.reviewProgress.total
            )
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: WinstonLayout.space5) {
                    HighlightInspectorHeader(
                        item: item,
                        onToggleFavorite: onToggleFavorite
                    )
                    HighlightSourceBlock(item: item)
                    HighlightEditorFields(model: model)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(WinstonLayout.space5)
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: WinstonLayout.space3) {
                Button("Back", action: onBack)
                    .disabled(!model.canMoveBackInReview)
                Spacer()
                Text("Next saves this reflection and marks the passage as reviewed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                Button(isLast ? "Finish" : "Next", action: onAdvance)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("highlights.review.advance")
            }
            .padding(WinstonLayout.space4)
            .themedChrome(role: .inspector)
        }
    }
}

private struct HighlightReviewProgress: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: WinstonLayout.space3) {
            Label("Review Session", systemImage: "rectangle.stack")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("highlights.review.session")
            ProgressView(value: Double(current), total: Double(max(total, 1)))
                .accessibilityLabel("Review progress")
                .accessibilityValue(Text(
                    "\(current) of \(total)",
                    comment: "Review progress; first value is current, second is total."
                ))
            Text(
                "\(current) of \(total)",
                comment: "Review progress; first value is current, second is total."
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, WinstonLayout.space4)
        .padding(.vertical, WinstonLayout.space3)
        .themedChrome(role: .toolbar)
    }
}

private struct HighlightsReviewCompletion: View {
    let reviewedCount: Int
    let onReviewAgain: () -> Void
    let onReturnToLibrary: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        ContentUnavailableView {
            Label("Review Complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(theme.success)
                .accessibilityIdentifier("highlights.review.complete")
        } description: {
            Text(
                "You revisited \(reviewedCount) highlights.",
                comment: "Review completion message; the value is the number of reviewed highlights."
            )
        } actions: {
            HStack {
                Button("Back to Library", action: onReturnToLibrary)
                Button("Review Another Set", action: onReviewAgain)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct HighlightsReviewEmptyState: View {
    let hasAnyHighlights: Bool
    let onReturnToLibrary: () -> Void

    var body: some View {
        ContentUnavailableView {
            if hasAnyHighlights {
                Label("No Highlights in This View", systemImage: "rectangle.stack")
            } else {
                Label("No Highlights Yet", systemImage: "rectangle.stack")
            }
        } description: {
            if hasAnyHighlights {
                Text("Change the search or filters in Library, then start Review again.")
            } else {
                Text("Import highlights from a connected Kindle before starting a review.")
            }
        } actions: {
            Button("Back to Library", action: onReturnToLibrary)
        }
    }
}
