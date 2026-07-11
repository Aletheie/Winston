import SwiftUI
import UniformTypeIdentifiers

struct LibraryDropZone: View {
    @Binding var isTargeted: Bool
    let onDrop: ([NSItemProvider]) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: isTargeted ? 14 : 8, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        theme.accent.opacity(isTargeted ? 0.07 : 0),
                        theme.accentSecondary.opacity(isTargeted ? 0.07 : 0),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))

            RoundedRectangle(cornerRadius: isTargeted ? 14 : 8, style: .continuous)
                .stroke(
                    isTargeted ? theme.borderActive : theme.borderSubtle,
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [10, 6])
                )

            if isTargeted {
                VStack(spacing: 6) {
                    Text(theme.copy.dropActive)
                        .font(theme.label(size: 14))
                        .foregroundStyle(theme.textPrimary)
                    Text(theme.copy.dropFormats)
                        .font(theme.label(size: 11, weight: .regular))
                        .foregroundStyle(theme.textTertiary)
                }
            } else {
                Text(theme.copy.dropIdle)
                    .font(theme.label(size: 10, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(maxWidth: 720)
        .frame(height: isTargeted ? 72 : 30)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: isTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            onDrop(providers)
            return true
        }
        .accessibilityLabel("Drop zone for book files")
    }
}
