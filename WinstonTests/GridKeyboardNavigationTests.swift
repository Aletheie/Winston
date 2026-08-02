import Testing
@testable import Winston

@Suite("Grid keyboard navigation")
struct GridKeyboardNavigationTests {
    @Test(arguments: [1, 2, 5])
    func columnCountMatchesSharedAdaptiveGeometry(expectedColumns: Int) {
        let minimum = WinstonLayout.coverGridMinimumWidth(zoom: 0)
        let spacing = WinstonLayout.coverGridSpacing
        let contentWidth = (minimum * CGFloat(expectedColumns))
            + (spacing * CGFloat(max(expectedColumns - 1, 0)))
        let containerWidth = contentWidth
            + (WinstonLayout.coverGridHorizontalPadding * 2)

        #expect(WinstonLayout.coverGridColumnCount(
            containerWidth: containerWidth,
            zoom: 0
        ) == expectedColumns)
    }

    @Test func verticalMovementUsesTheVisualRowWidth() {
        #expect(destination(from: 7, count: 20, columns: 5, .up) == 2)
        #expect(destination(from: 7, count: 20, columns: 5, .down) == 12)
        #expect(destination(from: 2, count: 20, columns: 5, .up) == 2)
    }

    @Test func incompleteLastRowClampsToItsLastVisibleItem() {
        #expect(destination(from: 3, count: 7, columns: 5, .down) == 6)
        #expect(destination(from: 4, count: 7, columns: 5, .down) == 6)
        #expect(destination(from: 6, count: 7, columns: 5, .down) == 6)
        #expect(destination(from: 6, count: 7, columns: 5, .up) == 1)
    }

    @Test func horizontalMovementStaysWithinTheDisplayedArray() {
        #expect(destination(from: 0, count: 7, columns: 5, .left) == 0)
        #expect(destination(from: 6, count: 7, columns: 5, .right) == 6)
        #expect(destination(from: 4, count: 7, columns: 5, .right) == 5)
    }

    @Test func invalidOrEmptyInputsHaveNoDestination() {
        #expect(destination(from: 0, count: 0, columns: 5, .down) == nil)
        #expect(destination(from: -1, count: 3, columns: 2, .right) == nil)
        #expect(destination(from: 3, count: 3, columns: 2, .left) == nil)
    }

    private func destination(
        from index: Int,
        count: Int,
        columns: Int,
        _ direction: GridKeyboardDirection
    ) -> Int? {
        GridKeyboardNavigation.destinationIndex(
            from: index,
            itemCount: count,
            columnCount: columns,
            direction: direction
        )
    }
}
