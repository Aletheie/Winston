import Foundation

nonisolated enum ReadingRecommendationMode: String, CaseIterable, Identifiable, Sendable {
    case anything
    case continueReading
    case startNew

    var id: Self { self }

    var label: LocalizedStringResource {
        switch self {
        case .anything: "Anything"
        case .continueReading: "Continue reading"
        case .startNew: "Start something new"
        }
    }
}

nonisolated enum ReadingTimeBudget: String, CaseIterable, Identifiable, Sendable {
    case any
    case quick
    case weekend
    case long

    var id: Self { self }

    var label: LocalizedStringResource {
        switch self {
        case .any: "Any length"
        case .quick: "Quick read"
        case .weekend: "A weekend"
        case .long: "Longer read"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .any: "Let mood, series, and ratings decide."
        case .quick: "Favor books up to about 220 pages."
        case .weekend: "Favor books around 180–420 pages."
        case .long: "Favor books with at least 400 pages."
        }
    }
}

nonisolated enum ReadingSeriesPreference: String, CaseIterable, Identifiable, Sendable {
    case any
    case continueSeries
    case standalone

    var id: Self { self }

    var label: LocalizedStringResource {
        switch self {
        case .any: "Any"
        case .continueSeries: "Continue a series"
        case .standalone: "Standalone only"
        }
    }
}

nonisolated struct ReadingRecommendationPreferences: Equatable, Sendable {
    var mode: ReadingRecommendationMode = .anything
    var timeBudget: ReadingTimeBudget = .any
    var moodTag: String?
    var language: String?
    var seriesPreference: ReadingSeriesPreference = .any
    var preferHighlyRated = true
    var preferWaitingLongest = true

    static let `default` = ReadingRecommendationPreferences()
}

nonisolated struct ReadingRecommendationCandidate: Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let author: String?
    let readingStatus: ReadingStatus
    let activeProgress: Double?
    let pageCount: Int?
    let tags: [String]
    let language: String?
    let series: String?
    let seriesIndex: Double?
    let personalRating: Int?
    let communityRating: Double?
    let dateAdded: Date
    let isAvailable: Bool
}

nonisolated enum ReadingRecommendationReason: Hashable, Sendable, Identifiable {
    case currentlyReading(progress: Int?)
    case paused(progress: Int?)
    case fitsQuickRead(pageCount: Int)
    case fitsWeekend(pageCount: Int)
    case suitsLongRead(pageCount: Int)
    case matchesMood(String)
    case matchesLanguage(String)
    case continuesSeries(String)
    case highlyRated(Double)
    case waitingSince(Date)
    case readyNow

    var id: Self { self }

    var icon: String {
        switch self {
        case .currentlyReading: "book.pages"
        case .paused: "pause.circle"
        case .fitsQuickRead, .fitsWeekend, .suitsLongRead: "clock"
        case .matchesMood: "tag"
        case .matchesLanguage: "character.book.closed"
        case .continuesSeries: "books.vertical"
        case .highlyRated: "star.fill"
        case .waitingSince: "calendar"
        case .readyNow: "checkmark.circle"
        }
    }

    var text: LocalizedStringResource {
        switch self {
        case .currentlyReading(let progress):
            if let progress {
                "Already \(progress)% read"
            } else {
                "Already in progress"
            }
        case .paused(let progress):
            if let progress {
                "Paused at \(progress)%"
            } else {
                "Easy to resume"
            }
        case .fitsQuickRead(let pageCount):
            "\(pageCount) pages fits a quick read"
        case .fitsWeekend(let pageCount):
            "\(pageCount) pages fits a weekend"
        case .suitsLongRead(let pageCount):
            "\(pageCount) pages suits a longer read"
        case .matchesMood(let tag):
            "Matches your “\(tag)” mood"
        case .matchesLanguage(let language):
            "Written in \(language)"
        case .continuesSeries(let series):
            "Next up in \(series)"
        case .highlyRated(let rating):
            "Rated \(rating, format: .number.precision(.fractionLength(1)))/5"
        case .waitingSince(let date):
            "In your library since \(date, format: .dateTime.month(.wide).year())"
        case .readyNow:
            "Ready in your library"
        }
    }
}

nonisolated struct ReadingRecommendation: Equatable, Sendable, Identifiable {
    let bookID: UUID
    let score: Double
    let reasons: [ReadingRecommendationReason]

    var id: UUID { bookID }
}

nonisolated enum ReadingRecommendationService {
    static func rank(
        _ candidates: [ReadingRecommendationCandidate],
        preferences: ReadingRecommendationPreferences,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [ReadingRecommendation] {
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let startedSeries = Set(candidates.compactMap { candidate -> String? in
            guard candidate.readingStatus == .finished
                    || candidate.readingStatus == .reading
                    || candidate.readingStatus == .paused else { return nil }
            return normalized(candidate.series)
        })

        var eligible = candidates.filter { candidate in
            guard candidate.isAvailable else { return false }
            switch preferences.mode {
            case .anything:
                return candidate.readingStatus == .unread
                    || candidate.readingStatus == .reading
                    || candidate.readingStatus == .paused
            case .continueReading:
                return candidate.readingStatus == .reading || candidate.readingStatus == .paused
            case .startNew:
                return candidate.readingStatus == .unread
            }
        }

        if let requestedTag = normalized(preferences.moodTag) {
            eligible = eligible.filter { candidate in
                candidate.tags.contains { normalized($0) == requestedTag }
            }
        }
        if let requestedLanguage = normalized(preferences.language) {
            eligible = eligible.filter { normalized($0.language) == requestedLanguage }
        }

        switch preferences.seriesPreference {
        case .any:
            break
        case .continueSeries:
            eligible = eligible.filter { candidate in
                guard let key = normalized(candidate.series) else { return false }
                return startedSeries.contains(key)
            }
        case .standalone:
            eligible = eligible.filter { normalized($0.series) == nil }
        }

        eligible = removeLaterUnreadVolumes(
            from: eligible,
            considering: candidates
        )

        return eligible.map { candidate in
            score(
                candidate,
                allCandidates: candidates,
                startedSeries: startedSeries,
                preferences: preferences,
                now: now,
                calendar: calendar
            )
        }
        .sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.000_1 { return lhs.score > rhs.score }
            let left = candidatesByID[lhs.bookID]
            let right = candidatesByID[rhs.bookID]
            if left?.dateAdded != right?.dateAdded {
                return (left?.dateAdded ?? .distantFuture) < (right?.dateAdded ?? .distantFuture)
            }
            let titleOrder = (left?.title ?? "").localizedCaseInsensitiveCompare(right?.title ?? "")
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.bookID.uuidString < rhs.bookID.uuidString
        }
    }

    private struct WeightedReason {
        let weight: Double
        let reason: ReadingRecommendationReason
    }

    private static func score(
        _ candidate: ReadingRecommendationCandidate,
        allCandidates: [ReadingRecommendationCandidate],
        startedSeries: Set<String>,
        preferences: ReadingRecommendationPreferences,
        now: Date,
        calendar: Calendar
    ) -> ReadingRecommendation {
        var score = 5.0
        var reasons: [WeightedReason] = []

        let progress = candidate.activeProgress.map {
            min(100, max(0, Int(($0 * 100).rounded())))
        }
        switch candidate.readingStatus {
        case .reading:
            score += 48
            reasons.append(WeightedReason(weight: 48, reason: .currentlyReading(progress: progress)))
        case .paused:
            score += 30
            reasons.append(WeightedReason(weight: 30, reason: .paused(progress: progress)))
        case .unread, .finished, .didNotFinish:
            break
        }

        if let pageCount = candidate.pageCount, pageCount > 0 {
            let timeFit = timeScore(pageCount: pageCount, budget: preferences.timeBudget)
            score += timeFit.score
            if let reason = timeFit.reason {
                reasons.append(WeightedReason(weight: timeFit.score, reason: reason))
            }
        }

        if let requestedTag = preferences.moodTag,
           candidate.tags.contains(where: { normalized($0) == normalized(requestedTag) }) {
            score += 42
            reasons.append(WeightedReason(weight: 42, reason: .matchesMood(requestedTag)))
        }

        if let requestedLanguage = preferences.language,
           normalized(candidate.language) == normalized(requestedLanguage) {
            score += 18
            reasons.append(WeightedReason(weight: 18, reason: .matchesLanguage(requestedLanguage)))
        }

        if let series = candidate.series,
           let seriesKey = normalized(series),
           startedSeries.contains(seriesKey),
           isContinuation(candidate, among: allCandidates) {
            score += 32
            reasons.append(WeightedReason(weight: 32, reason: .continuesSeries(series)))
        }

        if preferences.preferHighlyRated, let rating = effectiveRating(candidate) {
            let ratingScore = max(0, min(22, (rating - 2.5) * 8.8))
            score += ratingScore
            if rating >= 3.5 {
                reasons.append(WeightedReason(weight: ratingScore, reason: .highlyRated(rating)))
            }
        }

        if preferences.preferWaitingLongest, candidate.readingStatus == .unread {
            let days = max(0, calendar.dateComponents([.day], from: candidate.dateAdded, to: now).day ?? 0)
            let waitingScore = min(24, Double(days) / 45)
            score += waitingScore
            if days >= 90 {
                reasons.append(WeightedReason(weight: waitingScore, reason: .waitingSince(candidate.dateAdded)))
            }
        }

        let rankedReasons = reasons
            .sorted {
                if $0.weight != $1.weight { return $0.weight > $1.weight }
                return String(describing: $0.reason) < String(describing: $1.reason)
            }
            .prefix(4)
            .map(\.reason)

        return ReadingRecommendation(
            bookID: candidate.id,
            score: score,
            reasons: rankedReasons.isEmpty ? [.readyNow] : rankedReasons
        )
    }

    private static func timeScore(
        pageCount: Int,
        budget: ReadingTimeBudget
    ) -> (score: Double, reason: ReadingRecommendationReason?) {
        switch budget {
        case .any:
            return (0, nil)
        case .quick:
            if pageCount <= 220 { return (28, .fitsQuickRead(pageCount: pageCount)) }
            if pageCount <= 320 { return (10, nil) }
            return (0, nil)
        case .weekend:
            if (180 ... 420).contains(pageCount) { return (25, .fitsWeekend(pageCount: pageCount)) }
            if (120 ... 560).contains(pageCount) { return (10, nil) }
            return (0, nil)
        case .long:
            if pageCount >= 400 { return (24, .suitsLongRead(pageCount: pageCount)) }
            if pageCount >= 280 { return (9, nil) }
            return (0, nil)
        }
    }

    private static func effectiveRating(_ candidate: ReadingRecommendationCandidate) -> Double? {
        if let personal = candidate.personalRating, (1 ... 5).contains(personal) {
            return Double(personal)
        }
        guard let community = candidate.communityRating, (0 ... 5).contains(community) else { return nil }
        return community
    }

    private static func removeLaterUnreadVolumes(
        from candidates: [ReadingRecommendationCandidate],
        considering allCandidates: [ReadingRecommendationCandidate]
    ) -> [ReadingRecommendationCandidate] {
        let earliestUnreadIndexBySeries = Dictionary(
            grouping: allCandidates.filter { candidate in
                candidate.readingStatus == .unread
                    && normalized(candidate.series) != nil
                    && candidate.seriesIndex != nil
            },
            by: { normalized($0.series)! }
        ).compactMapValues { group in
            group.compactMap(\.seriesIndex).min()
        }

        return candidates.filter { candidate in
            guard candidate.readingStatus == .unread,
                  let seriesKey = normalized(candidate.series),
                  let seriesIndex = candidate.seriesIndex,
                  let earliestUnreadIndex = earliestUnreadIndexBySeries[seriesKey] else {
                return true
            }
            return seriesIndex == earliestUnreadIndex
        }
    }

    private static func isContinuation(
        _ candidate: ReadingRecommendationCandidate,
        among candidates: [ReadingRecommendationCandidate]
    ) -> Bool {
        if candidate.readingStatus == .reading || candidate.readingStatus == .paused { return true }
        guard candidate.readingStatus == .unread,
              let key = normalized(candidate.series) else { return false }

        return candidates.contains { other in
            guard other.id != candidate.id,
                  normalized(other.series) == key,
                  other.readingStatus == .finished
                    || other.readingStatus == .reading
                    || other.readingStatus == .paused else { return false }
            guard let candidateIndex = candidate.seriesIndex,
                  let otherIndex = other.seriesIndex else { return true }
            return otherIndex < candidateIndex
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }
}
