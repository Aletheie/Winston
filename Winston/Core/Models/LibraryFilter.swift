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

enum SortField: String, CaseIterable, Identifiable {
    case title = "TITLE"
    case author = "AUTHOR"
    case dateAdded = "DATE"
    case rating = "RATING"
    var id: Self { self }
}
