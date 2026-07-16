import Foundation

nonisolated enum ReadingStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case unread
    case reading
    case paused
    case finished
    case didNotFinish

    var id: Self { self }

    var label: String {
        switch self {
        case .unread:       String(localized: "Unread", comment: "Reading status")
        case .reading:      String(localized: "Reading", comment: "Reading status")
        case .paused:       String(localized: "Paused", comment: "Reading status")
        case .finished:     String(localized: "Finished", comment: "Reading status")
        case .didNotFinish: String(localized: "Did Not Finish", comment: "Reading status")
        }
    }

    var terminalLabel: String {
        switch self {
        case .unread:       "unread"
        case .reading:      "reading"
        case .paused:       "paused"
        case .finished:     "done"
        case .didNotFinish: "dnf"
        }
    }

    var systemImage: String {
        switch self {
        case .unread:       "circle"
        case .reading:      "book"
        case .paused:       "pause.circle.fill"
        case .finished:     "checkmark.circle.fill"
        case .didNotFinish: "xmark.circle.fill"
        }
    }
}
