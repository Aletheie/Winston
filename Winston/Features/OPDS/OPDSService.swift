import Foundation

nonisolated protocol OPDSFetching: Sendable {
    func feed(at url: URL) async throws -> OPDSFeed
    func download(_ acquisition: OPDSAcquisition, title: String) async throws -> URL
}

nonisolated enum OPDSServiceError: Error, Equatable, Sendable {
    case invalidURL
    case authenticationRequired
    case server(Int)
    case network
    case feedTooLarge
    case invalidFeed
    case downloadTooLarge
    case invalidDownload
}

actor OPDSService: OPDSFetching {
    nonisolated static let maximumFeedBytes = 8 * 1024 * 1024
    nonisolated static let maximumDownloadBytes: Int64 = 250 * 1024 * 1024

    private let session: URLSession
    private let temporaryDirectory: URL

    init(session: URLSession? = nil, temporaryDirectory: URL? = nil) {
        self.session = session ?? Self.makeSession()
        self.temporaryDirectory = temporaryDirectory ?? FileManager.default.temporaryDirectory
    }

    func feed(at url: URL) async throws -> OPDSFeed {
        guard url.isOPDSHTTPURL else { throw OPDSServiceError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(
            "application/opds+json, application/atom+xml;profile=opds-catalog;q=0.9, application/atom+xml;q=0.8, application/xml;q=0.7",
            forHTTPHeaderField: "Accept"
        )

        let (data, http) = try await boundedFeedData(for: request)
        do {
            return try OPDSParser.parse(
                data,
                baseURL: http.url ?? url,
                contentType: http.value(forHTTPHeaderField: "Content-Type")
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OPDSServiceError.invalidFeed
        }
    }

    private func boundedFeedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let http = try validate(response)
            let expected = response.expectedContentLength
            guard expected <= 0 || expected <= Int64(Self.maximumFeedBytes) else {
                throw OPDSServiceError.feedTooLarge
            }

            var data = Data()
            if expected > 0 {
                data.reserveCapacity(Int(expected))
            }
            for try await byte in bytes {
                guard data.count < Self.maximumFeedBytes else {
                    throw OPDSServiceError.feedTooLarge
                }
                data.append(byte)
                if data.count.isMultiple(of: 16 * 1_024) {
                    try Task.checkCancellation()
                }
            }
            return (data, http)
        } catch let error as OPDSServiceError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OPDSServiceError.network
        }
    }

    func download(_ acquisition: OPDSAcquisition, title: String) async throws -> URL {
        guard acquisition.url.isOPDSHTTPURL else { throw OPDSServiceError.invalidURL }
        var request = URLRequest(url: acquisition.url)
        if !acquisition.mediaType.isEmpty {
            request.setValue(acquisition.mediaType, forHTTPHeaderField: "Accept")
        }

        let sourceURL: URL
        let response: URLResponse
        do {
            (sourceURL, response) = try await session.download(for: request)
        } catch {
            if error is CancellationError { throw error }
            throw OPDSServiceError.network
        }
        _ = try validate(response)

        let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values?.fileSize ?? 0)
        guard size > 0 else { throw OPDSServiceError.invalidDownload }
        guard size <= Self.maximumDownloadBytes else { throw OPDSServiceError.downloadTooLarge }

        let folder = temporaryDirectory.appending(
            path: "Winston-OPDS-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appending(
                path: "\(Self.safeFileStem(title)).\(acquisition.fileExtension)"
            )
            try FileManager.default.moveItem(at: sourceURL, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw OPDSServiceError.invalidDownload
        }
    }

    private func validate(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse,
              response.url?.isOPDSHTTPURL == true else {
            throw OPDSServiceError.network
        }
        switch response.statusCode {
        case 200..<300:
            return response
        case 401, 403:
            throw OPDSServiceError.authenticationRequired
        default:
            throw OPDSServiceError.server(response.statusCode)
        }
    }

    nonisolated static func expandedSearchURL(template: String, query: String) -> URL? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?/#")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }

        var value = template
        if value.contains("{searchTerms}") {
            value = value.replacingOccurrences(of: "{searchTerms}", with: encoded)
        } else if value.contains("{?query}") {
            value = value.replacingOccurrences(of: "{?query}", with: "?query=\(encoded)")
        } else if value.contains("{query}") {
            value = value.replacingOccurrences(of: "{query}", with: encoded)
        } else {
            guard var components = URLComponents(string: value) else { return nil }
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "query", value: query))
            components.queryItems = items
            return components.url?.isOPDSHTTPURL == true ? components.url : nil
        }
        guard let url = URL(string: value), url.isOPDSHTTPURL else { return nil }
        return url
    }

    nonisolated private static func safeFileStem(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let scalars = title.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        let compact = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(compact.prefix(120)).opdsNonEmpty ?? "Book"
    }

    nonisolated private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 180
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Winston/0.2 (macOS OPDS reader; +https://github.com/)"
        ]
        return URLSession(configuration: configuration)
    }
}
