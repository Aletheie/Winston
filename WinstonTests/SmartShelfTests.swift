import Foundation
import Testing
@testable import Winston

@MainActor
struct SmartShelfTests {
    private func makeBook(
        _ title: String,
        fileName: String,
        language: String? = nil,
        pages: Int? = nil,
        rating: Int? = nil,
        status: ReadingStatus = .unread
    ) -> Book {
        let book = Book(fileName: fileName, originalFileName: fileName)
        book.title = title
        book.author = "Author"
        book.language = language
        book.pageCount = pages
        book.rating = rating
        book.readingStatus = status
        return book
    }

    @Test func allRulesMatchUnreadCzechShortBookNotOnKindle() {
        let matching = makeBook("Duna", fileName: "duna.epub", language: "cs", pages: 280)
        let tooLong = makeBook("Dlouhá", fileName: "long.epub", language: "cs", pages: 420)
        let english = makeBook("English", fileName: "english.epub", language: "en", pages: 180)
        let onKindle = makeBook("Solaris", fileName: "solaris.epub", language: "cs", pages: 204)
        let definition = SmartShelfDefinition(rules: [
            SmartShelfRule(field: .readingStatus, value: ReadingStatus.unread.rawValue),
            SmartShelfRule(field: .language, comparison: .isEqual, value: "cs"),
            SmartShelfRule(field: .pageCount, comparison: .lessThan, value: "300"),
            SmartShelfRule(field: .onDevice, comparison: .isFalse),
        ])

        let result = LibraryQuery.applySmartShelf(
            to: [matching, tooLong, english, onKindle],
            definition: definition,
            deviceFileNames: [onKindle.deviceMatchKey],
            deviceIsConnected: true,
            sort: []
        )

        #expect(result.map(\.displayTitle) == ["Duna"])
    }

    @Test func anyModeMatchesEitherRatingOrHighlights() {
        let rated = makeBook("Rated", fileName: "rated.epub", rating: 5)
        let highlighted = makeBook("Marked", fileName: "marked.epub")
        highlighted.highlights.append(
            Highlight(text: "A passage", isNote: false, location: nil, addedDate: nil)
        )
        let plain = makeBook("Plain", fileName: "plain.epub", rating: 2)
        let definition = SmartShelfDefinition(matchMode: .any, rules: [
            SmartShelfRule(field: .rating, comparison: .atLeast, value: "4"),
            SmartShelfRule(field: .highlights, comparison: .isTrue),
        ])

        let result = LibraryQuery.applySmartShelf(
            to: [rated, highlighted, plain],
            definition: definition,
            deviceFileNames: [],
            deviceIsConnected: false,
            sort: []
        )

        #expect(Set(result.map(\.displayTitle)) == ["Rated", "Marked"])
    }

    @Test func deviceRulesStayInactiveWhileKindleIsDisconnected() {
        let book = makeBook("Local", fileName: "local.epub")
        let definition = SmartShelfPreset.notOnKindle.definition

        let disconnected = LibraryQuery.applySmartShelf(
            to: [book],
            definition: definition,
            deviceFileNames: [],
            deviceIsConnected: false,
            sort: []
        )
        let connected = LibraryQuery.applySmartShelf(
            to: [book],
            definition: definition,
            deviceFileNames: [],
            deviceIsConnected: true,
            sort: []
        )

        #expect(disconnected.isEmpty)
        #expect(connected.map(\.displayTitle) == ["Local"])
    }

    @Test func missingMetadataChecksEssentialFields() {
        let incomplete = Book(fileName: "unknown.epub", originalFileName: "unknown.epub")
        let complete = makeBook("Complete", fileName: "complete.epub", language: "en")
        let definition = SmartShelfPreset.missingMetadata.definition

        let result = LibraryQuery.applySmartShelf(
            to: [incomplete, complete],
            definition: definition,
            deviceFileNames: [],
            deviceIsConnected: false,
            sort: []
        )

        #expect(result.map(\.uuid) == [incomplete.uuid])
    }

    @Test func structuredSmartCountsEvaluateEveryShelfInOnePass() {
        let unread = makeBook("Unread", fileName: "unread.epub", language: "cs")
        let finished = makeBook(
            "Finished",
            fileName: "finished.epub",
            language: "en",
            status: .finished
        )
        let unreadID = UUID()
        let czechID = UUID()

        let counts = LibraryQuery.smartShelfCounts(
            for: [unread, finished],
            shelves: [
                (unreadID, SmartShelfPreset.unread.definition),
                (czechID, SmartShelfPreset.czechUnread.definition),
            ],
            deviceFileNames: [],
            deviceIsConnected: false
        )

        #expect(counts[unreadID] == 1)
        #expect(counts[czechID] == 1)
    }

    @Test func previewCountsAllMatchesButKeepsOnlyLeadingBooks() {
        let books = (0..<25).map { index in
            makeBook("Book \(index)", fileName: "book-\(index).epub")
        }

        let result = LibraryQuery.smartShelfPreview(
            for: books.map(SmartShelfBookSnapshot.init),
            definition: SmartShelfPreset.unread.definition,
            deviceFileNames: [],
            deviceIsConnected: false
        )

        #expect(result.matchCount == 25)
        #expect(result.leadingBookIDs == Array(books.prefix(10).map(\.uuid)))

        let countOnly = LibraryQuery.smartShelfPreview(
            for: books.map(SmartShelfBookSnapshot.init),
            definition: SmartShelfPreset.unread.definition,
            deviceFileNames: [],
            deviceIsConnected: false,
            maximumBookCount: -1
        )
        #expect(countOnly.matchCount == 25)
        #expect(countOnly.leadingBookIDs.isEmpty)
    }

    @Test func definitionRoundTripsThroughCollectionStorage() throws {
        let definition = SmartShelfDefinition(matchMode: .any, rules: [
            SmartShelfRule(field: .tag, comparison: .contains, value: "essay"),
            SmartShelfRule(field: .format, comparison: .isEqual, value: "PDF"),
        ])
        let collection = BookCollection(name: "Essays")

        collection.smartShelfDefinition = definition

        #expect(collection.smartShelfDefinition == definition)
        #expect(collection.isSmart)
        #expect(collection.savedSearch == nil)
    }
}
