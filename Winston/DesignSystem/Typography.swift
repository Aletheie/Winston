import SwiftUI
import AppKit

extension Font {
    static func winstonDisplay(size: CGFloat, weight: Weight = .heavy) -> Font {
        .custom("SF Pro Rounded", size: size).weight(weight)
    }

    static func winstonBody(size: CGFloat, weight: Weight = .medium) -> Font {
        .custom("SF Pro Text", size: size).weight(weight)
    }

    private static let hasJetBrainsMono = NSFontManager.shared.availableFontFamilies.contains("JetBrains Mono")

    static func winstonMono(size: CGFloat, weight: Weight = .medium) -> Font {
        hasJetBrainsMono
            ? .custom("JetBrains Mono", size: size).weight(weight)
            : .system(size: size, weight: weight, design: .monospaced)
    }
}
