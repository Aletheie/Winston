import Foundation
import Testing
@testable import Winston

@Suite("Online metadata cache", .serialized)
struct OnlineMetadataServiceTests {
    @Test func concurrentEquivalentLookupsShareOneProviderRequestChain() async {
        OnlineMetadataURLProtocol.prepare(responseDelay: 0.08)
        let service = makeService()

        await withTaskGroup(of: OnlineMetadataFetchResult.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await service.fetch(
                        isbn: nil,
                        title: "Dune",
                        author: "Frank Herbert",
                        language: .english,
                        hardcoverToken: nil
                    )
                }
            }
            for await result in group {
                #expect(result.metadata?.title == "Dune")
            }
        }

        #expect(OnlineMetadataURLProtocol.requestCount == 2)
        _ = await service.fetch(
            isbn: nil,
            title: "  DUNE ",
            author: "frank-herbert",
            language: .english,
            hardcoverToken: nil
        )
        #expect(OnlineMetadataURLProtocol.requestCount == 2)

        let diagnostics = await service.cacheDiagnostics()
        #expect(diagnostics.metadataRequestCount == 1)
        #expect(diagnostics.coalescedMetadataRequestCount == 7)
        #expect(diagnostics.cacheHitCount == 1)
        #expect(diagnostics.cacheEntryCount == 1)
        #expect(diagnostics.metadataInFlightCount == 0)
    }

    @Test func cacheUsesLRUEvictionAndStaysWithinCapacity() async {
        OnlineMetadataURLProtocol.prepare()
        let service = makeService(cacheCapacity: 2)

        _ = await fetch("Alpha", from: service)
        _ = await fetch("Beta", from: service)
        _ = await fetch("Alpha", from: service)
        _ = await fetch("Gamma", from: service)
        #expect(OnlineMetadataURLProtocol.requestCount == 6)

        _ = await fetch("Alpha", from: service)
        #expect(OnlineMetadataURLProtocol.requestCount == 6)
        _ = await fetch("Beta", from: service)
        #expect(OnlineMetadataURLProtocol.requestCount == 8)

        let diagnostics = await service.cacheDiagnostics()
        #expect(diagnostics.cacheEntryCount == 2)
        #expect(diagnostics.evictionCount == 2)
    }

    @Test func expiredEntryIsRefetched() async {
        OnlineMetadataURLProtocol.prepare()
        let clock = LockedMetadataClock()
        let service = makeService(cacheTTL: 60, now: { clock.now })

        _ = await fetch("Dune", from: service)
        #expect(OnlineMetadataURLProtocol.requestCount == 2)
        clock.advance(by: 61)
        _ = await fetch("Dune", from: service)
        #expect(OnlineMetadataURLProtocol.requestCount == 4)

        let diagnostics = await service.cacheDiagnostics()
        #expect(diagnostics.expirationCount == 1)
        #expect(diagnostics.cacheEntryCount == 1)
    }

    @Test func derivedCacheCanBeResetAndRebuilt() async {
        OnlineMetadataURLProtocol.prepare()
        let service = makeService()

        _ = await fetch("Dune", from: service)
        #expect(OnlineMetadataURLProtocol.requestCount == 2)
        await service.resetCache()
        #expect(await service.cacheDiagnostics().cacheEntryCount == 0)

        _ = await fetch("Dune", from: service)
        #expect(OnlineMetadataURLProtocol.requestCount == 4)
        #expect(await service.cacheDiagnostics().cacheEntryCount == 1)
    }

    @Test func providerConfigurationSeparatesCacheAndInFlightKeys() async {
        OnlineMetadataURLProtocol.prepare()
        let service = makeService()

        _ = await service.fetch(
            isbn: nil,
            title: "Dune",
            author: "Test Author",
            language: .english,
            hardcoverToken: "secret-a"
        )
        _ = await service.fetch(
            isbn: nil,
            title: "Dune",
            author: "Test Author",
            language: .english,
            hardcoverToken: "secret-b"
        )
        #expect(OnlineMetadataURLProtocol.requestCount == 6)

        _ = await service.fetch(
            isbn: nil,
            title: "Dune",
            author: "Test Author",
            language: .english,
            hardcoverToken: "secret-a"
        )
        #expect(OnlineMetadataURLProtocol.requestCount == 6)

        let diagnostics = await service.cacheDiagnostics()
        #expect(diagnostics.metadataRequestCount == 2)
        #expect(diagnostics.cacheEntryCount == 2)
    }

    @Test func concurrentCoverDownloadsAreCoalescedWithoutRetainingImageData() async {
        OnlineMetadataURLProtocol.prepare(responseDelay: 0.08)
        let service = makeService()
        let url = URL(string: "https://images.example.test/cover.jpg")!

        await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<8 {
                group.addTask { await service.downloadCover(url) }
            }
            for await data in group {
                #expect(data?.count == 1_500)
            }
        }

        #expect(OnlineMetadataURLProtocol.requestCount == 1)
        let diagnostics = await service.cacheDiagnostics()
        #expect(diagnostics.coverDownloadCount == 1)
        #expect(diagnostics.coalescedCoverDownloadCount == 7)
        #expect(diagnostics.coverInFlightCount == 0)
        #expect(diagnostics.cacheEntryCount == 0)
    }

    private func makeService(
        cacheCapacity: Int = 32,
        cacheTTL: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { .now }
    ) -> OnlineMetadataService {
        OnlineMetadataService(
            session: URLSession(configuration: OnlineMetadataURLProtocol.configuration),
            cacheCapacity: cacheCapacity,
            cacheTTL: cacheTTL,
            minInterval: 0,
            now: now
        )
    }

    private func fetch(
        _ title: String,
        from service: OnlineMetadataService
    ) async -> OnlineMetadataFetchResult {
        await service.fetch(
            isbn: nil,
            title: title,
            author: "Test Author",
            language: .english,
            hardcoverToken: nil
        )
    }
}

private final class LockedMetadataClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)

    var now: Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private final class OnlineMetadataURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedRequestCount = 0
    nonisolated(unsafe) private static var responseDelay: TimeInterval = 0

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnlineMetadataURLProtocol.self]
        return configuration
    }

    static var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    static func prepare(responseDelay: TimeInterval = 0) {
        lock.withLock {
            storedRequestCount = 0
            self.responseDelay = responseDelay
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let delay = Self.lock.withLock { () -> TimeInterval in
            Self.storedRequestCount += 1
            return Self.responseDelay
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let body: Data
        if request.url?.host == "images.example.test" {
            body = Data(repeating: 0xA5, count: 1_500)
        } else if request.url?.host == "openlibrary.org" {
            body = openLibraryResponse()
        } else {
            body = googleBooksResponse()
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestedTitle() -> String {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return "Unknown" }
        if let title = components.queryItems?.first(where: { $0.name == "title" })?.value {
            return title
        }
        let query = components.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
        if query.hasPrefix("intitle:") {
            return String(query.dropFirst("intitle:".count).split(separator: "+").first ?? "Unknown")
        }
        return "Unknown"
    }

    private func openLibraryResponse() -> Data {
        let object: [String: Any] = [
            "docs": [[
                "key": "/works/OL1W",
                "title": requestedTitle(),
                "author_name": ["Test Author"],
                "first_publish_year": 1965,
                "publisher": ["Test Publisher"],
                "cover_i": 42,
                "subject": ["Fiction"],
                "ratings_average": 4.5,
                "ratings_count": 10,
            ]],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func googleBooksResponse() -> Data {
        let object: [String: Any] = [
            "items": [[
                "volumeInfo": [
                    "title": requestedTitle(),
                    "authors": ["Test Author"],
                    "description": "Description",
                    "averageRating": 4.5,
                    "ratingsCount": 10,
                ],
            ]],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }
}
