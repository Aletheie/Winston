import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class WishlistService {
    private let modelContext: ModelContext
    private let toasts: ToastCenter

    private(set) var items: [WishlistItem]
    @ObservationIgnored private var cachedLibraryKeys: Set<BookMatchKey> = []
    @ObservationIgnored private var cachedLibraryRevision = -1

    init(modelContext: ModelContext, toasts: ToastCenter) {
        self.modelContext = modelContext
        self.toasts = toasts
        let descriptor = FetchDescriptor<WishlistItem>(
            sortBy: [SortDescriptor(\WishlistItem.dateAdded, order: .reverse)]
        )
        self.items = (try? modelContext.fetch(descriptor)) ?? []
        ensureSystemCollection()
    }

    var count: Int { items.count }

    func contains(_ book: DiscoveryBook) -> Bool {
        matchingItem(for: book) != nil
    }

    func toggle(_ book: DiscoveryBook) {
        if let item = matchingItem(for: book) {
            remove(item)
        } else {
            add(book)
        }
    }

    @discardableResult
    func add(_ book: DiscoveryBook) -> Bool {
        guard matchingItem(for: book) == nil else { return false }

        let key = BookMatchKey(title: book.title, author: book.author)
        if key.isComplete, libraryKeys().contains(key) {
            toasts.info(String(localized: "This book is already in your library."))
            return false
        }

        let item = WishlistItem(
            hardcoverID: book.id,
            title: book.title,
            author: book.author,
            coverURL: book.coverURL,
            hardcoverURL: book.hardcoverURL,
            rating: book.rating
        )
        modelContext.insert(item)
        items.insert(item, at: 0)
        modelContext.saveQuietly(catalogChanged: false)
        toasts.success(String(localized: "Added to Wishlist."))
        return true
    }

    func remove(_ item: WishlistItem) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        items.removeAll { $0.id == item.id }
        modelContext.delete(item)
        modelContext.saveQuietly(catalogChanged: false)
        toasts.info(String(localized: "Removed from Wishlist."))
    }

    @discardableResult
    func fulfil(with importedBooks: [Book]) -> Int {
        let importedKeys = Set(importedBooks.compactMap { book -> BookMatchKey? in
            let key = BookMatchKey(title: book.displayTitle, author: book.displayAuthor)
            return key.isComplete ? key : nil
        })
        guard !importedKeys.isEmpty else { return 0 }

        let fulfilledItems = items.filter { item in
            let key = item.matchKey
            return key.isComplete && importedKeys.contains(key)
        }
        guard !fulfilledItems.isEmpty else { return 0 }

        let fulfilledIDs = Set(fulfilledItems.map(\.id))
        let fulfilledBookCount = Set(fulfilledItems.map(\.matchKey)).count
        items.removeAll { fulfilledIDs.contains($0.id) }
        for item in fulfilledItems { modelContext.delete(item) }
        modelContext.saveQuietly(catalogChanged: false)

        if fulfilledBookCount == 1 {
            toasts.success(String(localized: "A book from your Wishlist is now in your library."))
        } else {
            toasts.success(String(localized: "Books from your Wishlist are now in your library."))
        }
        return fulfilledBookCount
    }

    private func matchingItem(for book: DiscoveryBook) -> WishlistItem? {
        if let byID = items.first(where: { $0.hardcoverID == book.id }) { return byID }
        let key = BookMatchKey(title: book.title, author: book.author)
        guard key.isComplete else { return nil }
        return items.first { $0.matchKey == key }
    }

    private func libraryKeys() -> Set<BookMatchKey> {
        let revision = LibraryMutationLog.shared.catalogRevision
        if cachedLibraryRevision != revision {
            cachedLibraryKeys = Set(modelContext.allBooks().compactMap { book in
                let key = BookMatchKey(title: book.displayTitle, author: book.displayAuthor)
                return key.isComplete ? key : nil
            })
            cachedLibraryRevision = revision
        }
        return cachedLibraryKeys
    }

    private func ensureSystemCollection() {
        let collections = (try? modelContext.fetch(FetchDescriptor<BookCollection>())) ?? []
        guard !collections.contains(where: { $0.isWishlist }) else { return }
        modelContext.insert(BookCollection(name: "Wishlist", systemKind: .wishlist))
        modelContext.saveQuietly(catalogChanged: false)
    }
}
