import Testing
import Foundation
@testable import Winston

// MARK: - Search query parsing

struct SearchQueryTests {

    @Test func plainTextBecomesFreeText() {
        let q = SearchQuery.parse("the hobbit")
        #expect(q.freeText == "the hobbit")
        #expect(q.authors.isEmpty && q.tags.isEmpty && q.year == nil)
    }

    @Test func parsesFieldFiltersAlongsideFreeText() {
        let q = SearchQuery.parse("author:tolkien tag:fantasy hobbit")
        #expect(q.authors == ["tolkien"])
        #expect(q.tags == ["fantasy"])
        #expect(q.freeText == "hobbit")
    }

    @Test func parsesQuotedValuesAndPhrases() {
        let q = SearchQuery.parse("tag:\"science fiction\" \"the dispossessed\"")
        #expect(q.tags == ["science fiction"])
        #expect(q.freeText == "the dispossessed")
    }

    @Test func parsesLanguageAndTranslatorFields() {
        let query = SearchQuery.parse("language:cs translator:\"Jan Novák\"")
        #expect(query.languages == ["cs"])
        #expect(query.translators == ["Jan Novák"])
    }

    @Test(arguments: zip(
        [">2000", "<1990", "=2010", "2010", "abc"],
        [SearchQuery.YearConstraint(op: .greaterThan, value: 2000),
         SearchQuery.YearConstraint(op: .lessThan, value: 1990),
         SearchQuery.YearConstraint(op: .equal, value: 2010),
         SearchQuery.YearConstraint(op: .equal, value: 2010),
         nil] as [SearchQuery.YearConstraint?]
    ))
    func parsesYearConstraints(_ token: String, _ expected: SearchQuery.YearConstraint?) {
        #expect(SearchQuery.parse("year:\(token)").year == expected)
    }

    @Test func blankIsEmptyAndUnknownFieldStaysFreeText() {
        #expect(SearchQuery.parse("   ").isEmpty)
        #expect(SearchQuery.parse("foo:bar").freeText == "foo:bar")
    }
}

// MARK: - Filtering + sorting (Book is MainActor-isolated)

@MainActor
struct LibraryQueryTests {

    private func makeBook(_ title: String, author: String? = nil, tags: [String] = [],
                          series: String? = nil, seriesIndex: String? = nil, year: String? = nil,
                          rating: Int? = nil, status: ReadingStatus = .unread) -> Book {
        let book = Book(fileName: "u.epub", originalFileName: "u.epub")
        book.title = title
        book.author = author
        book.tags = tags
        book.series = series
        book.seriesIndex = seriesIndex
        book.year = year
        book.rating = rating
        book.readingStatus = status
        return book
    }

    @Test func filtersByReadingStatus() {
        let books = [makeBook("A", status: .reading), makeBook("B", status: .unread)]
        let result = LibraryQuery.apply(to: books, filter: .status(.reading), searchText: "", sort: [])
        #expect(result.map(\.title) == ["A"])
    }

    @Test func fieldSearchNarrowsByTag() {
        let books = [makeBook("Dune", tags: ["sci-fi"]), makeBook("Mythago", tags: ["fantasy"])]
        let result = LibraryQuery.apply(to: books, filter: .all, searchText: "tag:sci-fi", sort: [])
        #expect(result.map(\.title) == ["Dune"])
    }

    @Test func yearConstraintFilters() {
        let books = [makeBook("Old", year: "1980"), makeBook("New", year: "2020")]
        let result = LibraryQuery.apply(to: books, filter: .all, searchText: "year:>2000", sort: [])
        #expect(result.map(\.title) == ["New"])
    }

    @Test func freeTextMatchesTitleOrAuthor() {
        let books = [makeBook("Dune", author: "Herbert"), makeBook("Other", author: "Asimov")]
        #expect(LibraryQuery.apply(to: books, filter: .all, searchText: "herbert", sort: []).map(\.title) == ["Dune"])
    }

    @Test func freeTextMatchesNotes() {
        let withNote = makeBook("Untitled")
        withNote.notes = "borrowed from Jana"
        let plain = makeBook("Other")
        let result = LibraryQuery.apply(to: [withNote, plain], filter: .all, searchText: "jana", sort: [])
        #expect(result.map(\.title) == ["Untitled"])
    }

    @Test func languageAndTranslatorFieldsFilterEditions() {
        let matching = makeBook("Duna")
        matching.language = "cs"
        matching.translator = "Jan Novák"
        let other = makeBook("Dune")
        other.language = "en"
        let result = LibraryQuery.apply(
            to: [matching, other], filter: .all,
            searchText: "language:cs translator:novák", sort: []
        )
        #expect(result.map(\.title) == ["Duna"])
    }

    @Test func batchedSmartCountsMatchIndividualQueries() {
        let books = [
            makeBook("Dune", author: "Frank Herbert", tags: ["sci-fi"], year: "1965"),
            makeBook("Foundation", author: "Isaac Asimov", tags: ["sci-fi"], year: "1951"),
            makeBook("Emma", author: "Jane Austen", tags: ["classic"], year: "1815"),
        ]
        let scienceFiction = UUID()
        let modern = UUID()
        let searches = [(scienceFiction, "tag:sci-fi"), (modern, "year:>1900")]

        let counts = LibraryQuery.smartCounts(for: books, searches: searches)
        let snapshotCounts = LibraryQuery.smartCounts(
            for: books.map(LibraryQuery.SearchSnapshot.init),
            searches: searches
        )

        #expect(counts[scienceFiction] == 2)
        #expect(counts[modern] == 2)
        #expect(snapshotCounts == counts)
    }

    @Test func titleSortIsAscending() {
        let books = [makeBook("Banana"), makeBook("Apple")]
        let sort = [BookSort.title.comparator(ascending: true)]
        let result = LibraryQuery.apply(to: books, filter: .all, searchText: "", sort: sort)
        #expect(result.map(\.title) == ["Apple", "Banana"])
    }

    @Test func seriesFilterOrdersByIndex() {
        let books = [makeBook("Two", series: "S", seriesIndex: "2"),
                     makeBook("One", series: "S", seriesIndex: "1")]
        let result = LibraryQuery.apply(to: books, filter: .series("S"), searchText: "", sort: [])
        #expect(result.map(\.title) == ["One", "Two"])
    }

    @Test func displaySnapshotsPreserveFilteringSearchAndSortSemantics() {
        let dune = makeBook("Dune", author: "Frank Herbert", tags: ["sci-fi"], status: .reading)
        let dispossessed = makeBook(
            "The Dispossessed",
            author: "Ursula Le Guin",
            tags: ["sci-fi"],
            status: .reading
        )
        let emma = makeBook("Emma", author: "Jane Austen", tags: ["classic"], status: .reading)
        let books = [dispossessed, emma, dune]
        let snapshots = books.enumerated().map {
            LibraryDisplaySnapshot(
                $0.element,
                sourceOrdinal: $0.offset,
                includeCollections: false,
                includeHighlights: false
            )
        }

        let ids = LibraryQuery.displayIDs(
            for: snapshots,
            filter: .status(.reading),
            searchText: "tag:sci-fi",
            sort: LibraryDisplaySort(field: .title, ascending: true),
            savedSearch: nil,
            smartShelf: nil,
            deviceFileNames: [],
            deviceIsConnected: false
        )

        #expect(ids == [dune.uuid, dispossessed.uuid])
    }

    @Test func concurrentDisplayPathMatchesLegacyQuerySemantics() async {
        let dune = makeBook("Dune", author: "Frank Herbert", tags: ["sci-fi"], status: .reading)
        let dispossessed = makeBook(
            "The Dispossessed",
            author: "Ursula Le Guin",
            tags: ["sci-fi"],
            status: .reading
        )
        let emma = makeBook("Emma", author: "Jane Austen", tags: ["classic"], status: .reading)
        let books = [dispossessed, emma, dune]
        let sort = [BookSort.title.comparator(ascending: true)]
        let expected = LibraryQuery.apply(
            to: books,
            filter: .status(.reading),
            searchText: "tag:sci-fi",
            sort: sort
        ).map(\.uuid)
        let snapshots = books.enumerated().map {
            LibraryDisplaySnapshot(
                $0.element,
                sourceOrdinal: $0.offset,
                includeCollections: true,
                includeHighlights: true
            )
        }

        let actual = await LibraryQuery.displayIDsConcurrently(
            for: snapshots,
            filter: .status(.reading),
            searchText: "tag:sci-fi",
            sort: LibraryDisplaySort(field: .title, ascending: true),
            savedSearch: nil,
            smartShelf: nil,
            deviceFileNames: [],
            deviceIsConnected: false
        )

        #expect(actual == expected)
    }

    @Test func displaySnapshotsComposeSavedAndStructuredShelvesWithVisibleSearch() {
        let dune = makeBook("Dune", tags: ["sci-fi"])
        let foundation = makeBook("Foundation", tags: ["sci-fi"])
        let emma = makeBook("Emma", tags: ["classic"])
        let books = [foundation, emma, dune]
        let snapshots = books.enumerated().map {
            LibraryDisplaySnapshot(
                $0.element,
                sourceOrdinal: $0.offset,
                includeCollections: false,
                includeHighlights: false
            )
        }
        let shelf = SmartShelfDefinition(rules: [
            SmartShelfRule(field: .tag, comparison: .contains, value: "sci-fi"),
        ])

        let savedIDs = LibraryQuery.displayIDs(
            for: snapshots,
            filter: .all,
            searchText: "title:dune",
            sort: .sourceOrder,
            savedSearch: "tag:sci-fi",
            smartShelf: nil,
            deviceFileNames: [],
            deviceIsConnected: false
        )
        let structuredIDs = LibraryQuery.displayIDs(
            for: snapshots,
            filter: .all,
            searchText: "title:dune",
            sort: .sourceOrder,
            savedSearch: nil,
            smartShelf: shelf,
            deviceFileNames: [],
            deviceIsConnected: false
        )

        #expect(savedIDs == [dune.uuid])
        #expect(structuredIDs == savedIDs)
    }

    @Test func displaySnapshotQueryFiltersByKindlePresenceOnlyWhileConnected() {
        let onKindle = makeBook("On Kindle")
        onKindle.originalFileName = "on-kindle.epub"
        let notOnKindle = makeBook("Not on Kindle")
        notOnKindle.originalFileName = "not-on-kindle.epub"
        let books = [onKindle, notOnKindle]
        let snapshots = books.enumerated().map {
            LibraryDisplaySnapshot(
                $0.element,
                sourceOrdinal: $0.offset,
                includeCollections: false,
                includeHighlights: false
            )
        }
        let deviceFileNames = Set([onKindle.deviceMatchKey])

        let onKindleIDs = LibraryQuery.displayIDs(
            for: snapshots,
            filter: .all,
            searchText: "",
            sort: .sourceOrder,
            savedSearch: nil,
            smartShelf: nil,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: true,
            kindlePresenceFilter: .onKindle
        )
        let notOnKindleIDs = LibraryQuery.displayIDs(
            for: snapshots,
            filter: .all,
            searchText: "",
            sort: .sourceOrder,
            savedSearch: nil,
            smartShelf: nil,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: true,
            kindlePresenceFilter: .notOnKindle
        )
        let disconnectedIDs = LibraryQuery.displayIDs(
            for: snapshots,
            filter: .all,
            searchText: "",
            sort: .sourceOrder,
            savedSearch: nil,
            smartShelf: nil,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: false,
            kindlePresenceFilter: .onKindle
        )

        #expect(onKindleIDs == [onKindle.uuid])
        #expect(notOnKindleIDs == [notOnKindle.uuid])
        #expect(disconnectedIDs == books.map(\.uuid))
    }

    @Test func displaySnapshotQueryScalesToLargeLibraries() {
        let books = (0..<10_000).map { index in
            makeBook(
                String(format: "Book %05d", 10_000 - index),
                author: "Writer \(index % 100)",
                tags: index.isMultiple(of: 4) ? ["target"] : ["other"],
                status: index.isMultiple(of: 2) ? .reading : .unread
            )
        }
        let snapshots = books.enumerated().map {
            LibraryDisplaySnapshot(
                $0.element,
                sourceOrdinal: $0.offset,
                includeCollections: false,
                includeHighlights: false
            )
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let ids = LibraryQuery.displayIDs(
            for: snapshots,
            filter: .status(.reading),
            searchText: "tag:target",
            sort: LibraryDisplaySort(field: .title, ascending: true),
            savedSearch: nil,
            smartShelf: nil,
            deviceFileNames: [],
            deviceIsConnected: false
        )
        let elapsed = startedAt.duration(to: clock.now)

        #expect(ids.count == 2_500)
        #expect(elapsed < .seconds(1))
    }
}
