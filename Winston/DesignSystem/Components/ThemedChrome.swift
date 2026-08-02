import SwiftUI

nonisolated enum ThemedChromeMaterialStyle: Equatable, Sendable {
    case none
    case bar
    case thin
    case regular
}

struct ThemedChromePresentation: Equatable {
    let role: ThemeStructuralRole
    let opaqueFill: Color
    let material: ThemedChromeMaterialStyle
    let borderColor: Color
    let borderWidth: CGFloat
    let elevation: WinstonLayout.Elevation

    var usesMaterial: Bool { material != .none }

    static func resolve(
        theme: Theme,
        role: ThemeStructuralRole,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> ThemedChromePresentation {
        let permitsMaterial = theme.structure.usesNativeMaterials
            && !reduceTransparency
            && role != .content
        let material: ThemedChromeMaterialStyle = if permitsMaterial {
            switch role {
            case .content: .none
            case .sidebar, .toolbar, .sheetAction: .bar
            case .inspector: .thin
            case .floating: .regular
            }
        } else {
            .none
        }
        let normallyBordered = role == .inspector || role == .floating
        let borderWidth: CGFloat = increaseContrast
            ? 1.5
            : (normallyBordered ? 1 : 0)
        let elevationRole: WinstonLayout.ElevationRole = role == .floating
            ? .floating
            : .flat
        return ThemedChromePresentation(
            role: role,
            opaqueFill: theme.structuralColor(for: role),
            material: material,
            borderColor: increaseContrast
                ? theme.textSecondary.opacity(0.72)
                : theme.borderSubtle,
            borderWidth: borderWidth,
            elevation: WinstonLayout.elevation(elevationRole)
        )
    }
}

private struct ThemedChromeModifier: ViewModifier {
    let role: ThemeStructuralRole
    let cornerRadius: CGFloat

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let presentation = ThemedChromePresentation.resolve(
            theme: theme,
            role: role,
            reduceTransparency: reduceTransparency,
            increaseContrast: contrast == .increased
        )
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )
        content
            .background(fill(for: presentation), in: shape)
            .overlay {
                if presentation.borderWidth > 0 {
                    shape.stroke(
                        presentation.borderColor,
                        lineWidth: presentation.borderWidth
                    )
                }
            }
            .shadow(
                color: .black.opacity(presentation.elevation.opacity),
                radius: presentation.elevation.radius,
                y: presentation.elevation.y
            )
    }

    private func fill(
        for presentation: ThemedChromePresentation
    ) -> AnyShapeStyle {
        switch presentation.material {
        case .none: AnyShapeStyle(presentation.opaqueFill)
        case .bar: AnyShapeStyle(.bar)
        case .thin: AnyShapeStyle(.thinMaterial)
        case .regular: AnyShapeStyle(.regularMaterial)
        }
    }
}

extension View {
    func themedChrome(
        role: ThemeStructuralRole,
        cornerRadius: CGFloat = 0
    ) -> some View {
        modifier(ThemedChromeModifier(role: role, cornerRadius: cornerRadius))
    }
}

struct SheetHeader<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(WinstonLayout.space4)
            .themedChrome(role: .toolbar)
    }
}
