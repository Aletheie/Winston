import Foundation
import Observation
import OSLog
import SwiftData

@MainActor
@Observable
final class WishlistService {
    private let modelContext: ModelContext
    private let toasts: ToastCenter
    private let mutations: CatalogMutationService

    private(set) var items: [WishlistItem]
    private(set) var lastLoadError: String?

    init(
        modelContext: ModelContext,
        toasts: ToastCenter,
        mutations: CatalogMutationService? = nil
    ) {
        self.modelContext = modelContext
        self.toasts = toasts
        self.mutations = mutations ?? CatalogMutationService(modelContext: modelContext)
        let descriptor = FetchDescriptor<WishlistItem>(
            sortBy: [SortDescriptor(\WishlistItem.dateAdded, order: .reverse)]
        )
        do {
            self.items = try modelContext.fetch(descriptor)
            self.lastLoadError = nil
        } catch {
            self.items = []
            self.lastLoadError = error.localizedDescription
            Log.persistence.error(
                "Initial Wishlist fetch failed: \(error.localizedDescription, privacy: .public)"
            )
        }
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
        if key.isComplete {
            do {
                if try libraryContains(book, key: key) {
                    toasts.info(String(localized: "This book is already in your library."))
                    return false
                }
                lastLoadError = nil
            } catch {
                lastLoadError = error.localizedDescription
                toasts.error(String(localized: "Couldn’t check the library catalog."))
                return false
            }
        }

        var insertedItem: WishlistItem?
        do {
            try mutations.commitPrepared(
                .updateAuxiliaryStore(operation: "wishlistAdd"),
                catalogChanged: false
            ) { writeContext in
                let storedItems = try writeContext.fetch(FetchDescriptor<WishlistItem>())
                guard !storedItems.contains(where: {
                    $0.hardcoverID == book.id
                        || (key.isComplete && $0.matchKey == key)
                }) else {
                    throw CatalogMutationError.invalidRequest
                }
                let item = WishlistItem(
                    hardcoverID: book.id,
                    title: book.title,
                    author: book.author,
                    coverURL: book.coverURL,
                    hardcoverURL: book.hardcoverURL,
                    rating: book.rating
                )
                writeContext.insert(item)
                insertedItem = item
            }
        } catch {
            toasts.error(String(localized: "Could not update Wishlist."))
            return false
        }
        guard let item = insertedItem else { return false }
        items.insert(item, at: 0)
        toasts.success(String(localized: "Added to Wishlist."))
        return true
    }

    func remove(_ item: WishlistItem) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        let itemID = item.id
        do {
            try mutations.commitPrepared(
                .updateAuxiliaryStore(operation: "wishlistRemove"),
                catalogChanged: false
            ) { writeContext in
                let matches = try writeContext.fetch(FetchDescriptor<WishlistItem>(
                    predicate: #Predicate { $0.id == itemID }
                ))
                guard let stored = matches.first else {
                    throw CatalogMutationError.modelNotFound
                }
                writeContext.delete(stored)
            }
        } catch {
            toasts.error(String(localized: "Could not update Wishlist."))
            return
        }
        items.removeAll { $0.id == item.id }
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
        do {
            try mutations.commitPrepared(
                .updateAuxiliaryStore(operation: "wishlistFulfil"),
                catalogChanged: false
            ) { writeContext in
                let storedItems = try writeContext.fetch(FetchDescriptor<WishlistItem>())
                let fulfilled = storedItems.filter { fulfilledIDs.contains($0.id) }
                guard fulfilled.count == fulfilledIDs.count else {
                    throw CatalogMutationError.modelNotFound
                }
                fulfilled.forEach(writeContext.delete)
            }
        } catch {
            toasts.error(String(localized: "Could not update Wishlist."))
            return 0
        }
        items.removeAll { fulfilledIDs.contains($0.id) }

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

    private func libraryContains(
        _ discoveryBook: DiscoveryBook,
        key: BookMatchKey
    ) throws -> Bool {
        let storageKey = key.storageValue
        var workDescriptor = FetchDescriptor<Work>(
            predicate: #Predicate { $0.matchKey == storageKey }
        )
        workDescriptor.fetchLimit = 1
        if try !modelContext.fetch(workDescriptor).isEmpty {
            return true
        }

        // Legacy editions may not have their Work relation backfilled yet.
        // Keep the compatibility lookup targeted to the exact source values.
        let title: String? = discoveryBook.title
        let author: String? = discoveryBook.author
        var bookDescriptor = FetchDescriptor<Book>(
            predicate: #Predicate {
                $0.title == title && $0.author == author
            }
        )
        bookDescriptor.fetchLimit = 1
        return try !modelContext.fetch(bookDescriptor).isEmpty
    }

    private func ensureSystemCollection() {
        do {
            let collections = try modelContext.fetch(FetchDescriptor<BookCollection>())
            guard !collections.contains(where: { $0.isWishlist }) else { return }
            try mutations.commitPrepared(
                .updateAuxiliaryStore(operation: "ensureWishlistCollection"),
                catalogChanged: false
            ) { writeContext in
                let stored = try writeContext.fetch(FetchDescriptor<BookCollection>())
                guard !stored.contains(where: { $0.isWishlist }) else { return }
                writeContext.insert(BookCollection(
                    name: "Wishlist",
                    systemKind: .wishlist
                ))
            }
        } catch {
            lastLoadError = error.localizedDescription
            Log.persistence.error(
                "Could not create the Wishlist system collection: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
