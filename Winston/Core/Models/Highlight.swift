import Foundation
import SwiftData

@Model
final class Highlight {
    var text: String
    var kindRaw: String
    var location: String?
    var addedDate: Date?
    var dateImported: Date
    // Optional storage keeps additive migration from the public 0.2 store safe.
    var isFavoriteRaw: Bool?
    var userTagsRaw: [String]?
    var reflection: String?
    var lastReviewedAt: Date?
    var book: Book?

    init(text: String, isNote: Bool, location: String?, addedDate: Date?) {
        self.text = text
        self.kindRaw = isNote ? "note" : "highlight"
        self.location = location
        self.addedDate = addedDate
        self.dateImported = Date()
    }

    var isNote: Bool { kindRaw == "note" }

    var isFavorite: Bool {
        get { isFavoriteRaw ?? false }
        set { isFavoriteRaw = newValue }
    }

    var userTags: [String] {
        get { userTagsRaw ?? [] }
        set { userTagsRaw = newValue.isEmpty ? nil : newValue }
    }

    var hasReflection: Bool {
        reflection?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
