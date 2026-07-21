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

    @Test func `Gutenberg image variants merge into one publication`() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:dcterms="http://purl.org/dc/terms/">
          <title>Gutenberg detail</title>
          <entry>
            <id>urn:gutenberg:37525:2</id>
            <title>Dvojník</title>
            <author><name>Dostoyevsky, Fyodor</name></author>
            <dcterms:language>cs</dcterms:language>
            <link rel="http://opds-spec.org/acquisition" href="/37525.epub.noimages" type="application/epub+zip" title="EPUB (no images)"/>
          </entry>
          <entry>
            <id>urn:gutenberg:37525:3</id>
            <title>Dvojník</title>
            <author><name>Dostoyevsky, Fyodor</name></author>
            <dcterms:language>cs</dcterms:language>
            <link rel="http://opds-spec.org/acquisition" href="/37525.epub3.images" type="application/epub+zip" title="EPUB3 (E-readers incl. Send-to-Kindle)"/>
            <link rel="http://opds-spec.org/acquisition" href="/37525.epub.images" type="application/epub+zip" title="EPUB (older E-readers)"/>
          </entry>
        </feed>
        """

        let feed = try OPDSParser.parse(
            Data(xml.utf8),
            baseURL: URL(string: "https://www.gutenberg.org/ebooks/37525.opds")!
        )

        let publication = try #require(feed.publications.first)
        #expect(feed.publications.count == 1)
        #expect(publication.id == "urn:gutenberg:37525")
        #expect(publication.acquisitions.count == 3)
        #expect(publication.preferredAcquisition?.title == "EPUB3 (E-readers incl. Send-to-Kindle)")
        #expect(publication.acquisitionOptions.map(\.title) == [
            "EPUB3 (E-readers incl. Send-to-Kindle)",
            "EPUB (older E-readers)",
            "EPUB (no images)",
        ])
    }

    @Test func `Standard Ebooks public Atom feed decodes covers and downloads`() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
          <title>Standard Ebooks - Newest Ebooks</title>
          <subtitle>The 15 latest Standard Ebooks.</subtitle>
          <entry>
            <id>https://standardebooks.org/ebooks/example/book</id>
            <title>A Public Book</title>
            <author><name>Ada Author</name></author>
            <summary type="text">A carefully produced edition.</summary>
            <media:thumbnail url="https://standardebooks.org/ebooks/example/book/downloads/cover-thumbnail.jpg"/>
            <link rel="enclosure" href="https://standardebooks.org/ebooks/example/book/downloads/book.epub?source=feed" type="application/epub+zip" title="Recommended compatible epub"/>
            <link rel="enclosure" href="https://standardebooks.org/ebooks/example/book/downloads/book.azw3?source=feed" type="application/x-mobipocket-ebook" title="Amazon Kindle azw3"/>
          </entry>
        </feed>
        """

        let feed = try OPDSParser.parse(
            Data(xml.utf8),
            baseURL: URL(string: "https://standardebooks.org/feeds/atom/new-releases")!
        )

        let publication = try #require(feed.publications.first)
        #expect(OPDSCatalog.builtIn[1].rootURL.absoluteString ==
            "https://standardebooks.org/feeds/atom/new-releases")
        #expect(publication.coverURL?.absoluteString ==
            "https://standardebooks.org/ebooks/example/book/downloads/cover-thumbnail.jpg")
        #expect(publication.acquisitions.map(\.fileExtension) == ["epub", "azw3"])
        #expect(publication.preferredAcquisition?.title == "Recommended compatible epub")
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

    @Test func `Service stops reading a feed at the byte limit`() async throws {
        OPDSTestURLProtocol.prepare(
            status: 200,
            body: Data(repeating: 0x20, count: OPDSService.maximumFeedBytes + 1)
        )
        let session = URLSession(configuration: OPDSTestURLProtocol.configuration)
        let service = OPDSService(session: session)

        await #expect(throws: OPDSServiceError.feedTooLarge) {
            try await service.feed(at: URL(string: "https://example.com/large")!)
        }
    }
}

@MainActor
@Suite(.serialized)
struct OPDSViewModelTests {
    @Test func `Offline gate performs no catalog request`() async {
        let settings = AppSettings()
        let oldValue = settings.onlineMetadataEnabled
        settings.onlineMetadataEnabled = false
        defer { settings.onlineMetadataEnabled = oldValue }
        let client = FakeOPDSClient()
        let viewModel = OPDSViewModel(settings: settings, toasts: ToastCenter(), service: client)

        await viewModel.open(OPDSCatalog.builtIn[0])

        #expect(viewModel.phase == .disabledOnline)
        #expect(await client.feedCalls == 0)
    }

    @Test func `Pagination appends unique catalog results`() async throws {
        let settings = AppSettings()
        let oldValue = settings.onlineMetadataEnabled
        settings.onlineMetadataEnabled = true
        defer { settings.onlineMetadataEnabled = oldValue }
        let catalog = OPDSCatalog.builtIn[1]
        let nextURL = URL(string: "https://example.com/page/2")!
        let first = OPDSFeed(
            title: "Catalog",
            subtitle: nil,
            navigation: [OPDSNavigationItem(
                title: "First",
                subtitle: nil,
                url: URL(string: "https://example.com/first")!,
                coverURL: nil
            )],
            publications: [],
            nextURL: nextURL,
            searchTemplate: nil
        )
        let second = OPDSFeed(
            title: "Catalog",
            subtitle: nil,
            navigation: [
                first.navigation[0],
                OPDSNavigationItem(
                    title: "Second",
                    subtitle: nil,
                    url: URL(string: "https://example.com/second")!,
                    coverURL: nil
                ),
            ],
            publications: [],
            nextURL: nil,
            searchTemplate: nil
        )
        let client = FakeOPDSClient(feeds: [catalog.rootURL: first, nextURL: second])
        let viewModel = OPDSViewModel(settings: settings, toasts: ToastCenter(), service: client)

        await viewModel.open(catalog)
        await viewModel.loadNextPage()

        #expect(viewModel.phase == .loaded)
        #expect(viewModel.feed?.navigation.map(\.title) == ["First", "Second"])
        #expect(viewModel.feed?.nextURL == nil)
    }

    @Test func `Downloaded EPUB is imported and prepared for Kindle automatically`() async throws {
        let testLibrary = try await TestLibrary()
        let settings = AppSettings()
        let oldOnline = settings.onlineMetadataEnabled
        let oldKindlePreference = UserDefaults.standard.bool(forKey: "preferKindleAZW3")
        settings.onlineMetadataEnabled = true
        UserDefaults.standard.set(false, forKey: "preferKindleAZW3")
        defer {
            settings.onlineMetadataEnabled = oldOnline
            UserDefaults.standard.set(oldKindlePreference, forKey: "preferKindleAZW3")
        }

        let source = try EPUBFixture.make(title: "Catalog Fixture", author: "OPDS Author")
        let acquisition = try #require(OPDSAcquisition.make(
            url: URL(string: "https://example.com/catalog-fixture.epub")!,
            mediaType: "application/epub+zip",
            title: "EPUB"
        ))
        let publication = OPDSPublication(
            id: "fixture",
            title: "Catalog Fixture",
            authors: ["OPDS Author"],
            summary: nil,
            language: "en",
            coverURL: nil,
            acquisitions: [acquisition]
        )
        let client = FakeOPDSClient(downloadURL: source)
        let toasts = ToastCenter()
        let library = LibraryViewModel(
            modelContext: testLibrary.context,
            settings: settings,
            toasts: toasts,
            online: OfflineMetadataClient()
        )
        let viewModel = OPDSViewModel(settings: settings, toasts: toasts, service: client)

        viewModel.addToLibrary(publication, acquisition: acquisition, library: library)

        let target = EbookConverter.kindleTarget(forFormat: "epub").ext
        let deadline = Date.now.addingTimeInterval(8)
        while Date.now < deadline {
            if let book = testLibrary.context.allBooks().first,
               book.assets.contains(where: { $0.format.lowercased() == target }) {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        let book = try #require(testLibrary.context.allBooks().first)
        #expect(viewModel.isDownloaded(publication))
        #expect(book.format.lowercased() == "epub")
        #expect(book.assets.contains(where: {
            $0.format.lowercased() == target && $0.origin == .generated
        }))
        #expect(await client.downloadCalls == 1)
    }
}

private actor FakeOPDSClient: OPDSFetching {
    private let feeds: [URL: OPDSFeed]
    private let downloadURL: URL?
    private(set) var feedCalls = 0
    private(set) var downloadCalls = 0

    init(feeds: [URL: OPDSFeed] = [:], downloadURL: URL? = nil) {
        self.feeds = feeds
        self.downloadURL = downloadURL
    }

    func feed(at url: URL) async throws -> OPDSFeed {
        feedCalls += 1
        guard let feed = feeds[url] else { throw OPDSServiceError.network }
        return feed
    }

    func download(_ acquisition: OPDSAcquisition, title: String) async throws -> URL {
        downloadCalls += 1
        guard let downloadURL else { throw OPDSServiceError.network }
        return downloadURL
    }
}

private actor OfflineMetadataClient: OnlineMetadataFetching {
    func fetch(
        isbn: String?,
        title: String,
        author: String?,
        language: MetadataLanguage,
        hardcoverToken: String?
    ) async -> OnlineMetadataFetchResult {
        OnlineMetadataFetchResult(metadata: nil, reachedNetwork: false)
    }

    func downloadCover(_ url: URL) async -> Data? { nil }
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
