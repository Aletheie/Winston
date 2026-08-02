import SwiftUI

struct LibraryDropZone: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge, style: .continuous)
                .fill(theme.structuralColor(for: .floating))

            RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge, style: .continuous)
                .stroke(
                    theme.interaction.focus,
                    style: StrokeStyle(lineWidth: 2, dash: [10, 6])
                )

            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.interaction.focus)
                    .accessibilityHidden(true)
                Text(theme.copy.dropActive)
                    .font(theme.label(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(theme.copy.dropFormats)
                    .font(theme.label(size: 11, weight: .regular))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .frame(maxWidth: 620, maxHeight: 180)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        .allowsHitTesting(false)
        .accessibilityLabel("Drop zone for book files")
    }
}
