import Foundation
import SwiftData

enum BookCollectionSystemKind: String, Codable, Sendable {
    case wishlist
}

@Model
final class BookCollection {
    nonisolated private final class SmartShelfDefinitionBox: NSObject {
        let value: SmartShelfDefinition?

        init(_ value: SmartShelfDefinition?) {
            self.value = value
        }
    }

    nonisolated(unsafe) private static let decodedSmartShelves: NSCache<
        NSData,
        SmartShelfDefinitionBox
    > = {
        let cache = NSCache<NSData, SmartShelfDefinitionBox>()
        cache.countLimit = 2_048
        return cache
    }()

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
            let key = smartShelfRulesData as NSData
            if let cached = Self.decodedSmartShelves.object(forKey: key) {
                return cached.value
            }
            let decoded = try? JSONDecoder().decode(
                SmartShelfDefinition.self,
                from: smartShelfRulesData
            )
            Self.decodedSmartShelves.setObject(
                SmartShelfDefinitionBox(decoded),
                forKey: key
            )
            return decoded
        }
        set {
            let encoded = newValue.flatMap { try? JSONEncoder().encode($0) }
            smartShelfRulesData = encoded
            if let encoded {
                Self.decodedSmartShelves.setObject(
                    SmartShelfDefinitionBox(newValue),
                    forKey: encoded as NSData
                )
            }
        }
    }

    var isSmart: Bool {
        savedSearch?.isEmpty == false || smartShelfRulesData?.isEmpty == false || systemKind != nil
    }
    var isSystem: Bool { systemKind != nil }
    var isWishlist: Bool { systemKind == .wishlist }

    init(
        id: UUID = UUID(),
        name: String,
        savedSearch: String? = nil,
        systemKind: BookCollectionSystemKind? = nil
    ) {
        self.id = id
        self.name = name
        self.dateCreated = Date()
        self.savedSearch = savedSearch
        self.smartShelfRulesData = nil
        self.systemKindRaw = systemKind?.rawValue
        self.books = []
    }
}
