import SwiftUI

struct BookDetailPanel: View {
    let book: Book?
    let multiCount: Int
    var convertibleSelectionCount: Int = 0
    let viewModel: LibraryViewModel
    let actions: BookActions

    var body: some View {
        if multiCount > 1 {
            DetailMultiSelection(count: multiCount, convertibleCount: convertibleSelectionCount, actions: actions)
        } else if let book {
            DetailSingleBook(book: book, viewModel: viewModel, actions: actions)
        } else {
            DetailEmptyState()
        }
    }
}
