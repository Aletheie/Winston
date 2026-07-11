import Foundation
import SwiftData

@Model
final class Highlight {
    var text: String
    var kindRaw: String
    var location: String?
    var addedDate: Date?
    var dateImported: Date
    var book: Book?

    init(text: String, isNote: Bool, location: String?, addedDate: Date?) {
        self.text = text
        self.kindRaw = isNote ? "note" : "highlight"
        self.location = location
        self.addedDate = addedDate
        self.dateImported = Date()
    }

    var isNote: Bool { kindRaw == "note" }
}
