import Foundation
import SwiftData

nonisolated enum NoticeKind: String, Codable, Sendable {
    case newRelease
    case nextInSeries
    case ratingPrompt
}

@Model
final class LibraryNotice {
    @Attribute(.unique) var id: UUID
    // Deliberately not .unique — a unique-key insert upserts and would silently reset readAt.
    var dedupeKey: String
    // Raw string on purpose — a Codable enum column traps on NULL rows after additive migrations.
    var kindRaw: String?
    var dateCreated: Date
    var readAt: Date?
    var seriesName: String?
    var bookTitle: String
    var author: String?
    var positionText: String?
    var hardcoverBookID: String?
    var hardcoverURLString: String?
    var coverURLString: String?
    var bookUUID: UUID?
    var releaseDateRaw: String?

    init(
        id: UUID = UUID(),
        dedupeKey: String,
        kind: NoticeKind,
        dateCreated: Date = .now,
        bookTitle: String
    ) {
        self.id = id
        self.dedupeKey = dedupeKey
        self.kindRaw = kind.rawValue
        self.dateCreated = dateCreated
        self.bookTitle = bookTitle
    }

    var kind: NoticeKind? {
        get { kindRaw.flatMap(NoticeKind.init(rawValue:)) }
        set { kindRaw = newValue?.rawValue }
    }

    var isUnread: Bool { readAt == nil }

    var hardcoverURL: URL? { hardcoverURLString.flatMap(URL.init(string:)) }
    var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }
}
