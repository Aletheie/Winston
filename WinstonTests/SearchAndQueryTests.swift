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
        let result = LibraryQuery.apply(
            to: books,
            filter: .status(.reading),
            searchText: "",
            sort: .sourceOrder
        )
        #expect(result.map(\.title) == ["A"])
    }

    @Test func authorNavigationUsesTheExistingLibraryFilter() {
        let author = "Ursula K. Le Guin"
        let selection = SidebarItem.author(author)
        let books = [
            makeBook("A Wizard of Earthsea", author: author),
            makeBook("The Tombs of Atuan", author: author),
            makeBook("Dune", author: "Frank Herbert"),
        ]

        #expect(selection.libraryFilter == .author(author))
        #expect(SidebarItem(rawValue: selection.rawValue) == selection)
        #expect(
            LibraryQuery.apply(
                to: books,
                filter: selection.libraryFilter,
                searchText: "",
                sort: .sourceOrder
            )
                .map(\.title) == ["A Wizard of Earthsea", "The Tombs of Atuan"]
        )
    }

    @Test func fieldSearchNarrowsByTag() {
        let books = [makeBook("Dune", tags: ["sci-fi"]), makeBook("Mythago", tags: ["fantasy"])]
        let result = LibraryQuery.apply(
            to: books,
            filter: .all,
            searchText: "tag:sci-fi",
            sort: .sourceOrder
        )
        #expect(result.map(\.title) == ["Dune"])
    }

    @Test func yearConstraintFilters() {
        let books = [makeBook("Old", year: "1980"), makeBook("New", year: "2020")]
        let result = LibraryQuery.apply(
            to: books,
            filter: .all,
            searchText: "year:>2000",
            sort: .sourceOrder
        )
        #expect(result.map(\.title) == ["New"])
    }

    @Test func freeTextMatchesTitleOrAuthor() {
        let books = [makeBook("Dune", author: "Herbert"), makeBook("Other", author: "Asimov")]
        #expect(
            LibraryQuery.apply(
                to: books,
                filter: .all,
                searchText: "herbert",
                sort: .sourceOrder
            ).map(\.title) == ["Dune"]
        )
    }

    @Test func freeTextMatchesNotes() {
        let withNote = makeBook("Untitled")
        withNote.notes = "borrowed from Jana"
        let plain = makeBook("Other")
        let result = LibraryQuery.apply(
            to: [withNote, plain],
            filter: .all,
            searchText: "jana",
            sort: .sourceOrder
        )
        #expect(result.map(\.title) == ["Untitled"])
    }

    @Test func freeTextMatchesLanguageThroughTheCanonicalEvaluator() {
        let czech = makeBook("Duna")
        czech.language = "Čeština"
        let english = makeBook("Dune")
        english.language = "English"

        let result = LibraryQuery.apply(
            to: [english, czech],
            filter: .all,
            searchText: "cestina",
            sort: .sourceOrder
        )

        #expect(result.map(\.uuid) == [czech.uuid])
    }

    @Test func languageAndTranslatorFieldsFilterEditions() {
        let matching = makeBook("Duna")
        matching.language = "cs"
        matching.translator = "Jan Novák"
        let other = makeBook("Dune")
        other.language = "en"
        let result = LibraryQuery.apply(
            to: [matching, other], filter: .all,
            searchText: "language:cs translator:novák", sort: .sourceOrder
        )
        #expect(result.map(\.title) == ["Duna"])
    }

    @Test func languageAliasesSelectTheBaseGroupAndRegionalTagsStayExact() {
        let american = makeBook("American")
        american.language = "en-US"
        let british = makeBook("British")
        british.language = "en-GB"
        let czech = makeBook("Czech")
        czech.language = "ces"
        let books = [american, british, czech]

        for operand in ["en", "eng", "English"] {
            let result = LibraryQuery.apply(
                to: books,
                filter: .all,
                searchText: "language:\(operand)",
                sort: .sourceOrder
            )
            #expect(result.map(\.title) == ["American", "British"])
        }

        let regional = LibraryQuery.apply(
            to: books,
            filter: .all,
            searchText: "language:en-GB",
            sort: .sourceOrder
        )
        #expect(regional.map(\.title) == ["British"])
    }

    @Test func malformedLanguageValuesRemainExactlySearchable() {
        let unknown = makeBook("Unknown")
        unknown.language = "Made Up"
        let english = makeBook("English")
        english.language = "en"

        let result = LibraryQuery.apply(
            to: [unknown, english],
            filter: .all,
            searchText: "language:\"Made Up\"",
            sort: .sourceOrder
        )

        #expect(result.map(\.title) == ["Unknown"])
    }

    @Test func oldSavedLanguageOperandsNormalizeWhenEvaluated() {
        let american = makeBook("American")
        american.language = "en-US"
        let czech = makeBook("Czech")
        czech.language = "cs"
        let books = [american, czech]
        let legacyShelf = SmartShelfDefinition(rules: [
            SmartShelfRule(
                field: .language,
                comparison: .isEqual,
                value: "English"
            ),
        ])

        let result = LibraryQuery.applySmartShelf(
            to: books,
            definition: legacyShelf,
            deviceFileNames: [],
            deviceIsConnected: false,
            sort: .sourceOrder
        )

        #expect(result.map(\.title) == ["American"])
    }

    @Test func projectionDerivesCanonicalMetadataWithoutChangingRawValues() {
        let book = makeBook("Projection")
        book.language = "cze"
        book.isbn = "0-306-40615-2"

        let record = LibraryBookRecord(
            book,
            sourceOrdinal: 0,
            includeCollections: false,
            includeHighlights: false
        )

        #expect(record.language == "cze")
        #expect(record.isbn == "0-306-40615-2")
        #expect(record.canonicalLanguageTag == "cs")
        #expect(record.baseLanguageCode == "cs")
        #expect(record.languageNormalizationStatus == .recognized)
        #expect(record.canonicalISBN13 == "9780306406157")
        #expect(book.language == "cze")
        #expect(book.isbn == "0-306-40615-2")
    }

    @Test func formatFilteringAliasesHTMOnlyAndTagsIgnoreCase() {
        let html = makeBook("HTML", tags: ["Sci-Fi"])
        html.fileName = "page.htm"
        let mobi = makeBook("MOBI")
        mobi.fileName = "book.mobi"
        let azw = makeBook("AZW")
        azw.fileName = "book.azw"

        let htmlResult = LibraryQuery.apply(
            to: [html, mobi, azw],
            filter: .format("HTML"),
            searchText: "",
            sort: .sourceOrder
        )
        let tagResult = LibraryQuery.apply(
            to: [html, mobi, azw],
            filter: .tag("sci-fi"),
            searchText: "",
            sort: .sourceOrder
        )

        #expect(htmlResult.map(\.title) == ["HTML"])
        #expect(tagResult.map(\.title) == ["HTML"])
        #expect(MetadataNormalizer.formatFilterKey(mobi.format) != MetadataNormalizer.formatFilterKey(azw.format))
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
        let sort = LibraryDisplaySort(field: .title, ascending: true)
        let result = LibraryQuery.apply(to: books, filter: .all, searchText: "", sort: sort)
        #expect(result.map(\.title) == ["Apple", "Banana"])
    }

    @Test func librarySortPreferenceRoundTripsSceneStorageRepresentation() throws {
        let preference = LibrarySortPreference(field: .author, ascending: false)
        let restored = try #require(LibrarySortPreference(rawValue: preference.rawValue))

        #expect(restored == preference)
        #expect(restored.displaySort == LibraryDisplaySort(field: .author, ascending: false))
        #expect(LibrarySortPreference(rawValue: "unknown:true") == nil)
    }

    @Test func seriesFilterOrdersByIndex() {
        let books = [makeBook("Two", series: "S", seriesIndex: "2"),
                     makeBook("One", series: "S", seriesIndex: "1")]
        let result = LibraryQuery.apply(
            to: books,
            filter: .series("S"),
            searchText: "",
            sort: .sourceOrder
        )
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
            LibraryBookRecord(
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
        let sort = LibraryDisplaySort(field: .title, ascending: true)
        let expected = LibraryQuery.apply(
            to: books,
            filter: .status(.reading),
            searchText: "tag:sci-fi",
            sort: sort
        ).map(\.uuid)
        let snapshots = books.enumerated().map {
            LibraryBookRecord(
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
            LibraryBookRecord(
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
            LibraryBookRecord(
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
            LibraryBookRecord(
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
