import Foundation

nonisolated enum LibraryFilter: Hashable, Sendable {
    case all
    case recentlyAdded
    case status(ReadingStatus)
    case collection(UUID)
    case format(String)
    case author(String)
    case series(String)
    case tag(String)
    case rated
}

nonisolated enum KindlePresenceFilter: String, CaseIterable, Hashable, Identifiable, Sendable {
    case all
    case onKindle
    case notOnKindle

    var id: Self { self }

    func includes(
        deviceMatchKeys: Set<String>,
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) -> Bool {
        guard deviceIsConnected else { return true }
        let isOnKindle = !deviceMatchKeys.isDisjoint(with: deviceFileNames)
        return switch self {
        case .all: true
        case .onKindle: isOnKindle
        case .notOnKindle: !isOnKindle
        }
    }
}

enum SortField: String, CaseIterable, Identifiable {
    case title = "TITLE"
    case author = "AUTHOR"
    case dateAdded = "DATE"
    case rating = "RATING"
    var id: Self { self }
}
