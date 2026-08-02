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
        #expect(OPDSCatalogConfiguration.builtInDefaults[1].rootURL.absoluteString ==
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
        #expect(feed.documentFormat == .opds2)
        #expect(feed.capabilities.hasBrowseNavigation)
        #expect(feed.capabilities.hasRemoteSearch)
        #expect(feed.capabilities.hasPagination)
        #expect(feed.capabilities.hasAcquisitions)
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

    @Test func `OpenSearch description resolves an OPDS template`() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
          <ShortName>Books</ShortName>
          <Url type="application/atom+xml;profile=opds-catalog"
               template="/search?query={searchTerms}"/>
        </OpenSearchDescription>
        """

        let template = try OPDSParser.parseOpenSearch(
            Data(xml.utf8),
            baseURL: URL(
                string: "https://catalog.example/descriptions/search.xml"
            )!
        )

        #expect(
            template
                == "https://catalog.example/search?query={searchTerms}"
        )
    }

    @Test func `Publication metadata and paid acquisition remain visible`() throws {
        let json = """
        {
          "metadata": { "title": "Store" },
          "publications": [{
            "metadata": {
              "identifier": ["urn:isbn:9780306406157", "provider:42"],
              "title": "Detailed Book",
              "author": "Ada Author",
              "language": "en",
              "subject": [{"name": "Fiction"}, {"name": "Robots"}],
              "rights": "Licensed reading copy",
              "published": "2026-07-31"
            },
            "links": [{
              "rel": "buy",
              "href": "/buy/book.epub",
              "type": "application/epub+zip",
              "properties": {
                "price": { "currency": "eur", "value": "4.99" }
              }
            }]
          }]
        }
        """

        let feed = try OPDSParser.parse(
            Data(json.utf8),
            baseURL: URL(string: "https://catalog.example/opds")!,
            contentType: "application/opds+json"
        )
        let publication = try #require(feed.publications.first)
        let acquisition = try #require(publication.acquisitions.first)

        #expect(publication.identifiers == [
            "urn:isbn:9780306406157", "provider:42",
        ])
        #expect(publication.subjects == ["Fiction", "Robots"])
        #expect(publication.rights == "Licensed reading copy")
        #expect(publication.published == "2026-07-31")
        #expect(acquisition.relation == .buy)
        #expect(acquisition.price == Decimal(string: "4.99"))
        #expect(acquisition.currency == "EUR")
        #expect(!acquisition.canImport)
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

    @Test func `Unglue root stays on OPDS and receives its documented title search fallback`() async throws {
        OPDSTestURLProtocol.prepare(
            status: 200,
            body: Data(#"{"metadata":{"title":"Unglue.it"}}"#.utf8)
        )
        let service = OPDSService(
            session: URLSession(
                configuration: OPDSTestURLProtocol.configuration
            )
        )
        let configuration = try #require(
            OPDSCatalogConfiguration.builtInDefaults.first {
                $0.builtIn == .unglueIt
            }
        )

        let feed = try await service.feed(
            at: configuration.rootURL,
            access: OPDSCatalogAccess(
                configuration: configuration,
                credential: nil
            )
        )

        #expect(feed.documentFormat == .opds2)
        #expect(
            feed.searchTemplate
                == "https://unglue.it/api/opds/s.{searchTerms}/"
        )
        #expect(
            OPDSTestURLProtocol.lastAccept?.contains(
                "application/opds+json"
            ) == true
        )
    }

    @Test func `Wikisource search uses Action API and defers WS Export`() async throws {
        WikisourceSearchURLProtocol.prepare()
        let service = OPDSService(
            session: URLSession(
                configuration: WikisourceSearchURLProtocol.configuration
            )
        )
        let configuration = try #require(
            OPDSCatalogConfiguration.builtInDefaults(
                for: .english,
                preferredLocalizations: ["cs"]
            ).first { $0.builtIn == .wikisource }
        )
        let access = OPDSCatalogAccess(
            configuration: configuration,
            credential: nil
        )

        let root = try await service.feed(
            at: configuration.rootURL,
            access: access
        )
        #expect(root.documentFormat == .mediaWiki)
        #expect(WikisourceSearchURLProtocol.requestedHosts.isEmpty)
        let searchLink = try #require(root.searchLink)
        let template = try #require(
            try await service.resolvedSearchTemplate(
                for: searchLink,
                access: access
            )
        )
        let searchURL = try #require(OPDSService.expandedSearchURL(
            template: template,
            query: "Pride and Prejudice"
        ))
        let results = try await service.feed(
            at: searchURL,
            access: access
        )
        let publication = try #require(results.publications.first)
        let acquisition = try #require(
            publication.preferredAcquisition
        )

        #expect(WikisourceSearchURLProtocol.requestedHosts == [
            "en.wikisource.org",
        ])
        #expect(publication.title == "Pride and Prejudice")
        #expect(publication.sourceURL?.host == "en.wikisource.org")
        #expect(publication.attribution == "Wikisource")
        #expect(publication.contributors == ["Ada", "Charles"])
        #expect(acquisition.url.host == "ws-export.wmcloud.org")
        #expect(acquisition.canImport)
        let exportQuery = URLComponents(
            url: acquisition.url,
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(exportQuery?.contains {
            $0.name == "format" && $0.value == "epub"
        } == true)
        #expect(exportQuery?.contains {
            $0.name == "credits" && $0.value == "true"
        } == true)
        #expect(!WikisourceSearchURLProtocol.requestedHosts.contains(
            "ws-export.wmcloud.org"
        ))
    }

    @Test func `Catalog test follows one advertised OPDS discovery link`() async throws {
        let enteredURL = URL(string: "https://discover.example/")!
        let catalogURL = URL(string: "https://discover.example/opds")!
        OPDSDiscoveryURLProtocol.prepare(routes: [
            enteredURL: .init(
                contentType: "text/html",
                body: Data("""
                <html><head>
                  <link rel="alternate" type="application/opds+json" href="/opds">
                </head></html>
                """.utf8)
            ),
            catalogURL: .init(
                contentType: "application/opds+json",
                body: Data("""
                {
                  "metadata": { "title": "Discovered Catalog" },
                  "navigation": [{ "title": "Books", "href": "/books" }]
                }
                """.utf8)
            ),
        ])
        let service = OPDSService(
            session: URLSession(
                configuration: OPDSDiscoveryURLProtocol.configuration
            )
        )
        let configuration = OPDSCatalogConfiguration(
            id: "discovery",
            name: "Discovery",
            rootURL: enteredURL
        )

        let result = try await service.testCatalog(
            access: OPDSCatalogAccess(
                configuration: configuration,
                credential: nil
            )
        )

        #expect(result.title == "Discovered Catalog")
        #expect(result.discoveredRootURL == catalogURL)
        #expect(result.canBrowse)
        #expect(OPDSDiscoveryURLProtocol.requestCount == 2)
    }

    @Test func `Catalog test rejects an HTML MIME hint without a discovery relationship`() async {
        let enteredURL = URL(string: "https://discover.example/")!
        OPDSDiscoveryURLProtocol.prepare(routes: [
            enteredURL: .init(
                contentType: "text/html",
                body: Data("""
                <html><head>
                  <link type="application/opds+json" href="/opds">
                </head></html>
                """.utf8)
            ),
        ])
        let service = OPDSService(
            session: URLSession(
                configuration: OPDSDiscoveryURLProtocol.configuration
            )
        )
        let configuration = OPDSCatalogConfiguration(
            id: "misleading",
            name: "Misleading",
            rootURL: enteredURL
        )

        await #expect(throws: OPDSServiceError.invalidFeed) {
            try await service.testCatalog(
                access: OPDSCatalogAccess(
                    configuration: configuration,
                    credential: nil
                )
            )
        }
        #expect(OPDSDiscoveryURLProtocol.requestCount == 1)
    }

    @Test func `Cancelling a catalog download leaves no managed temporary data`() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WinstonCatalogDownloadCancellation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        SlowOPDSDownloadURLProtocol.prepare()
        let service = OPDSService(
            session: URLSession(
                configuration: SlowOPDSDownloadURLProtocol.configuration
            ),
            importSourceLeases: ImportSourceLeaseStore(
                rootDirectory: root
            )
        )
        let acquisition = try #require(OPDSAcquisition.make(
            url: URL(string: "https://download.example/book.epub")!,
            mediaType: "application/epub+zip",
            title: "EPUB"
        ))
        let configuration = OPDSCatalogConfiguration(
            id: "download-cancellation",
            name: "Download Cancellation",
            rootURL: URL(string: "https://download.example/opds")!
        )
        let task = Task {
            try await service.download(
                acquisition,
                title: "Cancelled Book",
                access: OPDSCatalogAccess(
                    configuration: configuration,
                    credential: nil
                )
            )
        }

        let deadline = Date.now.addingTimeInterval(2)
        while !SlowOPDSDownloadURLProtocol.didStart,
              Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        _ = try? await task.value

        let remaining = if FileManager.default.fileExists(
            atPath: root.path(percentEncoded: false)
        ) {
            try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            )
        } else {
            []
        }
        #expect(SlowOPDSDownloadURLProtocol.didStop)
        #expect(remaining.isEmpty)
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

        await viewModel.open(
            OPDSCatalogConfiguration.builtInDefaults[0]
        )

        #expect(viewModel.phase == .disabledOnline)
        #expect(await client.feedCalls == 0)
    }

    @Test func `Pagination appends unique catalog results`() async throws {
        let settings = AppSettings()
        let oldValue = settings.onlineMetadataEnabled
        settings.onlineMetadataEnabled = true
        defer { settings.onlineMetadataEnabled = oldValue }
        let catalog = OPDSCatalogConfiguration.builtInDefaults[1]
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
            searchLink: nil
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
            searchLink: nil
        )
        let client = FakeOPDSClient(feeds: [catalog.rootURL: first, nextURL: second])
        let viewModel = OPDSViewModel(settings: settings, toasts: ToastCenter(), service: client)

        await viewModel.open(catalog)
        await viewModel.loadNextPage()

        #expect(viewModel.phase == .loaded)
        #expect(viewModel.feed?.navigation.map(\.title) == ["First", "Second"])
        #expect(viewModel.feed?.nextURL == nil)
    }

    @Test func `Downloaded EPUB waits for Import Review then commits normally`() async throws {
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
            sourceURL: URL(
                string: "https://example.com/books/catalog-fixture"
            ),
            attribution: "Example contributors",
            contributors: ["Ada", "Charles"],
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
        var successfulImportCount = 0

        viewModel.addToLibrary(
            publication,
            acquisition: acquisition,
            catalogID:
                OPDSBuiltInCatalog.projectGutenberg.stableID,
            library: library,
            onSuccessfulImport: { imported in
                successfulImportCount += imported.count
            }
        )

        let deadline = Date.now.addingTimeInterval(8)
        while Date.now < deadline {
            if library.preparedImportBatch?.phase == .ready {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        #expect(testLibrary.context.allBooks().isEmpty)
        #expect(library.preparedImportBatch?.phase == .ready)
        #expect(
            library.preparedImportBatch?.items.first?
                .catalogContext?.contributors == ["Ada", "Charles"]
        )
        #expect(successfulImportCount == 0)
        library.commitImportReview()

        let commitDeadline = Date.now.addingTimeInterval(8)
        while Date.now < commitDeadline {
            if !testLibrary.context.allBooks().isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let book = try #require(testLibrary.context.allBooks().first)
        #expect(viewModel.isDownloaded(
            publication,
            catalogID:
                OPDSBuiltInCatalog.projectGutenberg.stableID
        ))
        #expect(book.format.lowercased() == "epub")
        #expect(book.primaryAsset?.sourceProvenance == .catalogImport)
        #expect(
            book.primaryAsset?.sourceIdentifier
                == "https://example.com/books/catalog-fixture"
        )
        #expect(successfulImportCount == 1)
        #expect(await client.downloadCalls == 1)
    }

    @Test func `Failed catalog import never starts the send callback`() async throws {
        let testLibrary = try await TestLibrary()
        let settings = AppSettings()
        let oldValue = settings.onlineMetadataEnabled
        settings.onlineMetadataEnabled = true
        defer { settings.onlineMetadataEnabled = oldValue }
        let acquisition = try #require(OPDSAcquisition.make(
            url: URL(string: "https://example.com/unavailable.epub")!,
            mediaType: "application/epub+zip",
            title: "EPUB"
        ))
        let publication = OPDSPublication(
            id: "unavailable",
            title: "Unavailable",
            authors: ["Ada Author"],
            summary: nil,
            language: "en",
            coverURL: nil,
            acquisitions: [acquisition]
        )
        let client = FakeOPDSClient()
        let library = LibraryViewModel(
            modelContext: testLibrary.context,
            settings: settings,
            toasts: ToastCenter(),
            online: OfflineMetadataClient()
        )
        let viewModel = OPDSViewModel(
            settings: settings,
            toasts: ToastCenter(),
            service: client
        )
        var sendCallbackCount = 0

        viewModel.addToLibrary(
            publication,
            acquisition: acquisition,
            catalogID:
                OPDSBuiltInCatalog.projectGutenberg.stableID,
            library: library,
            onSuccessfulImport: { _ in
                sendCallbackCount += 1
            }
        )

        let deadline = Date.now.addingTimeInterval(2)
        while viewModel.isDownloading(
            publication,
            catalogID:
                OPDSBuiltInCatalog.projectGutenberg.stableID
        ), Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(sendCallbackCount == 0)
        #expect(testLibrary.context.allBooks().isEmpty)
        #expect(library.preparedImportBatch == nil)
    }

    @Test func `Cancelled search cannot publish obsolete results`() async throws {
        let suiteName = "OPDSViewModelCancellation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(
            secretStore: VolatileSecretStore(),
            defaults: defaults
        )
        let oldValue = settings.onlineMetadataEnabled
        settings.onlineMetadataEnabled = true
        defer { settings.onlineMetadataEnabled = oldValue }
        let client = ScenarioOPDSClient()
        let viewModel = OPDSViewModel(
            settings: settings,
            toasts: ToastCenter(),
            service: client
        )

        viewModel.performUnifiedSearch(
            "obsolete",
            ownershipRecords: []
        )
        try await Task.sleep(for: .milliseconds(30))
        viewModel.performUnifiedSearch(
            "current",
            ownershipRecords: []
        )

        let deadline = Date.now.addingTimeInterval(3)
        while viewModel.isSearching, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(!viewModel.isSearching)
        #expect(viewModel.searchQuery == "current")
        #expect(viewModel.searchGroups.map(\.title) == ["Current"])
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

private final class OPDSDiscoveryURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    struct Route: Sendable {
        let status: Int
        let contentType: String
        let body: Data

        init(
            status: Int = 200,
            contentType: String,
            body: Data
        ) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [URL: Route] = [:]
    nonisolated(unsafe) private static var storedRequestCount = 0

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OPDSDiscoveryURLProtocol.self]
        return configuration
    }

    static var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    static func prepare(routes: [URL: Route]) {
        lock.withLock {
            self.routes = routes
            storedRequestCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let route = Self.lock.withLock { () -> Route? in
            Self.storedRequestCount += 1
            return request.url.flatMap { Self.routes[$0] }
        }
        guard let route, let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: route.status,
            httpVersion: nil,
            headerFields: ["Content-Type": route.contentType]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class WikisourceSearchURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String] = []

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WikisourceSearchURLProtocol.self]
        return configuration
    }

    static var requestedHosts: [String] {
        lock.withLock { hosts }
    }

    static func prepare() {
        lock.withLock { hosts = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL)
            )
            return
        }
        Self.lock.withLock {
            Self.hosts.append(url.host ?? "")
        }
        let body = Data(#"""
        {
          "query": {
            "pages": [{
              "pageid": 4185790,
              "ns": 0,
              "title": "Pride and Prejudice",
              "index": 1,
              "fullurl": "https://en.wikisource.org/wiki/Pride_and_Prejudice",
              "canonicalurl": "https://en.wikisource.org/wiki/Pride_and_Prejudice",
              "contributors": [
                {"userid": 1, "name": "Ada"},
                {"userid": 2, "name": "Charles"}
              ]
            }]
          }
        }
        """#.utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SlowOPDSDownloadURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var stopped = false
    private var deliveryWorkItem: DispatchWorkItem?

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowOPDSDownloadURLProtocol.self]
        return configuration
    }

    static var didStart: Bool {
        lock.withLock { started }
    }

    static var didStop: Bool {
        lock.withLock { stopped }
    }

    static func prepare() {
        lock.withLock {
            started = false
            stopped = false
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.started = true }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/epub+zip",
                "Content-Length": "65536",
            ]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: Data(repeating: 0x41, count: 1_024)
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(
                self,
                didLoad: Data(repeating: 0x42, count: 64_512)
            )
            self.client?.urlProtocolDidFinishLoading(self)
        }
        deliveryWorkItem = workItem
        DispatchQueue.global().asyncAfter(
            deadline: .now() + 1,
            execute: workItem
        )
    }

    override func stopLoading() {
        deliveryWorkItem?.cancel()
        Self.lock.withLock { Self.stopped = true }
    }
}
