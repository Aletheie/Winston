import SwiftUI

nonisolated struct DiscoveryReleaseDate: Sendable, Equatable, Comparable {
    let year: Int
    let month: Int
    let day: Int

    init?(year: Int, month: Int, day: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let validated = calendar.dateComponents([.year, .month, .day], from: date)
        guard validated.year == year,
              validated.month == month,
              validated.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    init?(iso8601 value: String) {
        let datePart = value.prefix(10)
        let parts = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard datePart.count == 10,
              parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    init?(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return nil }
        self.init(year: year, month: month, day: day)
    }

    var iso8601: String {
        let month = month < 10 ? "0\(month)" : String(month)
        let day = day < 10 ? "0\(day)" : String(day)
        return "\(year)-\(month)-\(day)"
    }

    static func < (lhs: DiscoveryReleaseDate, rhs: DiscoveryReleaseDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
}

nonisolated struct DiscoveryBook: Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let author: String?
    let coverURL: URL?
    let hardcoverURL: URL
    let rating: Double?
    let releaseYear: Int?
    let releaseDate: DiscoveryReleaseDate?

    init(id: String, title: String, author: String?, coverURL: URL?, hardcoverURL: URL,
         rating: Double?, releaseYear: Int? = nil, releaseDate: DiscoveryReleaseDate? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.hardcoverURL = hardcoverURL
        self.rating = rating
        self.releaseYear = releaseYear
        self.releaseDate = releaseDate
    }
}

nonisolated enum DiscoveryResult: Sendable, Equatable {
    case needsToken
    case failed
    case books([DiscoveryBook])
}

nonisolated struct DiscoveryGenre: Sendable, Identifiable, Hashable {
    let id: String
    let queryTerm: String
    let terminal: String

    var nativeLabel: LocalizedStringKey {
        switch id {
        case "scifi":    "Sci-Fi"
        case "fantasy":  "Fantasy"
        case "mystery":  "Mystery"
        case "thriller": "Thriller"
        case "romance":  "Romance"
        case "horror":   "Horror"
        case "litfic":   "Literary Fiction"
        case "ya":       "Young Adult"
        default:         "\(queryTerm)"
        }
    }

    static let all: [DiscoveryGenre] = [
        DiscoveryGenre(id: "scifi",    queryTerm: "Science Fiction",  terminal: "SCI-FI"),
        DiscoveryGenre(id: "fantasy",  queryTerm: "Fantasy",          terminal: "FANTASY"),
        DiscoveryGenre(id: "mystery",  queryTerm: "Mystery",          terminal: "MYSTERY"),
        DiscoveryGenre(id: "thriller", queryTerm: "Thriller",         terminal: "THRILLER"),
        DiscoveryGenre(id: "romance",  queryTerm: "Romance",          terminal: "ROMANCE"),
        DiscoveryGenre(id: "horror",   queryTerm: "Horror",           terminal: "HORROR"),
        DiscoveryGenre(id: "litfic",   queryTerm: "Literary Fiction", terminal: "LIT FICTION"),
        DiscoveryGenre(id: "ya",       queryTerm: "Young Adult",      terminal: "YA"),
    ]

    static var `default`: DiscoveryGenre { all[0] }
}
