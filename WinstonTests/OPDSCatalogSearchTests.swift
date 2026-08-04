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
        let localizedPosition = String(
            localized: "Book \(book.positionText ?? "3")"
        )
        #expect(seed.context == "Robot Stories · \(localizedPosition)")
    }

    @Test func `Failed catalog keeps successful catalog results`() async throws {
        let catalogs = OPDSCatalogConfiguration.builtInDefaults
        let successful = catalogs[0]
        let failing = catalogs[1]
        let client = ScenarioOPDSClient(failingRoot: failing.rootURL)
        let service = OPDSCatalogSearchService(
            client: client,
            maximumConcurrentCatalogs: 2
        )
        var states: [String: OPDSCatalogSearchState] = [:]

        for await update in service.updates(
            accesses: catalogs.map {
                OPDSCatalogAccess(configuration: $0, credential: nil)
            },
            query: "robot"
        ) {
            states[update.catalogID] = update.state
        }

        if case .success(let publications) = states[successful.id] {
            #expect(publications.map(\.title) == ["Robot"])
        } else {
            Issue.record("Expected the successful catalog result.")
        }
        #expect(states[failing.id] == .failed(.server(503)))
        let groups = OPDSSearchAggregator.aggregate(
            states: states,
            catalogNames: Dictionary(
                uniqueKeysWithValues: catalogs.map { ($0.id, $0.name) }
            ),
            ownership: ownership
        )
        #expect(groups.map(\.title) == ["Robot"])
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

actor ScenarioOPDSClient: OPDSFetching {
    private let failingRoot: URL?

    init(failingRoot: URL? = nil) {
        self.failingRoot = failingRoot
    }

    func feed(at url: URL) async throws -> OPDSFeed {
        if url == failingRoot {
            throw OPDSServiceError.server(503)
        }
        if let query = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "query" })?.value {
            if query == "obsolete" {
                try await Task.sleep(for: .milliseconds(300))
            }
            return OPDSFeed(
                title: "Results",
                subtitle: nil,
                navigation: [],
                publications: [
                    OPDSPublication(
                        id: "\(url.host() ?? "catalog")-\(query)",
                        title: query.capitalized,
                        authors: ["Ada Author"],
                        summary: nil,
                        language: "en",
                        coverURL: nil,
                        acquisitions: []
                    ),
                ],
                nextURL: nil,
                searchLink: nil
            )
        }
        return OPDSFeed(
            title: "Root",
            subtitle: nil,
            navigation: [],
            publications: [],
            nextURL: nil,
            searchLink: .template(
                "\(url.absoluteString)?query={searchTerms}"
            )
        )
    }

    func download(
        _ acquisition: OPDSAcquisition,
        title: String
    ) async throws -> URL {
        throw OPDSServiceError.invalidDownload
    }
}
