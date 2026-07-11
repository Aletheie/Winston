import SwiftUI

struct DetailActionButton: View {
    let title: Text
    let icon: String
    let color: Color
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
                title
                    .font(theme.label(size: 9, weight: .semibold))
            }
            .foregroundStyle(isHovered ? color : theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(isHovered ? color.opacity(0.6) : theme.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }
}
