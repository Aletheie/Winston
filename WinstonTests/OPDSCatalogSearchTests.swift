import Foundation
import Testing
@testable import Winston

@Suite
struct OPDSCatalogSearchTests {
    private let ownership = OPDSLocalOwnershipIndex(records: [])

    @Test func `Identical canonical ISBN groups and keeps every source`() throws {
        let first = publication(
            id: "first",
            isbn: "9780306406157",
            title: "Shared Book",
            author: "Ada Author"
        )
        let second = publication(
            id: "second",
            isbn: "978-0-306-40615-7",
            title: "Shared Book: An Edition",
            author: "Ada Author"
        )
        let groups = OPDSSearchAggregator.aggregate(
            states: [
                "one": .success([first]),
                "two": .success([second]),
            ],
            catalogNames: ["one": "One", "two": "Two"],
            ownership: ownership
        )

        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.variants.map(\.catalogID) == ["one", "two"])
        #expect(group.variants.map(\.publication.id) == [
            "first", "second",
        ])
    }

    @Test func `Conflicting ISBNs never group`() {
        let groups = OPDSSearchAggregator.aggregate(
            states: [
                "one": .success([
                    publication(
                        id: "first",
                        isbn: "9780306406157",
                        title: "Same Name",
                        author: "Same Author"
                    ),
                ]),
                "two": .success([
                    publication(
                        id: "second",
                        isbn: "9783161484100",
                        title: "Same Name",
                        author: "Same Author"
                    ),
                ]),
            ],
            catalogNames: ["one": "One", "two": "Two"],
            ownership: ownership
        )

        #expect(groups.count == 2)
    }

    @Test func `Title author grouping is presentation-only and retains variants`() throws {
        let groups = OPDSSearchAggregator.aggregate(
            states: [
                "one": .success([
                    publication(
                        id: "first",
                        isbn: nil,
                        title: "The Robot",
                        author: "Karel Čapek"
                    ),
                ]),
                "two": .success([
                    publication(
                        id: "second",
                        isbn: nil,
                        title: "  the robot ",
                        author: "KAREL ČAPEK"
                    ),
                ]),
            ],
            catalogNames: ["one": "One", "two": "Two"],
            ownership: ownership
        )

        let group = try #require(groups.first)
        #expect(groups.count == 1)
        if case .normalizedName = group.basis {
            #expect(group.variants.count == 2)
        } else {
            Issue.record("Expected a presentation-only name group.")
        }
    }

    @Test func `Acquisition relations control direct import`() throws {
        let url = try #require(
            URL(string: "https://catalog.example/book.epub")
        )
        let open = try #require(OPDSAcquisition.make(
            url: url,
            mediaType: "application/epub+zip",
            title: nil,
            relations: [
                "http://opds-spec.org/acquisition/open-access",
            ]
        ))
        let buy = try #require(OPDSAcquisition.make(
            url: url,
            mediaType: "application/epub+zip",
            title: nil,
            relations: [
                "http://opds-spec.org/acquisition/buy",
            ]
        ))
        let sample = try #require(OPDSAcquisition.make(
            url: url,
            mediaType: "application/epub+zip",
            title: nil,
            relations: [
                "http://opds-spec.org/acquisition/sample",
            ]
        ))

        #expect(open.canImport)
        #expect(!buy.canImport)
        #expect(!sample.canImport)
    }

    @Test func `Missing series book creates focused catalog seed`() throws {
        let book = HardcoverSeriesBook(
            id: 42,
            title: "The Missing Volume",
            position: 3,
            positionText: "3",
            authors: ["Ada Author"],
            hardcoverURL: try #require(
                URL(string: "https://hardcover.app/books/42")
            ),
            releaseDate: nil,
            coverURL: nil
        )

        let seed = CatalogSearchSeed(
            seriesBook: book,
            seriesName: "Robot Stories"
        )

        #expect(seed.query == "The Missing Volume Ada Author")
        #expect(seed.context == "Robot Stories · Book 3")
    }

    private func publication(
        id: String,
        isbn: String?,
        title: String,
        author: String
    ) -> OPDSPublication {
        OPDSPublication(
            id: id,
            identifiers: [isbn].compactMap { $0 },
            title: title,
            authors: [author],
            summary: nil,
            language: "en",
            coverURL: nil,
            acquisitions: []
        )
    }
}
