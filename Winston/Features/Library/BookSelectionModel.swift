import AppKit
import Observation
import SwiftData

@MainActor
@Observable
final class BookSelectionModel {
    var selectedBookIDs: Set<Book.ID> = []
    var lastClickedBookID: Book.ID?

    var hasSelection: Bool { !selectedBookIDs.isEmpty }
    var count: Int { selectedBookIDs.count }

    func isSelected(_ book: Book) -> Bool {
        selectedBookIDs.contains(book.id)
    }

    func primaryBook(in books: [Book]) -> Book? {
        let id = lastClickedBookID.flatMap { selectedBookIDs.contains($0) ? $0 : nil }
            ?? selectedBookIDs.first
        guard let id else { return nil }
        return books.first { $0.id == id }
    }

    @discardableResult
    func handleClick(on book: Book, in displayedBooks: [Book]) -> Bool {
        let modifiers = NSEvent.modifierFlags

        if modifiers.contains(.command) {
            if selectedBookIDs.contains(book.id) {
                selectedBookIDs.remove(book.id)
            } else {
                selectedBookIDs.insert(book.id)
            }
            lastClickedBookID = book.id
            return false
        }

        if modifiers.contains(.shift), let anchor = lastClickedBookID {
            guard let anchorIdx = displayedBooks.firstIndex(where: { $0.id == anchor }),
                  let clickIdx = displayedBooks.firstIndex(where: { $0.id == book.id }) else { return false }
            for i in min(anchorIdx, clickIdx) ... max(anchorIdx, clickIdx) {
                selectedBookIDs.insert(displayedBooks[i].id)
            }
            return false
        }

        selectedBookIDs = [book.id]
        lastClickedBookID = book.id
        return true
    }

    func selectAll(_ books: [Book]) {
        selectedBookIDs = Set(books.map(\.id))
    }

    func remove(_ id: Book.ID) {
        selectedBookIDs.remove(id)
        if lastClickedBookID == id { lastClickedBookID = nil }
    }

    func clear() {
        selectedBookIDs.removeAll()
        lastClickedBookID = nil
    }
}
