import Foundation
import Testing
@testable import Winston

struct ReadingRecommendationTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func candidate(
        id: UUID = UUID(),
        title: String,
        status: ReadingStatus = .unread,
        progress: Double? = nil,
        pages: Int? = nil,
        tags: [String] = [],
        language: String? = nil,
        series: String? = nil,
        seriesIndex: Double? = nil,
        personalRating: Int? = nil,
        communityRating: Double? = nil,
        addedDaysAgo: Int = 0,
        isAvailable: Bool = true
    ) -> ReadingRecommendationCandidate {
        ReadingRecommendationCandidate(
            id: id,
            title: title,
            author: "Author",
            readingStatus: status,
            activeProgress: progress,
            pageCount: pages,
            tags: tags,
            language: language,
            series: series,
            seriesIndex: seriesIndex,
            personalRating: personalRating,
            communityRating: communityRating,
            dateAdded: Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: -addedDaysAgo,
                to: now
            )!,
            isAvailable: isAvailable
        )
    }

    @Test func quickReadPrefersShortBookAndExplainsTheFit() throws {
        let short = candidate(title: "Small Gods", pages: 210)
        let long = candidate(title: "The Stand", pages: 1_152)
        var preferences = ReadingRecommendationPreferences.default
        preferences.timeBudget = .quick
        preferences.preferHighlyRated = false
        preferences.preferWaitingLongest = false

        let result = ReadingRecommendationService.rank(
            [long, short],
            preferences: preferences,
            now: now
        )

        let first = try #require(result.first)
        #expect(first.bookID == short.id)
        #expect(first.reasons.contains(.fitsQuickRead(pageCount: 210)))
    }

    @Test func moodAndLanguageAreHardFiltersEvenAgainstAHigherRating() throws {
        let match = candidate(
            title: "Duna",
            tags: ["Sci-Fi"],
            language: "cs",
            communityRating: 3.8
        )
        let wrongLanguage = candidate(
            title: "Dune",
            tags: ["sci-fi"],
            language: "en",
            communityRating: 4.9
        )
        var preferences = ReadingRecommendationPreferences.default
        preferences.moodTag = "SCI-FI"
        preferences.language = "CS"

        let result = ReadingRecommendationService.rank(
            [wrongLanguage, match],
            preferences: preferences,
            now: now
        )

        #expect(result.map(\.bookID) == [match.id])
        let reasons = try #require(result.first?.reasons)
        #expect(reasons.contains(.matchesMood("SCI-FI")))
        #expect(reasons.contains(.matchesLanguage("CS")))
    }

    @Test func continuingSeriesPicksTheNextUnreadVolumeNotALaterOne() throws {
        let finished = candidate(
            title: "Volume One",
            status: .finished,
            series: "Earthsea",
            seriesIndex: 1
        )
        let next = candidate(
            title: "Volume Two",
            series: "Earthsea",
            seriesIndex: 2
        )
        let later = candidate(
            title: "Volume Three",
            series: "Earthsea",
            seriesIndex: 3,
            communityRating: 5
        )
        let unrelated = candidate(title: "Standalone")
        var preferences = ReadingRecommendationPreferences.default
        preferences.seriesPreference = .continueSeries
        preferences.preferHighlyRated = false
        preferences.preferWaitingLongest = false

        let result = ReadingRecommendationService.rank(
            [later, unrelated, finished, next],
            preferences: preferences,
            now: now
        )

        #expect(result.map(\.bookID) == [next.id])
        #expect(try #require(result.first).reasons.contains(.continuesSeries("Earthsea")))
    }

    @Test func moodFilterNeverJumpsPastAnEarlierUnreadSeriesVolume() {
        let finished = candidate(
            title: "Volume One",
            status: .finished,
            series: "Earthsea",
            seriesIndex: 1
        )
        let next = candidate(
            title: "Volume Two",
            tags: ["reflective"],
            series: "Earthsea",
            seriesIndex: 2
        )
        let laterMoodMatch = candidate(
            title: "Volume Three",
            tags: ["adventure"],
            series: "Earthsea",
            seriesIndex: 3
        )
        var preferences = ReadingRecommendationPreferences.default
        preferences.moodTag = "adventure"

        let result = ReadingRecommendationService.rank(
            [finished, next, laterMoodMatch],
            preferences: preferences,
            now: now
        )

        #expect(result.isEmpty)
    }

    @Test func continueModePrefersTheBookAlreadyInProgress() throws {
        let reading = candidate(title: "Reading", status: .reading, progress: 0.42)
        let paused = candidate(title: "Paused", status: .paused, progress: 0.8)
        let unread = candidate(title: "Unread", communityRating: 5)
        var preferences = ReadingRecommendationPreferences.default
        preferences.mode = .continueReading
        preferences.preferHighlyRated = false
        preferences.preferWaitingLongest = false

        let result = ReadingRecommendationService.rank(
            [unread, paused, reading],
            preferences: preferences,
            now: now
        )

        #expect(result.map(\.bookID) == [reading.id, paused.id])
        #expect(try #require(result.first).reasons.contains(.currentlyReading(progress: 42)))
    }

    @Test func ratingAndWaitingPreferencesCanChangeTheWinner() throws {
        let highlyRated = candidate(
            title: "New and Loved",
            communityRating: 5,
            addedDaysAgo: 2
        )
        let waiting = candidate(
            title: "Patient Book",
            communityRating: 2.5,
            addedDaysAgo: 1_500
        )
        var preferences = ReadingRecommendationPreferences.default
        preferences.preferWaitingLongest = false

        let ratingFirst = ReadingRecommendationService.rank(
            [waiting, highlyRated],
            preferences: preferences,
            now: now
        )
        preferences.preferHighlyRated = false
        preferences.preferWaitingLongest = true
        let waitingFirst = ReadingRecommendationService.rank(
            [waiting, highlyRated],
            preferences: preferences,
            now: now
        )

        #expect(ratingFirst.first?.bookID == highlyRated.id)
        #expect(waitingFirst.first?.bookID == waiting.id)
        #expect(try #require(waitingFirst.first).reasons.contains(.waitingSince(waiting.dateAdded)))
    }

    @Test func unavailableFinishedAndDNFBooksAreNeverRecommended() {
        let missing = candidate(title: "Missing", isAvailable: false)
        let finished = candidate(title: "Finished", status: .finished)
        let dnf = candidate(title: "DNF", status: .didNotFinish)
        let available = candidate(title: "Available")

        let result = ReadingRecommendationService.rank(
            [missing, finished, dnf, available],
            preferences: .default,
            now: now
        )

        #expect(result.map(\.bookID) == [available.id])
    }

    @Test func rankingScalesToALargeLibrary() {
        var books = (0..<4_000).map { index in
            candidate(title: "Book \(index)", series: "Long Series")
        }
        books.append(candidate(
            title: "Finished Prelude",
            status: .finished,
            series: "Long Series"
        ))
        var preferences = ReadingRecommendationPreferences.default
        preferences.preferHighlyRated = false
        preferences.preferWaitingLongest = false

        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = ReadingRecommendationService.rank(
            books,
            preferences: preferences,
            now: now
        )
        let elapsed = startedAt.duration(to: clock.now)

        print("Reading recommendation ranking benchmark: \(elapsed)")
        #expect(result.count == 4_000)
    }
}
