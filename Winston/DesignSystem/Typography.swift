import SwiftUI
import AppKit

extension Font {
    static func winstonDisplay(
        size: CGFloat,
        weight: Weight = .heavy,
        relativeTo textStyle: TextStyle
    ) -> Font {
        .custom("SF Pro Rounded", size: size, relativeTo: textStyle).weight(weight)
    }

    static func winstonBody(
        size: CGFloat,
        weight: Weight = .medium,
        relativeTo textStyle: TextStyle
    ) -> Font {
        .custom("SF Pro Text", size: size, relativeTo: textStyle).weight(weight)
    }

    private static let hasJetBrainsMono = NSFontManager.shared.availableFontFamilies.contains("JetBrains Mono")

    static func winstonMono(
        size: CGFloat,
        weight: Weight = .medium,
        relativeTo textStyle: TextStyle
    ) -> Font {
        hasJetBrainsMono
            ? .custom("JetBrains Mono", size: size, relativeTo: textStyle).weight(weight)
            : .system(textStyle, design: .monospaced, weight: weight)
    }
}
