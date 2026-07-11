import Foundation
import SwiftData

enum BookCollectionSystemKind: String, Codable, Sendable {
    case wishlist
}

@Model
final class BookCollection {
    @Attribute(.unique) var id: UUID
    var name: String
    var dateCreated: Date
    var savedSearch: String?
    var systemKindRaw: String?
    @Relationship(deleteRule: .nullify, inverse: \Book.collections)
    var books: [Book]

    var systemKind: BookCollectionSystemKind? {
        systemKindRaw.flatMap(BookCollectionSystemKind.init(rawValue:))
    }

    var isSmart: Bool { savedSearch?.isEmpty == false || systemKind != nil }
    var isSystem: Bool { systemKind != nil }
    var isWishlist: Bool { systemKind == .wishlist }

    init(
        name: String,
        savedSearch: String? = nil,
        systemKind: BookCollectionSystemKind? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.dateCreated = Date()
        self.savedSearch = savedSearch
        self.systemKindRaw = systemKind?.rawValue
        self.books = []
    }
}
