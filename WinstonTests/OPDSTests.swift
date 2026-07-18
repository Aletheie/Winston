import Foundation
import SwiftData
import Testing
@testable import Winston

@Suite
struct OPDSParserTests {
    @Test func `Atom feed decodes navigation, acquisition links, and pagination`() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:dcterms="http://purl.org/dc/terms/">
          <title>Free Books</title>
          <subtitle>An open catalog.</subtitle>
          <link rel="next" href="?page=2" type="application/atom+xml;profile=opds-catalog"/>
          <entry>
            <id>folder-1</id>
            <title>Czech books</title>
            <content type="text">Books in Czech</content>
            <link rel="subsection" href="/czech.opds" type="application/atom+xml;profile=opds-catalog"/>
          </entry>
          <entry>
            <id>urn:book:1</id>
            <title>The Sample Book</title>
            <author><name>Ada Author</name></author>
            <dcterms:language>cs</dcterms:language>
            <summary type="html">A &amp; B</summary>
            <link rel="http://opds-spec.org/image" href="/cover.jpg" type="image/jpeg"/>
            <link rel="http://opds-spec.org/acquisition/open-access" href="/book.epub" type="application/epub+zip" title="EPUB"/>
            <link rel="http://opds-spec.org/acquisition/open-access" href="/book.mobi" type="application/x-mobipocket-ebook" title="Kindle"/>
          </entry>
        </feed>
        """

        let feed = try OPDSParser.parse(
            Data(xml.utf8),
            baseURL: URL(string: "https://example.com/catalog/root")!,
            contentType: "application/atom+xml;profile=opds-catalog"
        )

        #expect(feed.title == "Free Books")
        #expect(feed.subtitle == "An open catalog.")
        #expect(feed.nextURL == URL(string: "https://example.com/catalog/root?page=2"))
        let navigation = try #require(feed.navigation.first)
        #expect(navigation.title == "Czech books")
        #expect(navigation.subtitle == "Books in Czech")
        #expect(navigation.url == URL(string: "https://example.com/czech.opds"))

        let publication = try #require(feed.publications.first)
        #expect(publication.id == "urn:book:1")
        #expect(publication.authors == ["Ada Author"])
        #expect(publication.language == "cs")
        #expect(publication.summary == "A & B")
        #expect(publication.coverURL == URL(string: "https://example.com/cover.jpg"))
        #expect(publication.acquisitions.map(\.formatLabel) == ["EPUB", "MOBI"])
        #expect(publication.preferredAcquisition?.fileExtension == "epub")
    }

    @Test func `OPDS 2 feed decodes flexible metadata, groups, and search templates`() throws {
        let json = """
        {
          "metadata": {
            "title": "Modern Catalog",
            "subtitle": "OPDS 2 example"
          },
          "links": [
            { "rel": "next", "href": "/page/2", "type": "application/opds+json" },
            { "rel": ["search"], "href": "/search{?query}", "templated": true }
          ],
          "navigation": [
            { "title": "Popular", "href": "/popular", "type": "application/opds+json" }
          ],
          "publications": [{
            "metadata": {
              "identifier": "urn:book:json",
              "title": "JSON Book",
              "author": [{ "name": "One Author" }, { "name": "Two Author" }],
              "language": ["cs", "en"],
              "description": "<p>A clean <strong>summary</strong>.</p>"
            },
            "links": [
              { "rel": "http://opds-spec.org/acquisition/open-access", "href": "book.pdf", "type": "application/pdf" },
              { "rel": ["download"], "href": "book.epub", "type": "application/epub+zip" }
            ],
            "images": [{ "href": "cover.png", "type": "image/png" }]
          }],
          "groups": [{
            "navigation": [{ "title": "Languages", "href": "/languages" }]
          }]
        }
        """

        let feed = try OPDSParser.parse(
            Data(json.utf8),
            baseURL: URL(string: "https://catalog.example/root/")!,
            contentType: "application/opds+json"
        )

        #expect(feed.title == "Modern Catalog")
        #expect(feed.navigation.map(\.title) == ["Popular", "Languages"])
        #expect(feed.nextURL == URL(string: "https://catalog.example/page/2"))
        #expect(feed.searchTemplate == "https://catalog.example/search{?query}")
        let publication = try #require(feed.publications.first)
        #expect(publication.id == "urn:book:json")
        #expect(publication.authors == ["One Author", "Two Author"])
        #expect(publication.language == "cs")
        #expect(publication.summary == "A clean summary.")
        #expect(publication.coverURL == URL(string: "https://catalog.example/root/cover.png"))
        #expect(publication.preferredAcquisition?.fileExtension == "epub")
    }

    @Test func `Unsupported documents and unsafe acquisition URLs are rejected`() {
        #expect(throws: OPDSParser.ParseError.unsupportedDocument) {
            try OPDSParser.parse(
                Data("not a feed".utf8),
                baseURL: URL(string: "https://example.com")!
            )
        }
        #expect(OPDSAcquisition.make(
            url: URL(string: "file:///tmp/book.epub")!,
            mediaType: "application/epub+zip",
            title: nil
        ) == nil)
    }

    @Test(arguments: [
        ("https://example.com/search?query={searchTerms}", "Karel Čapek", "https://example.com/search?query=Karel%20%C4%8Capek"),
        ("https://example.com/search{?query}", "robot", "https://example.com/search?query=robot"),
    ])
    func `Search templates expand safely`(template: String, query: String, expected: String) {
        #expect(OPDSService.expandedSearchURL(template: template, query: query)?.absoluteString == expected)
    }
}

@Suite(.serialized)
struct OPDSServiceTests {
    @Test func `Service requests OPDS and reports authentication failures`() async throws {
        OPDSTestURLProtocol.prepare(status: 200, body: Data("""
        { "metadata": { "title": "Catalog" }, "navigation": [{ "title": "Books", "href": "/books" }] }
        """.utf8))
        let session = URLSession(configuration: OPDSTestURLProtocol.configuration)
        let service = OPDSService(session: session)

        let feed = try await service.feed(at: URL(string: "https://example.com/opds")!)
        #expect(feed.title == "Catalog")
        #expect(OPDSTestURLProtocol.lastAccept?.contains("application/opds+json") == true)

        OPDSTestURLProtocol.prepare(status: 401, body: Data())
        await #expect(throws: OPDSServiceError.authenticationRequired) {
            try await service.feed(at: URL(string: "https://example.com/private")!)
        }
    }
}
private final class OPDSTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseStatus = 200
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var storedAccept: String?

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OPDSTestURLProtocol.self]
        return configuration
    }

    static var lastAccept: String? {
        lock.withLock { storedAccept }
    }

    static func prepare(status: Int, body: Data) {
        lock.withLock {
            responseStatus = status
            responseBody = body
            storedAccept = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let values = Self.lock.withLock { () -> (Int, Data) in
            Self.storedAccept = request.value(forHTTPHeaderField: "Accept")
            return (Self.responseStatus, Self.responseBody)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: values.0,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/opds+json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: values.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
