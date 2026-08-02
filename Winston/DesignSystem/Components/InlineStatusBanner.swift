import SwiftUI

nonisolated enum InlineStatusKind: Equatable, Sendable {
    case information
    case warning
    case error
    case success
}

struct InlineStatusBanner<Content: View, Actions: View>: View {
    let kind: InlineStatusKind
    let systemImage: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WinstonLayout.space2) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .padding(WinstonLayout.space3)
        .background(
            color.opacity(0.10),
            in: RoundedRectangle(
                cornerRadius: WinstonLayout.radius(.content),
                style: .continuous
            )
        )
        .accessibilityElement(children: .contain)
    }

    private var color: Color {
        switch kind {
        case .information: theme.interaction.information
        case .warning: theme.interaction.warning
        case .error: theme.destructive
        case .success: theme.success
        }
    }
}

extension InlineStatusBanner where Actions == EmptyView {
    init(
        kind: InlineStatusKind,
        systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.kind = kind
        self.systemImage = systemImage
        self.content = content
        actions = { EmptyView() }
    }
}
