import SwiftUI
import Testing
@testable import Winston

@MainActor
@Suite("Design system semantic tokens")
struct DesignSystemTokenTests {
    @Test func everyThemeResolvesEveryStructuralRole() {
        for theme in [Theme.black, .white, .purple] {
            let resolved = ThemeStructuralRole.allCases.map {
                theme.structuralColor(for: $0)
            }

            #expect(resolved.count == ThemeStructuralRole.allCases.count)
            #expect(theme.structuralColor(for: .content) == theme.structure.content)
            #expect(theme.structuralColor(for: .sidebar) == theme.structure.sidebar)
            #expect(theme.structuralColor(for: .toolbar) == theme.structure.toolbar)
            #expect(theme.structuralColor(for: .inspector) == theme.structure.inspector)
            #expect(theme.structuralColor(for: .floating) == theme.structure.floating)
            #expect(theme.structuralColor(for: .sheetAction) == theme.structure.sheetAction)
        }
    }

    @Test func purpleUsesExplicitOpaqueChromeWhileNativeThemesUseMaterial() {
        for role in ThemeStructuralRole.allCases {
            let purple = ThemedChromePresentation.resolve(
                theme: .purple,
                role: role,
                reduceTransparency: false,
                increaseContrast: false
            )
            #expect(!purple.usesMaterial)
            #expect(purple.opaqueFill == Theme.purple.structuralColor(for: role))
        }

        for theme in [Theme.black, .white] {
            #expect(ThemedChromePresentation.resolve(
                theme: theme,
                role: .toolbar,
                reduceTransparency: false,
                increaseContrast: false
            ).usesMaterial)
            #expect(!ThemedChromePresentation.resolve(
                theme: theme,
                role: .content,
                reduceTransparency: false,
                increaseContrast: false
            ).usesMaterial)
        }
    }

    @Test func reduceTransparencyAlwaysSelectsReadableOpaqueFallback() {
        for theme in [Theme.black, .white, .purple] {
            for role in ThemeStructuralRole.allCases {
                let presentation = ThemedChromePresentation.resolve(
                    theme: theme,
                    role: role,
                    reduceTransparency: true,
                    increaseContrast: false
                )

                #expect(!presentation.usesMaterial)
                #expect(presentation.opaqueFill == theme.structuralColor(for: role))
            }
        }
    }

    @Test func increasedContrastMakesStructuralBoundariesExplicit() {
        for theme in [Theme.black, .white, .purple] {
            for role in ThemeStructuralRole.allCases {
                let normal = ThemedChromePresentation.resolve(
                    theme: theme,
                    role: role,
                    reduceTransparency: false,
                    increaseContrast: false
                )
                let increased = ThemedChromePresentation.resolve(
                    theme: theme,
                    role: role,
                    reduceTransparency: false,
                    increaseContrast: true
                )

                #expect(increased.borderWidth >= normal.borderWidth)
                #expect(increased.borderWidth > 0)
            }
        }
    }

    @Test func spacingRadiusAndElevationScalesRemainMonotonic() {
        #expect(WinstonLayout.space1 < WinstonLayout.space2)
        #expect(WinstonLayout.space2 < WinstonLayout.space3)
        #expect(WinstonLayout.space3 < WinstonLayout.space4)
        #expect(WinstonLayout.space4 < WinstonLayout.space5)
        #expect(WinstonLayout.space5 < WinstonLayout.space6)
        #expect(WinstonLayout.radius(.control) < WinstonLayout.radius(.content))
        #expect(WinstonLayout.radius(.content) < WinstonLayout.radius(.structural))
        #expect(WinstonLayout.elevation(.flat).radius == 0)
        #expect(WinstonLayout.elevation(.raised).radius
            < WinstonLayout.elevation(.floating).radius)
    }
}
