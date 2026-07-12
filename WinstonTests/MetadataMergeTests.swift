import Testing
import Foundation
@testable import Winston


// MARK: - Extracted metadata merge (Book.apply)

@MainActor
struct BookApplyTests {

    private func makeBook() -> Book {
        Book(fileName: "u.epub", originalFileName: "u.epub")
    }

    @Test func fillsEmptyFieldsAndTrims() {
        let book = makeBook()
        var meta = BookMetadata()
        meta.title = "  Dune  "
        meta.author = "Frank Herbert"
        meta.publisher = "Ace"
        meta.year = "1965"
        meta.isbn = "9780441013593"
        meta.series = "Dune"
        meta.seriesIndex = "1"
        meta.description = "Desert planet."
        book.apply(meta)

        #expect(book.title == "Dune")
        #expect(book.author == "Frank Herbert")
        #expect(book.publisher == "Ace")
        #expect(book.year == "1965")
        #expect(book.isbn == "9780441013593")
        #expect(book.series == "Dune")
        #expect(book.seriesIndex == "1")
        #expect(book.bookDescription == "Desert planet.")
    }

    @Test func neverClobbersExistingValues() {
        let book = makeBook()
        book.title = "Existing Title"
        book.author = "Existing Author"
        var meta = BookMetadata()
        meta.title = "New Title"
        meta.author = "New Author"
        book.apply(meta)

        #expect(book.title == "Existing Title")
        #expect(book.author == "Existing Author")
    }

    @Test func emptyRescanLeavesDataIntact() {
        let book = makeBook()
        book.title = "Keep"
        book.author = "Me"
        book.apply(BookMetadata())

        #expect(book.title == "Keep")
        #expect(book.author == "Me")
    }

    @Test func tagsFillOnlyWhenEmpty() {
        let empty = makeBook()
        var meta = BookMetadata()
        meta.tags = ["sci-fi", "classic"]
        empty.apply(meta)
        #expect(empty.tags == ["sci-fi", "classic"])

        let existing = makeBook()
        existing.tags = ["keep"]
        existing.apply(meta)
        #expect(existing.tags == ["keep"])
    }

    @Test func blankIncomingValueIsIgnored() {
        let book = makeBook()
        var meta = BookMetadata()
        meta.title = "   "
        book.apply(meta)
        #expect(book.title == nil)
    }
}

// MARK: - Online metadata merge (Book.applyOnline)

@MainActor
struct BookApplyOnlineTests {

    private func makeBook() -> Book {
        Book(fileName: "u.epub", originalFileName: "u.epub")
    }

    @Test func joinsMultipleAuthors() {
        let book = makeBook()
        var fetched = FetchedMetadata()
        fetched.authors = ["Terry Pratchett", "Neil Gaiman"]
        book.applyOnline(fetched)
        #expect(book.author == "Terry Pratchett, Neil Gaiman")
    }

    @Test func doesNotOverwriteExistingAuthor() {
        let book = makeBook()
        book.author = "Local Author"
        var fetched = FetchedMetadata()
        fetched.authors = ["Online Author"]
        book.applyOnline(fetched)
        #expect(book.author == "Local Author")
    }

    @Test func fillsEmptyTextFieldsOnly() {
        let book = makeBook()
        book.title = "Local Title"
        var fetched = FetchedMetadata()
        fetched.title = "Online Title"
        fetched.publisher = "Penguin"
        fetched.year = "1990"
        fetched.bookDescription = "A synopsis."
        fetched.subjects = ["fantasy"]
        book.applyOnline(fetched)

        #expect(book.title == "Local Title")
        #expect(book.publisher == "Penguin")
        #expect(book.year == "1990")
        #expect(book.bookDescription == "A synopsis.")
        #expect(book.tags == ["fantasy"])
    }

    @Test func communityRatingIsAlwaysRefreshedWhenPresent() {
        let book = makeBook()
        book.communityRating = 1.0
        book.communityRatingSource = "Open Library"
        var fetched = FetchedMetadata()
        fetched.ratingsAverage = 4.2
        fetched.ratingsCount = 321
        fetched.ratingsSource = "Hardcover"
        book.applyOnline(fetched)

        #expect(book.communityRating == 4.2)
        #expect(book.communityRatingCount == 321)
        #expect(book.communityRatingSource == "Hardcover")
    }

    @Test func communityRatingUntouchedWhenFetchHasNone() {
        let book = makeBook()
        book.communityRating = 3.0
        book.communityRatingSource = "Google Books"
        book.applyOnline(FetchedMetadata())

        #expect(book.communityRating == 3.0)
        #expect(book.communityRatingSource == "Google Books")
    }
}
