import Foundation

/// Bridges the one localized Wikisource built-in into Catalog Hub's existing
/// feed/search/acquisition flow without turning MediaWiki into a general
/// catalog provider abstraction.
nonisolated enum WikisourceCatalogAdapter {
    private struct SearchResponse: Decodable {
        struct Continuation: Decodable {
            let gsroffset: Int?
        }

        struct Query: Decodable {
            let pages: [Page]
        }

        struct Page: Decodable {
            struct Contributor: Decodable {
                let name: String
            }

            let pageid: Int
            let title: String
            let index: Int?
            let fullurl: URL?
            let canonicalurl: URL?
            let contributors: [Contributor]?
        }

        let `continue`: Continuation?
        let query: Query?
    }

    private struct SiteInfoResponse: Decodable {
        struct Query: Decodable {
            struct General: Decodable {
                let sitename: String
            }

            let general: General
        }

        let query: Query
    }

    enum ParseError: Error {
        case invalidResponse
    }

    static func isRootRequest(
        _ url: URL,
        access: OPDSCatalogAccess
    ) -> Bool {
        url == access.configuration.rootURL
    }

    static func rootFeed(
        for configuration: OPDSCatalogConfiguration
    ) throws -> OPDSFeed {
        guard let template = searchTemplate(
            rootURL: configuration.rootURL
        ) else {
            throw ParseError.invalidResponse
        }
        return OPDSFeed(
            title: configuration.name,
            subtitle: "MediaWiki · \(languageCode(for: configuration.rootURL).uppercased())",
            navigation: [],
            publications: [],
            nextURL: nil,
            searchLink: .template(template),
            documentFormat: .mediaWiki
        )
    }

    static func parseSearchFeed(
        _ data: Data,
        responseURL: URL,
        configuration: OPDSCatalogConfiguration
    ) throws -> OPDSFeed {
        let response = try JSONDecoder().decode(
            SearchResponse.self,
            from: data
        )
        guard let pages = response.query?.pages else {
            throw ParseError.invalidResponse
        }
        let language = languageCode(for: configuration.rootURL)
        let publications = pages
            .sorted {
                ($0.index ?? Int.max, $0.pageid)
                    < ($1.index ?? Int.max, $1.pageid)
            }
            .compactMap { page in
                publication(from: page, language: language)
            }
        return OPDSFeed(
            title: configuration.name,
            subtitle: nil,
            navigation: [],
            publications: publications,
            nextURL: response.continue?.gsroffset.flatMap {
                nextSearchURL(from: responseURL, offset: $0)
            },
            searchLink: nil,
            documentFormat: .mediaWiki
        )
    }

    static func siteInfoURL(rootURL: URL) -> URL? {
        guard var components = URLComponents(
            url: rootURL,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "meta", value: "siteinfo"),
            URLQueryItem(name: "siprop", value: "general"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ]
        return components.url
    }

    static func siteTitle(from data: Data) throws -> String {
        try JSONDecoder().decode(
            SiteInfoResponse.self,
            from: data
        ).query.general.sitename
    }

    private static func searchTemplate(rootURL: URL) -> String? {
        guard var components = URLComponents(
            url: rootURL,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: "{searchTerms}"),
            URLQueryItem(name: "gsrnamespace", value: "0"),
            URLQueryItem(name: "gsrlimit", value: "20"),
            URLQueryItem(name: "prop", value: "info|contributors"),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "pclimit", value: "50"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ]
        return components.url?.absoluteString
            .replacingOccurrences(
                of: "%7BsearchTerms%7D",
                with: "{searchTerms}"
            )
    }

    private static func publication(
        from page: SearchResponse.Page,
        language: String
    ) -> OPDSPublication? {
        guard let exportURL = exportURL(
            title: page.title,
            language: language
        ),
        let acquisition = OPDSAcquisition.make(
            url: exportURL,
            mediaType: "application/epub+zip",
            title: "EPUB",
            relations: [
                "http://opds-spec.org/acquisition/open-access",
            ]
        ) else {
            return nil
        }
        let sourceURL = page.canonicalurl ?? page.fullurl
        return OPDSPublication(
            id: "wikisource:\(language):\(page.pageid)",
            identifiers: ["wikisource:\(language):\(page.pageid)"],
            title: page.title,
            authors: [],
            summary: nil,
            language: language,
            sourceURL: sourceURL,
            attribution: "Wikisource",
            contributors: unique(
                page.contributors?.map(\.name) ?? []
            ),
            coverURL: nil,
            acquisitions: [acquisition]
        )
    }

    private static func exportURL(
        title: String,
        language: String
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "ws-export.wmcloud.org"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "lang", value: language),
            URLQueryItem(name: "format", value: "epub"),
            URLQueryItem(name: "page", value: title),
            URLQueryItem(name: "credits", value: "true"),
        ]
        return components.url
    }

    private static func nextSearchURL(
        from url: URL,
        offset: Int
    ) -> URL? {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "gsroffset" }
        queryItems.append(URLQueryItem(
            name: "gsroffset",
            value: String(offset)
        ))
        components.queryItems = queryItems
        return components.url
    }

    private static func languageCode(for rootURL: URL) -> String {
        let candidate = rootURL.host?.split(separator: ".").first
            .map(String.init)?.lowercased()
        return candidate == "cs" ? "cs" : "en"
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
