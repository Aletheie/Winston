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
}
