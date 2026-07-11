import Foundation
import SwiftData

@Model
final class WishlistItem {
    @Attribute(.unique) var id: UUID
    var hardcoverID: String
    var title: String
    var author: String?
    var coverURLString: String?
    var hardcoverURLString: String
    var rating: Double?
    var dateAdded: Date

    init(
        id: UUID = UUID(),
        hardcoverID: String,
        title: String,
        author: String?,
        coverURL: URL?,
        hardcoverURL: URL,
        rating: Double?,
        dateAdded: Date = .now
    ) {
        self.id = id
        self.hardcoverID = hardcoverID
        self.title = title
        self.author = author
        self.coverURLString = coverURL?.absoluteString
        self.hardcoverURLString = hardcoverURL.absoluteString
        self.rating = rating
        self.dateAdded = dateAdded
    }

    var matchKey: BookMatchKey { BookMatchKey(title: title, author: author) }
}
