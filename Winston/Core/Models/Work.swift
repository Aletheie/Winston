import Foundation
import SwiftData

@Model
final class Work {
    @Attribute(.unique) var uuid: UUID
    // Canonical work identity. Edition identifiers such as ISBN deliberately
    // live on Book and must not be copied here.
    var title: String?
    var author: String?
    var originalTitle: String?
    var originalLanguage: String?
    var matchKey: String?
    var openLibraryWorkKey: String?
    var hardcoverBookID: String?
    var preferredEditionUUID: UUID?
    var coverVersionRaw: Int?
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
        coverVersionRaw = 0
        refreshMatchKey()
    }

    var displayTitle: String {
        guard let value = title?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return String(localized: "Untitled work")
        }
        return value
    }

    var coverVersion: Int {
        get { max(0, coverVersionRaw ?? 0) }
        set { coverVersionRaw = max(0, newValue) }
    }

    var coverReference: CoverReference {
        CoverReference(owner: .work(uuid), version: coverVersion)
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
