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
