import Foundation

nonisolated enum ReadingStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case unread
    case reading
    case finished

    var id: Self { self }

    var label: String {
        switch self {
        case .unread:   String(localized: "Unread", comment: "Reading status")
        case .reading:  String(localized: "Reading", comment: "Reading status")
        case .finished: String(localized: "Finished", comment: "Reading status")
        }
    }

    var terminalLabel: String {
        switch self {
        case .unread:   "unread"
        case .reading:  "reading"
        case .finished: "done"
        }
    }

    var systemImage: String {
        switch self {
        case .unread:   "circle"
        case .reading:  "book"
        case .finished: "checkmark.circle.fill"
        }
    }
}
