import SwiftUI

struct SheetActionBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(WinstonLayout.space3)
            .themedChrome(role: .sheetAction)
            .overlay(alignment: .top) { Divider() }
    }
}
