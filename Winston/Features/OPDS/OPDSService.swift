import Foundation

nonisolated protocol OPDSFetching: Sendable {
    func feed(at url: URL) async throws -> OPDSFeed
    func download(
        _ acquisition: OPDSAcquisition,
        title: String
    ) async throws -> URL
    func feed(
        at url: URL,
        access: OPDSCatalogAccess
    ) async throws -> OPDSFeed
    func resolvedSearchTemplate(
        for link: OPDSSearchLink,
        access: OPDSCatalogAccess
    ) async throws -> String?
    func download(
        _ acquisition: OPDSAcquisition,
        title: String,
        access: OPDSCatalogAccess
    ) async throws -> ImportSource
}

nonisolated extension OPDSFetching {
    func feed(
        at url: URL,
        access: OPDSCatalogAccess
    ) async throws -> OPDSFeed {
        try await feed(at: url)
    }

    func resolvedSearchTemplate(
        for link: OPDSSearchLink,
        access: OPDSCatalogAccess
    ) async throws -> String? {
        guard case .template(let template) = link else { return nil }
        return template
    }

    func download(
        _ acquisition: OPDSAcquisition,
        title: String,
        access: OPDSCatalogAccess
    ) async throws -> ImportSource {
        .external(try await download(acquisition, title: title))
    }
}

nonisolated enum OPDSServiceError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case invalidURL
    case authenticationRequired
    case unsupportedCrossOriginAuthentication
    case insecureTransport
    case insecureRedirect
    case server(Int)
    case network
    case feedTooLarge
    case invalidFeed
    case downloadTooLarge
    case invalidDownload
    case unsupportedSearch

    var description: String {
        switch self {
        case .invalidURL: "Invalid catalog address."
        case .authenticationRequired: "Catalog authentication is required."
        case .unsupportedCrossOriginAuthentication:
            "The linked server requires a separate authentication flow."
        case .insecureTransport: "The insecure catalog connection is not allowed."
        case .insecureRedirect: "A secure catalog tried to redirect to HTTP."
        case .server(let status): "The catalog server returned HTTP \(status)."
        case .network: "The catalog request failed."
        case .feedTooLarge: "The catalog response exceeded the size limit."
        case .invalidFeed: "The response is not a supported catalog."
        case .downloadTooLarge: "The download exceeded the size limit."
        case .invalidDownload: "The downloaded book is invalid."
        case .unsupportedSearch: "The catalog does not expose a supported search."
        }
    }
}

nonisolated struct OPDSCatalogTestResult: Equatable, Sendable {
    let title: String
    let resolvedRootURL: URL
    let discoveredRootURL: URL?
    let documentFormat: OPDSDocumentFormat
    let canBrowse: Bool
    let canSearch: Bool
    let rootEntryCount: Int
    let supportedFormats: [String]
    let usesSecureTransport: Bool
}

nonisolated struct OPDSRequestPolicy: Sendable {
    let access: OPDSCatalogAccess

    func request(
        for url: URL,
        accept: String? = nil
    ) throws -> URLRequest {
        try validateTransport(for: url)
        var request = URLRequest(url: url)
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        applyAuthorization(to: &request)
        return request
    }

    func redirectedRequest(
        from sourceURL: URL,
        proposedRequest: URLRequest
    ) throws -> URLRequest {
        guard let targetURL = proposedRequest.url else {
            throw OPDSServiceError.invalidURL
        }
        if sourceURL.scheme?.lowercased() == "https",
           targetURL.scheme?.lowercased() == "http" {
            throw OPDSServiceError.insecureRedirect
        }
        try validateTransport(for: targetURL)
        var request = proposedRequest
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        applyAuthorization(to: &request)
        return request
    }

    func hasCredentialAccess(to url: URL) -> Bool {
        guard let credentialOrigin = access.credentialOrigin,
              let targetOrigin = OPDSOrigin(url: url) else {
            return false
        }
        return credentialOrigin == targetOrigin
    }

    private func validateTransport(for url: URL) throws {
        guard url.isOPDSHTTPURL else {
            throw OPDSServiceError.invalidURL
        }
        guard url.scheme?.lowercased() == "http" else { return }
        guard access.configuration.allowsInsecureHTTP,
              access.configuration.authenticationMode == .none else {
            throw OPDSServiceError.insecureTransport
        }
    }

    private func applyAuthorization(to request: inout URLRequest) {
        guard let url = request.url,
              hasCredentialAccess(to: url),
              let credential = access.credential else {
            return
        }
        let value = Data(
            "\(credential.username):\(credential.password)".utf8
        ).base64EncodedString()
        request.setValue(
            "Basic \(value)",
            forHTTPHeaderField: "Authorization"
        )
    }
}

actor OPDSService: OPDSFetching {
    nonisolated static let maximumFeedBytes = 8 * 1024 * 1024
    nonisolated static let maximumDownloadBytes: Int64 = 250 * 1024 * 1024

    nonisolated static let feedAccept =
        "application/opds+json, application/atom+xml;profile=opds-catalog;q=0.9, application/atom+xml;q=0.8, application/xml;q=0.7"

    private let session: URLSession
    private let importSourceLeases: ImportSourceLeaseStore

    init(
        session: URLSession? = nil,
        importSourceLeases: ImportSourceLeaseStore = ImportSourceLeaseStore()
    ) {
        self.session = session ?? Self.makeSession()
        self.importSourceLeases = importSourceLeases
    }

    func feed(at url: URL) async throws -> OPDSFeed {
        let configuration = OPDSCatalogConfiguration(
            id: "anonymous",
            name: "Catalog",
            rootURL: url,
            allowsInsecureHTTP: url.scheme?.lowercased() == "http"
        )
        return try await feed(
            at: url,
            access: OPDSCatalogAccess(
                configuration: configuration,
                credential: nil
            )
        )
    }

    func feed(
        at url: URL,
        access: OPDSCatalogAccess
    ) async throws -> OPDSFeed {
        if access.configuration.builtIn == .wikisource {
            if WikisourceCatalogAdapter.isRootRequest(
                url,
                access: access
            ) {
                do {
                    return try WikisourceCatalogAdapter.rootFeed(
                        for: access.configuration
                    )
                } catch {
                    throw OPDSServiceError.invalidFeed
                }
            }
            let policy = OPDSRequestPolicy(access: access)
            let request = try policy.request(
                for: url,
                accept: "application/json"
            )
            let (data, response) = try await boundedData(
                for: request,
                policy: policy
            )
            do {
                return try WikisourceCatalogAdapter.parseSearchFeed(
                    data,
                    responseURL: response.url ?? url,
                    configuration: access.configuration
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw OPDSServiceError.invalidFeed
            }
        }
        let policy = OPDSRequestPolicy(access: access)
        let request = try policy.request(
            for: url,
            accept: Self.feedAccept
        )
        let (data, http) = try await boundedData(
            for: request,
            policy: policy
        )
        do {
            return try OPDSParser.parse(
                data,
                baseURL: http.url ?? url,
                contentType: http.value(
                    forHTTPHeaderField: "Content-Type"
                )
            ).providingSearchLink(
                access.configuration.builtInSearchLink
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OPDSServiceError.invalidFeed
        }
    }

    func resolvedSearchTemplate(
        for link: OPDSSearchLink,
        access: OPDSCatalogAccess
    ) async throws -> String? {
        switch link {
        case .template(let template):
            return template
        case .openSearchDescription(let url):
            let policy = OPDSRequestPolicy(access: access)
            let request = try policy.request(
                for: url,
                accept: "application/opensearchdescription+xml, application/xml;q=0.9"
            )
            let (data, response) = try await boundedData(
                for: request,
                policy: policy
            )
            do {
                return try OPDSParser.parseOpenSearch(
                    data,
                    baseURL: response.url ?? url
                )
            } catch {
                throw OPDSServiceError.unsupportedSearch
            }
        }
    }

    func testCatalog(
        access: OPDSCatalogAccess
    ) async throws -> OPDSCatalogTestResult {
        if access.configuration.builtIn == .wikisource {
            return try await testWikisourceCatalog(access: access)
        }
        let enteredURL = access.configuration.rootURL
        let policy = OPDSRequestPolicy(access: access)
        let request = try policy.request(
            for: enteredURL,
            accept: Self.feedAccept
        )
        let (data, response) = try await boundedData(
            for: request,
            policy: policy
        )
        let effectiveURL = response.url ?? enteredURL
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        let feed: OPDSFeed
        let discoveredURL: URL?
        do {
            feed = try OPDSParser.parse(
                data,
                baseURL: effectiveURL,
                contentType: contentType
            )
            discoveredURL = effectiveURL == enteredURL ? nil : effectiveURL
        } catch {
            guard let candidate = Self.discoveredCatalogURL(
                data: data,
                response: response,
                baseURL: effectiveURL
            ) else {
                throw OPDSServiceError.invalidFeed
            }
            if enteredURL.scheme?.lowercased() == "https",
               candidate.scheme?.lowercased() == "http" {
                throw OPDSServiceError.insecureRedirect
            }
            feed = try await self.feed(at: candidate, access: access)
            discoveredURL = candidate
        }

        var formats: Set<String> = []
        for acquisition in feed.publications.flatMap(\.acquisitions)
        where acquisition.isSupportedFormat {
            formats.insert(acquisition.formatLabel)
        }
        return OPDSCatalogTestResult(
            title: feed.title,
            resolvedRootURL: discoveredURL ?? effectiveURL,
            discoveredRootURL: discoveredURL,
            documentFormat: feed.documentFormat,
            canBrowse: !feed.isEmpty,
            canSearch: feed.searchLink != nil,
            rootEntryCount: feed.navigation.count + feed.publications.count,
            supportedFormats: formats.sorted(),
            usesSecureTransport:
                (discoveredURL ?? effectiveURL).scheme?.lowercased() == "https"
        )
    }

    private func testWikisourceCatalog(
        access: OPDSCatalogAccess
    ) async throws -> OPDSCatalogTestResult {
        let rootURL = access.configuration.rootURL
        guard let url = WikisourceCatalogAdapter.siteInfoURL(
            rootURL: rootURL
        ) else {
            throw OPDSServiceError.invalidURL
        }
        let policy = OPDSRequestPolicy(access: access)
        let request = try policy.request(
            for: url,
            accept: "application/json"
        )
        let (data, _) = try await boundedData(
            for: request,
            policy: policy
        )
        let title: String
        do {
            title = try WikisourceCatalogAdapter.siteTitle(from: data)
        } catch {
            throw OPDSServiceError.invalidFeed
        }
        return OPDSCatalogTestResult(
            title: title,
            resolvedRootURL: rootURL,
            discoveredRootURL: nil,
            documentFormat: .mediaWiki,
            canBrowse: false,
            canSearch: true,
            rootEntryCount: 0,
            supportedFormats: ["EPUB"],
            usesSecureTransport: true
        )
    }

    func download(
        _ acquisition: OPDSAcquisition,
        title: String
    ) async throws -> URL {
        let configuration = OPDSCatalogConfiguration(
            id: "anonymous",
            name: "Catalog",
            rootURL: acquisition.url,
            allowsInsecureHTTP:
                acquisition.url.scheme?.lowercased() == "http"
        )
        let source = try await download(
            acquisition,
            title: title,
            access: OPDSCatalogAccess(
                configuration: configuration,
                credential: nil
            )
        )
        return source.url
    }

    func download(
        _ acquisition: OPDSAcquisition,
        title: String,
        access: OPDSCatalogAccess
    ) async throws -> ImportSource {
        guard acquisition.canImport else {
            throw OPDSServiceError.invalidDownload
        }
        let policy = OPDSRequestPolicy(access: access)
        var request = try policy.request(for: acquisition.url)
        if !acquisition.mediaType.isEmpty {
            request.setValue(
                acquisition.mediaType,
                forHTTPHeaderField: "Accept"
            )
        }
        let redirectDelegate = OPDSRedirectDelegate(policy: policy)

        let sourceURL: URL
        let response: URLResponse
        do {
            (sourceURL, response) = try await session.download(
                for: request,
                delegate: redirectDelegate
            )
            if let error = redirectDelegate.rejection {
                throw error
            }
        } catch let error as OPDSServiceError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let rejection = redirectDelegate.rejection {
                throw rejection
            }
            throw OPDSServiceError.network
        }
        _ = try validate(response, policy: policy)

        let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values?.fileSize ?? 0)
        guard size > 0 else { throw OPDSServiceError.invalidDownload }
        guard size <= Self.maximumDownloadBytes else {
            throw OPDSServiceError.downloadTooLarge
        }

        let fileName = "\(Self.safeFileStem(title)).\(acquisition.fileExtension)"
        guard let leaf = ManagedLeafName(rawValue: fileName) else {
            throw OPDSServiceError.invalidDownload
        }
        var lease: WinstonImportSourceLease?
        do {
            let createdLease = try importSourceLeases.create(
                fileName: leaf,
                purpose: .catalogDownload
            )
            lease = createdLease
            try FileManager.default.moveItem(
                at: sourceURL,
                to: createdLease.fileURL
            )
        } catch {
            if let lease {
                try? importSourceLeases.remove(lease)
            }
            throw OPDSServiceError.invalidDownload
        }
        guard let lease else {
            throw OPDSServiceError.invalidDownload
        }
        if Task.isCancelled {
            try? importSourceLeases.remove(lease)
            throw CancellationError()
        }
        return .winstonOwned(lease)
    }

    private func boundedData(
        for request: URLRequest,
        policy: OPDSRequestPolicy
    ) async throws -> (Data, HTTPURLResponse) {
        let redirectDelegate = OPDSRedirectDelegate(policy: policy)
        do {
            let (bytes, response) = try await session.bytes(
                for: request,
                delegate: redirectDelegate
            )
            if let error = redirectDelegate.rejection {
                throw error
            }
            let http = try validate(response, policy: policy)
            let expected = response.expectedContentLength
            guard expected <= 0
                    || expected <= Int64(Self.maximumFeedBytes) else {
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
            if let rejection = redirectDelegate.rejection {
                throw rejection
            }
            throw OPDSServiceError.network
        }
    }

    private func validate(
        _ response: URLResponse,
        policy: OPDSRequestPolicy
    ) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse,
              let responseURL = response.url,
              responseURL.isOPDSHTTPURL else {
            throw OPDSServiceError.network
        }
        switch response.statusCode {
        case 200..<300:
            return response
        case 401, 403:
            if policy.access.credential != nil,
               !policy.hasCredentialAccess(to: responseURL) {
                throw OPDSServiceError
                    .unsupportedCrossOriginAuthentication
            }
            throw OPDSServiceError.authenticationRequired
        default:
            throw OPDSServiceError.server(response.statusCode)
        }
    }

    nonisolated static func expandedSearchURL(
        template: String,
        query: String
    ) -> URL? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?/#")
        guard let encoded = query.addingPercentEncoding(
            withAllowedCharacters: allowed
        ) else {
            return nil
        }

        var value = template
        let supportedTokens = [
            "{searchTerms}", "{searchTerms?}", "{query}", "{query?}",
        ]
        if let token = supportedTokens.first(where: value.contains) {
            value = value.replacingOccurrences(of: token, with: encoded)
        } else if value.contains("{?query}") {
            value = value.replacingOccurrences(
                of: "{?query}",
                with: "?query=\(encoded)"
            )
        } else if value.contains("{?q}") {
            value = value.replacingOccurrences(
                of: "{?q}",
                with: "?q=\(encoded)"
            )
        } else {
            guard var components = URLComponents(string: value) else {
                return nil
            }
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "query", value: query))
            components.queryItems = items
            return components.url?.isOPDSHTTPURL == true
                ? components.url
                : nil
        }
        guard let url = URL(string: value), url.isOPDSHTTPURL else {
            return nil
        }
        return url
    }

    nonisolated private static func discoveredCatalogURL(
        data: Data,
        response: HTTPURLResponse,
        baseURL: URL
    ) -> URL? {
        if let header = response.value(forHTTPHeaderField: "Link") {
            for part in header.split(separator: ",") {
                let value = String(part)
                let lowered = value.lowercased()
                guard lowered.contains("opds")
                        || lowered.contains("atom+xml"),
                      lowered.contains("rel="),
                      lowered.contains("alternate")
                        || lowered.contains("start")
                        || lowered.contains("catalog") else {
                    continue
                }
                guard let open = value.firstIndex(of: "<"),
                      let close = value[open...].firstIndex(of: ">"),
                      let url = URL(
                        string: String(value[value.index(after: open)..<close]),
                        relativeTo: baseURL
                      )?.absoluteURL,
                      url.isOPDSHTTPURL else {
                    continue
                }
                return url
            }
        }

        guard let html = String(data: data, encoding: .utf8),
              let tagExpression = try? NSRegularExpression(
                pattern: "(?is)<link\\b[^>]*>"
              ) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        for match in tagExpression.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else {
                continue
            }
            let tag = String(html[tagRange])
            guard let type = htmlAttribute("type", in: tag)?.lowercased(),
                  type.contains("opds")
                    || type.contains("atom+xml"),
                  let relation = htmlAttribute("rel", in: tag)?
                    .lowercased(),
                  relation.contains("alternate")
                    || relation.contains("start")
                    || relation.contains("catalog"),
                  let href = htmlAttribute("href", in: tag),
                  let url = URL(
                    string: href,
                    relativeTo: baseURL
                  )?.absoluteURL,
                  url.isOPDSHTTPURL else {
                continue
            }
            return url
        }
        return nil
    }

    nonisolated private static func htmlAttribute(
        _ name: String,
        in tag: String
    ) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: "(?i)\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*([\"'])(.*?)\\1"
        ) else {
            return nil
        }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = expression.firstMatch(in: tag, range: range),
              let valueRange = Range(match.range(at: 2), in: tag) else {
            return nil
        }
        return String(tag[valueRange])
    }

    nonisolated private static func safeFileStem(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: " -_")
        )
        let scalars = title.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : " "
        }
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
            "User-Agent":
                "Winston/0.2 (macOS OPDS reader; +https://github.com/)",
        ]
        return URLSession(configuration: configuration)
    }
}

private nonisolated final class OPDSRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let policy: OPDSRequestPolicy
    private let lock = NSLock()
    private var storedRejection: OPDSServiceError?

    init(policy: OPDSRequestPolicy) {
        self.policy = policy
    }

    var rejection: OPDSServiceError? {
        lock.withLock { storedRejection }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        do {
            completionHandler(try policy.redirectedRequest(
                from: response.url ?? task.currentRequest?.url
                    ?? policy.access.configuration.rootURL,
                proposedRequest: request
            ))
        } catch let error as OPDSServiceError {
            lock.withLock { storedRejection = error }
            completionHandler(nil)
        } catch {
            lock.withLock {
                storedRejection = .network
            }
            completionHandler(nil)
        }
    }
}
