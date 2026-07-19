import SwiftUI

// MARK: - Background

struct ThemedBackground: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if theme.showsMeshBackground && !reduceTransparency {
            meshBackground
        } else {
            theme.background.ignoresSafeArea()
        }
    }

    private var meshBackground: some View {
        GeometryReader { proxy in
            let maxDim = max(proxy.size.width, proxy.size.height)

            ZStack {
                theme.background

                Rectangle()
                    .fill(RadialGradient(
                        colors: [theme.accent.opacity(0.22), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: maxDim * 0.85
                    ))
                    .blur(radius: 90)
                    .offset(x: -maxDim * 0.15, y: -maxDim * 0.2)

                Rectangle()
                    .fill(RadialGradient(
                        colors: [theme.accentSecondary.opacity(0.16), .clear],
                        center: .bottomTrailing,
                        startRadius: 0,
                        endRadius: maxDim * 0.9
                    ))
                    .blur(radius: 90)
                    .offset(x: maxDim * 0.15, y: maxDim * 0.2)

                Rectangle()
                    .fill(RadialGradient(
                        colors: [theme.accentTertiary.opacity(0.10), .clear],
                        center: .init(x: 0.2, y: 0.65),
                        startRadius: 0,
                        endRadius: maxDim * 0.6
                    ))
                    .blur(radius: 80)
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Modifiers

private struct NeonGlowModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let color: Color
    let radius: CGFloat
    let intensity: Double

    func body(content: Content) -> some View {
        if theme.showsNeonGlow {
            content
                .shadow(color: color.opacity(intensity * 0.9), radius: radius * 0.35)
                .shadow(color: color.opacity(intensity * 0.6), radius: radius)
                .shadow(color: color.opacity(intensity * 0.28), radius: radius * 2.4)
        } else {
            content
        }
    }
}

private struct GlassCardModifier: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let cornerRadius: CGFloat
    let tintOpacity: Double

    func body(content: Content) -> some View {
        content
            .background(
                reduceTransparency
                    ? AnyShapeStyle(theme.surface)
                    : AnyShapeStyle(.ultraThinMaterial),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(theme.surfaceGlass.opacity(tintOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        contrast == .increased ? theme.textSecondary.opacity(0.55) : theme.borderSubtle,
                        lineWidth: contrast == .increased ? 2 : 1
                    )
            )
    }
}

private struct AccessibleThemeModifier: ViewModifier {
    let theme: Theme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        var adapted = theme
        if contrast == .increased {
            adapted.textTertiary = theme.textSecondary
            adapted.borderSubtle = theme.textSecondary.opacity(0.45)
        }
        return content.environment(\.theme, adapted)
    }
}

private struct BorderGlowModifier: ViewModifier {
    let active: Bool
    let color: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(active ? color.opacity(0.45) : .clear, lineWidth: active ? 2 : 0)
                    .shadow(color: active ? color.opacity(0.6) : .clear, radius: active ? 16 : 0)
            )
    }
}

private struct ThemedBorderModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(theme.borderSubtle, lineWidth: 1)
        }
    }
}

// MARK: - Shimmer (skeleton loading)

private struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.45), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.55)
                    .offset(x: phase * geo.size.width * 1.8)
                    .blendMode(.plusLighter)
                }
                .allowsHitTesting(false)
            }
            .onAppear {
                startAnimation()
            }
            .onChange(of: reduceMotion) { _, shouldReduce in
                if shouldReduce { phase = -1 } else { startAnimation() }
            }
    }

    private func startAnimation() {
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

extension View {
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}

// MARK: - View extensions

extension View {
    func neonGlow(color: Color, radius: CGFloat = 12, intensity: Double = 0.7) -> some View {
        modifier(NeonGlowModifier(color: color, radius: radius, intensity: intensity))
    }

    func glassCard(cornerRadius: CGFloat = 12, tintOpacity: Double = 0.6) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, tintOpacity: tintOpacity))
    }

    func borderGlow(active: Bool, color: Color, cornerRadius: CGFloat = 12) -> some View {
        modifier(BorderGlowModifier(active: active, color: color, cornerRadius: cornerRadius))
    }

    func themedBorder(cornerRadius: CGFloat) -> some View {
        modifier(ThemedBorderModifier(cornerRadius: cornerRadius))
    }

    func accessibleTheme(_ theme: Theme) -> some View {
        modifier(AccessibleThemeModifier(theme: theme))
    }
}
