import Foundation
import SwiftData

@Model
final class Work {
    @Attribute(.unique) var uuid: UUID
    var title: String?
    var author: String?
    var originalTitle: String?
    var originalLanguage: String?
    var matchKey: String?
    var openLibraryWorkKey: String?
    var hardcoverBookID: String?
    var preferredEditionUUID: UUID?
    var dateCreated: Date
    var notes: String?

    @Relationship(deleteRule: .nullify, inverse: \Book.work)
    var editions: [Book] = []

    init(
        uuid: UUID = UUID(),
        title: String? = nil,
        author: String? = nil,
        dateCreated: Date = Date()
    ) {
        self.uuid = uuid
        self.title = title
        self.author = author
        self.dateCreated = dateCreated
        refreshMatchKey()
    }

    var displayTitle: String {
        guard let value = title?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return String(localized: "Untitled work")
        }
        return value
    }

    func refreshMatchKey() {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            matchKey = nil
            return
        }
        let key = BookMatchKey(title: title, author: author)
        matchKey = key.isComplete ? key.storageValue : nil
    }
}
