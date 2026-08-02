import SwiftUI

nonisolated enum WinstonLayout {
    enum RadiusRole: Sendable {
        case control
        case content
        case structural
    }

    enum ElevationRole: Sendable {
        case flat
        case raised
        case floating
    }

    struct Elevation: Equatable, Sendable {
        let opacity: Double
        let radius: CGFloat
        let y: CGFloat
    }

    static let coverAspect: CGFloat = 2.0 / 3.0

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 24
    static let space6: CGFloat = 32

    static let cornerSmall: CGFloat = 5
    static let cornerMedium: CGFloat = 8
    static let cornerLarge: CGFloat = 12

    static let dividerOpacity: Double = 0.25
    static let coverGridSpacing: CGFloat = 14
    static let coverGridHorizontalPadding: CGFloat = 14

    static func radius(_ role: RadiusRole) -> CGFloat {
        switch role {
        case .control: cornerSmall
        case .content: cornerMedium
        case .structural: cornerLarge
        }
    }

    static func elevation(_ role: ElevationRole) -> Elevation {
        switch role {
        case .flat: Elevation(opacity: 0, radius: 0, y: 0)
        case .raised: Elevation(opacity: 0.12, radius: 4, y: 1)
        case .floating: Elevation(opacity: 0.16, radius: 8, y: 3)
        }
    }

    static func coverGridMinimumWidth(zoom: Double) -> CGFloat {
        140 + (300 - 140) * zoom
    }

    static func coverGridColumns(zoom: Double) -> [GridItem] {
        let minimum = coverGridMinimumWidth(zoom: zoom)
        let maximum = 220 + (460 - 220) * zoom
        return [GridItem(.adaptive(minimum: minimum, maximum: maximum), spacing: coverGridSpacing)]
    }

    static func coverGridColumnCount(containerWidth: CGFloat, zoom: Double) -> Int {
        let contentWidth = max(
            containerWidth - (coverGridHorizontalPadding * 2),
            0
        )
        let minimum = coverGridMinimumWidth(zoom: zoom)
        return max(
            Int((contentWidth + coverGridSpacing) / (minimum + coverGridSpacing)),
            1
        )
    }
}
