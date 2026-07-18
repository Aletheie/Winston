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
            rootURL: URL(string: "https://standardebooks.org/feeds/atom/new-releases")!,
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
        var combinedPublications: [OPDSPublication] = []
        var publicationIndexes: [String: Int] = [:]
        for publication in publications + page.publications {
            if let index = publicationIndexes[publication.id] {
                combinedPublications[index] = combinedPublications[index].merging(publication)
            } else {
                publicationIndexes[publication.id] = combinedPublications.count
                combinedPublications.append(publication)
            }
        }
        return OPDSFeed(
            title: title,
            subtitle: subtitle ?? page.subtitle,
            navigation: navigation + newNavigation,
            publications: combinedPublications,
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
        acquisitionOptions.first
    }

    var acquisitionOptions: [OPDSAcquisition] {
        acquisitions.sorted { lhs, rhs in
            if lhs.preferenceRank != rhs.preferenceRank {
                return lhs.preferenceRank < rhs.preferenceRank
            }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }
    }

    func merging(_ other: OPDSPublication, id mergedID: String? = nil) -> OPDSPublication {
        var seenAuthors = Set(authors)
        let mergedAuthors = authors + other.authors.filter { seenAuthors.insert($0).inserted }
        var seenAcquisitions = Set(acquisitions.map(\.id))
        let mergedAcquisitions = acquisitions + other.acquisitions.filter {
            seenAcquisitions.insert($0.id).inserted
        }
        let summaries = [summary, other.summary].compactMap { $0 }
        return OPDSPublication(
            id: mergedID ?? id,
            title: title,
            authors: mergedAuthors,
            summary: summaries.max(by: { $0.count < $1.count }),
            language: language ?? other.language,
            coverURL: coverURL ?? other.coverURL,
            acquisitions: mergedAcquisitions
        )
    }

    func identified(as newID: String) -> OPDSPublication {
        OPDSPublication(
            id: newID,
            title: title,
            authors: authors,
            summary: summary,
            language: language,
            coverURL: coverURL,
            acquisitions: acquisitions
        )
    }
}

nonisolated struct OPDSAcquisition: Identifiable, Hashable, Sendable {
    let url: URL
    let mediaType: String
    let title: String?
    let fileExtension: String

    var id: String { "\(url.absoluteString)|\(mediaType)" }
    var formatLabel: String { fileExtension.uppercased() }
    var optionLabel: String { title ?? formatLabel }

    fileprivate var preferenceRank: Int {
        let formatRank = switch fileExtension {
        case "epub": 0
        case "mobi", "azw", "azw3": 100
        case "pdf": 200
        case "txt": 300
        case "html", "htm": 400
        default: 1_000
        }
        let normalizedTitle = title?.lowercased() ?? ""
        let variantRank: Int
        if normalizedTitle.contains("recommended") {
            variantRank = 0
        } else if normalizedTitle.contains("epub3") {
            variantRank = 1
        } else if normalizedTitle.contains("advanced") {
            variantRank = 2
        } else if normalizedTitle.contains("no images") {
            variantRank = 9
        } else {
            variantRank = 3
        }
        return formatRank + variantRank
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
        case "application/x-mobipocket-ebook":
            resolvedExtension = ["mobi", "azw", "azw3"].contains(pathExtension)
                ? pathExtension
                : "mobi"
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
