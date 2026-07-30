import Foundation

nonisolated enum HardcoverAPIError: Error, Equatable, Sendable {
    case missingCredential
    case unauthorized(statusCode: Int)
    case server(statusCode: Int)
    case http(statusCode: Int)
    case invalidResponse
}

actor HardcoverAPIClient {
    nonisolated static let shared = HardcoverAPIClient()
    nonisolated static let endpoint = URL(string: "https://api.hardcover.app/v1/graphql")!
    nonisolated static let minimumRequestInterval: TimeInterval = 0.34

    private struct GraphQLBody<Variables: Encodable>: Encodable {
        let query: String
        let variables: Variables
    }

    private let endpointURL: URL
    private let session: URLSession
    private let minimumInterval: TimeInterval
    private var nextRequestAt = Date.distantPast

    init(
        session: URLSession? = nil,
        endpoint: URL = HardcoverAPIClient.endpoint,
        minimumRequestInterval: TimeInterval = HardcoverAPIClient.minimumRequestInterval
    ) {
        self.endpointURL = endpoint
        self.session = session ?? Self.makeSession()
        self.minimumInterval = max(0, minimumRequestInterval)
    }

    func post<Variables: Encodable & Sendable>(
        query: String,
        variables: Variables,
        token rawToken: String
    ) async throws -> Data {
        try Task.checkCancellation()
        let authorization = try Self.authorizationHeader(for: rawToken)
        let payload = try JSONEncoder().encode(
            GraphQLBody(query: query, variables: variables)
        )

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = payload

        try await reserveRequestSlot()
        try Task.checkCancellation()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }

        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HardcoverAPIError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200:
            return data
        case 401, 403:
            throw HardcoverAPIError.unauthorized(statusCode: httpResponse.statusCode)
        case 500...599:
            throw HardcoverAPIError.server(statusCode: httpResponse.statusCode)
        default:
            throw HardcoverAPIError.http(statusCode: httpResponse.statusCode)
        }
    }

    nonisolated static func authorizationHeader(for rawToken: String) throws -> String {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HardcoverAPIError.missingCredential }
        if trimmed.caseInsensitiveCompare("Bearer") == .orderedSame {
            throw HardcoverAPIError.missingCredential
        }

        let parts = trimmed.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: \.isWhitespace
        )
        if parts.count == 2,
           String(parts[0]).caseInsensitiveCompare("Bearer") == .orderedSame {
            let token = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw HardcoverAPIError.missingCredential }
            return "Bearer \(token)"
        }
        return "Bearer \(trimmed)"
    }

    private func reserveRequestSlot() async throws {
        let now = Date.now
        let scheduled = max(now, nextRequestAt)
        nextRequestAt = scheduled.addingTimeInterval(minimumInterval)
        let delay = scheduled.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
    }

    nonisolated private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Winston/1.0 (macOS eBook manager)"
        ]
        return URLSession(configuration: configuration)
    }
}
