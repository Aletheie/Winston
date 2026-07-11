import SwiftUI

nonisolated enum WinstonLayout {
    static let coverAspect: CGFloat = 2.0 / 3.0

    static let cornerSmall: CGFloat = 5
    static let cornerMedium: CGFloat = 8
    static let cornerLarge: CGFloat = 12

    static let dividerOpacity: Double = 0.25

    static func coverGridColumns(zoom: Double) -> [GridItem] {
        let minimum = 140 + (300 - 140) * zoom
        let maximum = 220 + (460 - 220) * zoom
        return [GridItem(.adaptive(minimum: minimum, maximum: maximum), spacing: 14)]
    }
}
