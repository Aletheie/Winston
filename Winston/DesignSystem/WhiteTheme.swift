import SwiftUI

extension Theme {
    static let white = Theme(
        colorScheme: .light,
        fontStyle: .native,

        background:    Color(hex: 0xF5F5F7),
        backgroundAlt: Color(hex: 0xFFFFFF),
        surface:       Color(hex: 0xFFFFFF),
        surfaceGlass:  Color(hex: 0xFFFFFF),

        accent:          Color(hex: 0x5E5CE6),
        accentSecondary: Color(hex: 0x007AFF),
        accentTertiary:  Color(hex: 0xAF52DE),
        highlight:       Color(hex: 0xFFB300),
        success:         Color(hex: 0x34C759),
        destructive:     Color(hex: 0xFF3B30),

        textPrimary:   Color(hex: 0x1D1D1F),
        textSecondary: Color(hex: 0x6E6E73),
        textTertiary:  Color(hex: 0xAEAEB2),

        borderSubtle: Color(hex: 0x000000, opacity: 0.08),
        borderActive: Color(hex: 0x5E5CE6),

        structure: ThemeStructuralRoles(
            content: Color(hex: 0xF5F5F7),
            sidebar: Color(hex: 0xF0F0F2),
            toolbar: Color(hex: 0xFFFFFF),
            inspector: Color(hex: 0xFAFAFC),
            floating: Color(hex: 0xFFFFFF),
            sheetAction: Color(hex: 0xFFFFFF),
            usesNativeMaterials: true
        ),
        interaction: ThemeInteractionRoles(
            selection: Color(hex: 0x5E5CE6, opacity: 0.14),
            focus: Color(hex: 0x007AFF),
            hover: Color(hex: 0x000000, opacity: 0.045),
            pressed: Color(hex: 0x5E5CE6, opacity: 0.20),
            disabled: Color(hex: 0x6E6E73, opacity: 0.46),
            warning: Color(hex: 0x9A6700),
            information: Color(hex: 0x007AFF)
        ),

        coverPalettes: [
            ColorPair(primary: Color(hex: 0x5E5CE6), secondary: Color(hex: 0xAF52DE)),
            ColorPair(primary: Color(hex: 0x007AFF), secondary: Color(hex: 0x5E5CE6)),
            ColorPair(primary: Color(hex: 0xAF52DE), secondary: Color(hex: 0x007AFF)),
        ],

        showsNeonGlow: false,
        showsMeshBackground: false,
        usesTerminalCopy: false,

        copy: .nativeCopy
    )
}
