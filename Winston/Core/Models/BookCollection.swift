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
    var smartShelfRulesData: Data?
    var systemKindRaw: String?
    @Relationship(deleteRule: .nullify, inverse: \Book.collections)
    var books: [Book]

    var systemKind: BookCollectionSystemKind? {
        systemKindRaw.flatMap(BookCollectionSystemKind.init(rawValue:))
    }

    var smartShelfDefinition: SmartShelfDefinition? {
        get {
            guard let smartShelfRulesData else { return nil }
            return try? JSONDecoder().decode(SmartShelfDefinition.self, from: smartShelfRulesData)
        }
        set {
            smartShelfRulesData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    var isSmart: Bool {
        savedSearch?.isEmpty == false || smartShelfRulesData?.isEmpty == false || systemKind != nil
    }
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
        self.smartShelfRulesData = nil
        self.systemKindRaw = systemKind?.rawValue
        self.books = []
    }
}
