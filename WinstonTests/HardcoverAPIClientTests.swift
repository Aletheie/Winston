import Foundation
import Testing
@testable import Winston

@Suite(.serialized)
struct HardcoverAPIClientTests {
    @Test func tokenAndBearerNormalizationIsCanonical() throws {
        #expect(
            try HardcoverAPIClient.authorizationHeader(for: "  token-value \n")
                == "Bearer token-value"
        )
        #expect(
            try HardcoverAPIClient.authorizationHeader(for: "Bearer token-value")
                == "Bearer token-value"
        )
        #expect(
            try HardcoverAPIClient.authorizationHeader(for: " bearer   token-value ")
                == "Bearer token-value"
        )

        for missing in ["", " \n ", "Bearer", " bearer "] {
            do {
                _ = try HardcoverAPIClient.authorizationHeader(for: missing)
                Issue.record("Expected an empty credential to be rejected")
            } catch let error as HardcoverAPIError {
                #expect(error == .missingCredential)
            }
        }
    }

    @Test func postOwnsGraphQLEncodingAndAuthorizationHeaders() async throws {
        HardcoverClientURLProtocol.prepare()
        let client = makeClient()

        _ = try await client.post(
            query: "query Example($id: Int!) { books_by_pk(id: $id) { id } }",
            variables: ["id": 42],
            token: " bearer secret-value "
        )

        let request = try #require(HardcoverClientURLProtocol.requests.first)
        #expect(request.url == HardcoverAPIClient.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-value")

        let body = try #require(HardcoverClientURLProtocol.requestBodies.first)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["query"] as? String == "query Example($id: Int!) { books_by_pk(id: $id) { id } }")
        #expect((object["variables"] as? [String: Int])?["id"] == 42)
    }

    @Test func httpAuthAndServerFailuresAreClassified() async {
        let cases: [(Int, HardcoverAPIError)] = [
            (401, .unauthorized(statusCode: 401)),
            (403, .unauthorized(statusCode: 403)),
            (429, .http(statusCode: 429)),
            (503, .server(statusCode: 503)),
        ]

        for (statusCode, expected) in cases {
            HardcoverClientURLProtocol.prepare(statusCode: statusCode)
            let client = makeClient()
            do {
                _ = try await client.post(
                    query: "query { books { id } }",
                    variables: [String: String](),
                    token: "secret-value"
                )
                Issue.record("Expected HTTP \(statusCode) to fail")
            } catch let error as HardcoverAPIError {
                #expect(error == expected)
            } catch {
                Issue.record("Unexpected error type for HTTP \(statusCode): \(error)")
            }
        }
    }

    @Test func cancellationWhileWaitingForTheSharedSlotSkipsTheRequest() async throws {
        HardcoverClientURLProtocol.prepare()
        let client = makeClient(minimumRequestInterval: 5)
        _ = try await client.post(
            query: "query First { books { id } }",
            variables: [String: String](),
            token: "secret-value"
        )

        let waiting = Task {
            try await client.post(
                query: "query Second { books { id } }",
                variables: [String: String](),
                token: "secret-value"
            )
        }
        try await Task.sleep(for: .milliseconds(40))
        waiting.cancel()

        do {
            _ = try await waiting.value
            Issue.record("Expected the waiting request to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
        #expect(HardcoverClientURLProtocol.requests.count == 1)
    }

    @Test func oneClientSharesCadenceAcrossConcurrentCallers() async throws {
        HardcoverClientURLProtocol.prepare()
        let minimumInterval: TimeInterval = 0.08
        let client = makeClient(minimumRequestInterval: minimumInterval)

        async let first = client.post(
            query: "query First { books { id } }",
            variables: ["caller": "discovery"],
            token: "secret-value"
        )
        async let second = client.post(
            query: "query Second { series { id } }",
            variables: ["caller": "series"],
            token: "secret-value"
        )
        _ = try await (first, second)

        let requestDates = HardcoverClientURLProtocol.requestDates.sorted()
        #expect(requestDates.count == 2)
        let firstDate = try #require(requestDates.first)
        let lastDate = try #require(requestDates.last)
        let spacing = lastDate.timeIntervalSince(firstDate)
        #expect(spacing >= minimumInterval - 0.015)
    }

    private func makeClient(
        minimumRequestInterval: TimeInterval = 0
    ) -> HardcoverAPIClient {
        HardcoverAPIClient(
            session: URLSession(configuration: HardcoverClientURLProtocol.configuration),
            minimumRequestInterval: minimumRequestInterval
        )
    }
}

private final class HardcoverClientURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var storedRequestBodies: [Data] = []
    nonisolated(unsafe) private static var storedRequestDates: [Date] = []
    nonisolated(unsafe) private static var storedStatusCode = 200

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HardcoverClientURLProtocol.self]
        return configuration
    }

    static var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    static var requestDates: [Date] {
        lock.withLock { storedRequestDates }
    }

    static var requestBodies: [Data] {
        lock.withLock { storedRequestBodies }
    }

    static func prepare(statusCode: Int = 200) {
        lock.withLock {
            storedRequests = []
            storedRequestBodies = []
            storedRequestDates = []
            storedStatusCode = statusCode
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? Self.readBody(from: request.httpBodyStream)
        let statusCode = Self.lock.withLock { () -> Int in
            Self.storedRequests.append(request)
            Self.storedRequestBodies.append(body)
            Self.storedRequestDates.append(.now)
            return Self.storedStatusCode
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":{}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
}
