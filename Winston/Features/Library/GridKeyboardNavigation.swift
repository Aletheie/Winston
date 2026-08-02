import Foundation

nonisolated enum GridKeyboardDirection: Sendable {
    case left
    case right
    case up
    case down
}

nonisolated enum GridKeyboardNavigation {
    static func destinationIndex(
        from currentIndex: Int,
        itemCount: Int,
        columnCount: Int,
        direction: GridKeyboardDirection
    ) -> Int? {
        guard itemCount > 0,
              currentIndex >= 0,
              currentIndex < itemCount else { return nil }
        let columns = max(columnCount, 1)

        switch direction {
        case .left:
            return max(currentIndex - 1, 0)
        case .right:
            return min(currentIndex + 1, itemCount - 1)
        case .up:
            return currentIndex >= columns
                ? currentIndex - columns
                : currentIndex
        case .down:
            let candidate = currentIndex + columns
            if candidate < itemCount { return candidate }

            let lastRowStart = ((itemCount - 1) / columns) * columns
            if currentIndex < lastRowStart {
                return itemCount - 1
            }
            return currentIndex
        }
    }
}
