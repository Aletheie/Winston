import Foundation

nonisolated struct OPDSCatalog: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case projectGutenberg
        case standardEbooks
    }

    let kind: Kind
    let name: String
    let rootURL: URL
    let searchTemplate: String?

    var id: Kind { kind }

    static let builtIn: [OPDSCatalog] = [
        OPDSCatalog(
            kind: .projectGutenberg,
            name: "Project Gutenberg",
            rootURL: URL(string: "https://www.gutenberg.org/ebooks.opds/")!,
            searchTemplate: "https://www.gutenberg.org/ebooks/search.opds/?query={searchTerms}"
        ),
        OPDSCatalog(
            kind: .standardEbooks,
            name: "Standard Ebooks",
            rootURL: URL(string: "https://standardebooks.org/feeds/opds")!,
            searchTemplate: nil
        ),
    ]

    var rootShortcuts: [OPDSNavigationItem] {
        guard kind == .projectGutenberg else { return [] }
        return [
            OPDSNavigationItem(
                title: String(localized: "Czech books"),
                subtitle: String(localized: "Project Gutenberg books in Czech"),
                url: URL(string: "https://www.gutenberg.org/ebooks/search.opds/?query=l.cs")!,
                coverURL: nil
            ),
            OPDSNavigationItem(
                title: String(localized: "All books"),
                subtitle: String(localized: "Browse the complete Project Gutenberg catalog"),
                url: URL(string: "https://www.gutenberg.org/ebooks/search.opds/")!,
                coverURL: nil
            ),
        ]
    }
}

nonisolated struct OPDSFeed: Equatable, Sendable {
    let title: String
    let subtitle: String?
    let navigation: [OPDSNavigationItem]
    let publications: [OPDSPublication]
    let nextURL: URL?
    let searchTemplate: String?

    var isEmpty: Bool { navigation.isEmpty && publications.isEmpty }

    func prependingNavigation(_ items: [OPDSNavigationItem]) -> OPDSFeed {
        guard !items.isEmpty else { return self }
        var seen = Set(items.map(\.id))
        let remaining = navigation.filter { seen.insert($0.id).inserted }
        return OPDSFeed(
            title: title,
            subtitle: subtitle,
            navigation: items + remaining,
            publications: publications,
            nextURL: nextURL,
            searchTemplate: searchTemplate
        )
    }

    func appending(_ page: OPDSFeed) -> OPDSFeed {
        var navigationIDs = Set(navigation.map(\.id))
        let newNavigation = page.navigation.filter { navigationIDs.insert($0.id).inserted }
        var publicationIDs = Set(publications.map(\.id))
        let newPublications = page.publications.filter { publicationIDs.insert($0.id).inserted }
        return OPDSFeed(
            title: title,
            subtitle: subtitle ?? page.subtitle,
            navigation: navigation + newNavigation,
            publications: publications + newPublications,
            nextURL: page.nextURL,
            searchTemplate: searchTemplate ?? page.searchTemplate
        )
    }
}

nonisolated struct OPDSNavigationItem: Identifiable, Hashable, Sendable {
    let title: String
    let subtitle: String?
    let url: URL
    let coverURL: URL?

    var id: String { url.absoluteString }
}

nonisolated struct OPDSPublication: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let authors: [String]
    let summary: String?
    let language: String?
    let coverURL: URL?
    let acquisitions: [OPDSAcquisition]

    var authorLine: String? {
        let value = authors.joined(separator: ", ").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var preferredAcquisition: OPDSAcquisition? {
        acquisitions.min { lhs, rhs in
            if lhs.preferenceRank != rhs.preferenceRank {
                return lhs.preferenceRank < rhs.preferenceRank
            }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }
    }
}

nonisolated struct OPDSAcquisition: Identifiable, Hashable, Sendable {
    let url: URL
    let mediaType: String
    let title: String?
    let fileExtension: String

    var id: String { "\(url.absoluteString)|\(mediaType)" }
    var formatLabel: String { fileExtension.uppercased() }

    fileprivate var preferenceRank: Int {
        switch fileExtension {
        case "epub": 0
        case "mobi", "azw", "azw3": 1
        case "pdf": 2
        case "txt": 3
        case "html", "htm": 4
        default: 10
        }
    }

    static func make(
        url: URL,
        mediaType rawMediaType: String?,
        title: String?
    ) -> OPDSAcquisition? {
        guard url.isOPDSHTTPURL else { return nil }
        let mediaType = rawMediaType?
            .split(separator: ";", maxSplits: 1)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            ?? ""
        let pathExtension = url.pathExtension.lowercased()
        let resolvedExtension: String?
        switch mediaType {
        case "application/epub+zip": resolvedExtension = "epub"
        case "application/x-mobipocket-ebook": resolvedExtension = "mobi"
        case "application/vnd.amazon.ebook": resolvedExtension = pathExtension == "azw" ? "azw" : "azw3"
        case "application/pdf": resolvedExtension = "pdf"
        case "text/plain": resolvedExtension = "txt"
        case "text/html", "application/xhtml+xml": resolvedExtension = "html"
        default:
            resolvedExtension = Self.supportedExtensions.contains(pathExtension) ? pathExtension : nil
        }
        guard let resolvedExtension else { return nil }
        return OPDSAcquisition(
            url: url,
            mediaType: mediaType,
            title: title?.opdsNonEmpty,
            fileExtension: resolvedExtension
        )
    }

    private static let supportedExtensions: Set<String> = [
        "epub", "mobi", "azw", "azw3", "pdf", "txt", "html", "htm",
    ]
}

extension URL {
    nonisolated var isOPDSHTTPURL: Bool {
        guard let scheme = scheme?.lowercased(), host != nil else { return false }
        return scheme == "https" || scheme == "http"
    }
}

extension String {
    nonisolated var opdsNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
