import SwiftUI

extension Theme {
    static let black = Theme(
        colorScheme: .dark,
        fontStyle: .native,

        background:    Color(hex: 0x1E1E1E),
        backgroundAlt: Color(hex: 0x2A2A2A),
        surface:       Color(hex: 0x2C2C2E),
        surfaceGlass:  Color(hex: 0x3A3A3C),

        accent:          Color(hex: 0x0A84FF),
        accentSecondary: Color(hex: 0x64D2FF),
        accentTertiary:  Color(hex: 0xBF5AF2),
        highlight:       Color(hex: 0xFFD60A),
        success:         Color(hex: 0x30D158),
        destructive:     Color(hex: 0xFF453A),

        textPrimary:   Color(hex: 0xF5F5F7),
        textSecondary: Color(hex: 0x98989D),
        textTertiary:  Color(hex: 0x636366),

        borderSubtle: Color(hex: 0xFFFFFF, opacity: 0.10),
        borderActive: Color(hex: 0x0A84FF),

        structure: ThemeStructuralRoles(
            content: Color(hex: 0x1E1E1E),
            sidebar: Color(hex: 0x252525),
            toolbar: Color(hex: 0x2A2A2A),
            inspector: Color(hex: 0x252525),
            floating: Color(hex: 0x2C2C2E),
            sheetAction: Color(hex: 0x2A2A2A),
            usesNativeMaterials: true
        ),
        interaction: ThemeInteractionRoles(
            selection: Color(hex: 0x0A84FF, opacity: 0.18),
            focus: Color(hex: 0x64D2FF),
            hover: Color(hex: 0xFFFFFF, opacity: 0.07),
            pressed: Color(hex: 0x0A84FF, opacity: 0.24),
            disabled: Color(hex: 0x98989D, opacity: 0.48),
            warning: Color(hex: 0xFFD60A),
            information: Color(hex: 0x64D2FF)
        ),

        coverPalettes: [
            ColorPair(primary: Color(hex: 0x0A84FF), secondary: Color(hex: 0xBF5AF2)),
            ColorPair(primary: Color(hex: 0x64D2FF), secondary: Color(hex: 0x0A84FF)),
            ColorPair(primary: Color(hex: 0xBF5AF2), secondary: Color(hex: 0x64D2FF)),
        ],

        showsNeonGlow: false,
        showsMeshBackground: false,
        usesTerminalCopy: false,

        copy: .nativeCopy
    )
}
