import Foundation
import SwiftData

nonisolated enum HighlightTagNormalizer {
    static func normalize(_ rawValue: String) -> [String] {
        normalize(rawValue.split(separator: ",").map(String.init))
    }

    static func normalize(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { rawValue in
            let value = rawValue
                .precomposedStringWithCanonicalMapping
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !value.isEmpty else { return nil }
            let key = MetadataNormalizer.tagComparisonKey(value)
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }
}

nonisolated struct HighlightPatchFields: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    static let favorite = HighlightPatchFields(rawValue: 1 << 0)
    static let tags = HighlightPatchFields(rawValue: 1 << 1)
    static let reflection = HighlightPatchFields(rawValue: 1 << 2)
    static let lastReviewedAt = HighlightPatchFields(rawValue: 1 << 3)
}

nonisolated struct HighlightPatch: Equatable, Sendable {
    let fields: HighlightPatchFields
    var favorite: Bool?
    var tags: [String]?
    var reflection: String?
    var lastReviewedAt: Date?

    init(
        fields: HighlightPatchFields,
        favorite: Bool? = nil,
        tags: [String]? = nil,
        reflection: String? = nil,
        lastReviewedAt: Date? = nil
    ) {
        self.fields = fields
        self.favorite = favorite
        self.tags = tags
        self.reflection = reflection
        self.lastReviewedAt = lastReviewedAt
    }
}

nonisolated struct CatalogHighlightUpdate: Sendable {
    let highlightID: PersistentIdentifier
    let patch: HighlightPatch
}

nonisolated struct HighlightWorkspaceItem: Identifiable, Equatable, Sendable {
    let id: PersistentIdentifier
    let bookID: UUID
    let bookTitle: String
    let bookAuthor: String?
    let text: String
    let isNote: Bool
    let location: String?
    let addedDate: Date?
    let dateImported: Date
    let isFavorite: Bool
    let tags: [String]
    let reflection: String?
    let lastReviewedAt: Date?
    let searchKey: String

    init(
        id: PersistentIdentifier,
        bookID: UUID,
        bookTitle: String,
        bookAuthor: String?,
        text: String,
        isNote: Bool,
        location: String?,
        addedDate: Date?,
        dateImported: Date,
        isFavorite: Bool,
        tags: [String],
        reflection: String?,
        lastReviewedAt: Date?
    ) {
        self.id = id
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.text = text
        self.isNote = isNote
        self.location = location
        self.addedDate = addedDate
        self.dateImported = dateImported
        self.isFavorite = isFavorite
        self.tags = tags
        self.reflection = reflection
        self.lastReviewedAt = lastReviewedAt
        searchKey = MetadataNormalizer.searchKey([
            bookTitle,
            bookAuthor ?? "",
            text,
            reflection ?? "",
            tags.joined(separator: " "),
        ].joined(separator: " "))
    }

    var hasReflection: Bool {
        reflection?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var searchableText: String {
        searchKey
    }
}

extension HighlightWorkspaceItem {
    @MainActor
    init?(_ highlight: Highlight) {
        guard let book = highlight.book else { return nil }
        self.init(
            id: highlight.persistentModelID,
            bookID: book.uuid,
            bookTitle: book.displayTitle,
            bookAuthor: book.displayAuthor,
            text: highlight.text,
            isNote: highlight.isNote,
            location: highlight.location,
            addedDate: highlight.addedDate,
            dateImported: highlight.dateImported,
            isFavorite: highlight.isFavorite,
            tags: highlight.userTags,
            reflection: highlight.reflection,
            lastReviewedAt: highlight.lastReviewedAt
        )
    }
}
