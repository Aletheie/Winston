import Foundation
import SwiftData

@Model
final class SeriesCatalogSnapshot {
    @Attribute(.unique) var seriesKey: String
    var knownBookIDsRaw: String
    var lastCheckedAt: Date

    init(seriesKey: String, knownBookIDs: Set<Int>, lastCheckedAt: Date = .now) {
        self.seriesKey = seriesKey
        self.knownBookIDsRaw = Self.encode(knownBookIDs)
        self.lastCheckedAt = lastCheckedAt
    }

    var knownBookIDs: Set<Int> {
        get { Set(knownBookIDsRaw.split(separator: ",").compactMap { Int($0) }) }
        set { knownBookIDsRaw = Self.encode(newValue) }
    }

    private static func encode(_ ids: Set<Int>) -> String {
        ids.sorted().map(String.init).joined(separator: ",")
    }
}
