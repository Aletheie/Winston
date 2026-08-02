import Foundation

nonisolated enum OPDSDocumentFormat: String, Codable, Equatable, Sendable {
    case opds1
    case opds2
    case atom
    case mediaWiki
}

nonisolated enum OPDSSearchLink: Equatable, Sendable {
    case template(String)
    case openSearchDescription(URL)
}

nonisolated struct OPDSFeedCapabilities: Equatable, Sendable {
    let hasBrowseNavigation: Bool
    let hasRemoteSearch: Bool
    let hasPagination: Bool
    let hasAcquisitions: Bool
    let documentFormat: OPDSDocumentFormat
}

nonisolated struct OPDSFeed: Equatable, Sendable {
    let title: String
    let subtitle: String?
    let navigation: [OPDSNavigationItem]
    let publications: [OPDSPublication]
    let nextURL: URL?
    let searchLink: OPDSSearchLink?
    let documentFormat: OPDSDocumentFormat

    init(
        title: String,
        subtitle: String?,
        navigation: [OPDSNavigationItem],
        publications: [OPDSPublication],
        nextURL: URL?,
        searchLink: OPDSSearchLink? = nil,
        documentFormat: OPDSDocumentFormat = .opds1
    ) {
        self.title = title
        self.subtitle = subtitle
        self.navigation = navigation
        self.publications = publications
        self.nextURL = nextURL
        self.searchLink = searchLink
        self.documentFormat = documentFormat
    }

    var isEmpty: Bool { navigation.isEmpty && publications.isEmpty }
    var searchTemplate: String? {
        guard case .template(let template) = searchLink else { return nil }
        return template
    }
    var capabilities: OPDSFeedCapabilities {
        OPDSFeedCapabilities(
            hasBrowseNavigation: !navigation.isEmpty,
            hasRemoteSearch: searchLink != nil,
            hasPagination: nextURL != nil,
            hasAcquisitions: publications.contains {
                !$0.acquisitions.isEmpty
            },
            documentFormat: documentFormat
        )
    }

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
            searchLink: searchLink,
            documentFormat: documentFormat
        )
    }

    func providingSearchLink(_ fallback: OPDSSearchLink?) -> OPDSFeed {
        guard searchLink == nil, let fallback else { return self }
        return OPDSFeed(
            title: title,
            subtitle: subtitle,
            navigation: navigation,
            publications: publications,
            nextURL: nextURL,
            searchLink: fallback,
            documentFormat: documentFormat
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
            searchLink: searchLink ?? page.searchLink,
            documentFormat: documentFormat
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
    let identifiers: [String]
    let title: String
    let authors: [String]
    let summary: String?
    let language: String?
    let subjects: [String]
    let rights: String?
    let published: String?
    let sourceURL: URL?
    let attribution: String?
    let contributors: [String]
    let coverURL: URL?
    let acquisitions: [OPDSAcquisition]

    init(
        id: String,
        identifiers: [String] = [],
        title: String,
        authors: [String],
        summary: String?,
        language: String?,
        subjects: [String] = [],
        rights: String? = nil,
        published: String? = nil,
        sourceURL: URL? = nil,
        attribution: String? = nil,
        contributors: [String] = [],
        coverURL: URL?,
        acquisitions: [OPDSAcquisition]
    ) {
        self.id = id
        self.identifiers = identifiers
        self.title = title
        self.authors = authors
        self.summary = summary
        self.language = language
        self.subjects = subjects
        self.rights = rights
        self.published = published
        self.sourceURL = sourceURL
        self.attribution = attribution
        self.contributors = contributors
        self.coverURL = coverURL
        self.acquisitions = acquisitions
    }

    var authorLine: String? {
        let value = authors.joined(separator: ", ").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var preferredAcquisition: OPDSAcquisition? {
        acquisitionOptions.first(where: \.canImport)
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
            identifiers: Self.uniqueStrings(
                identifiers + other.identifiers
            ),
            title: title,
            authors: mergedAuthors,
            summary: summaries.max(by: { $0.count < $1.count }),
            language: language ?? other.language,
            subjects: Self.uniqueStrings(subjects + other.subjects),
            rights: rights ?? other.rights,
            published: published ?? other.published,
            sourceURL: sourceURL ?? other.sourceURL,
            attribution: attribution ?? other.attribution,
            contributors: Self.uniqueStrings(
                contributors + other.contributors
            ),
            coverURL: coverURL ?? other.coverURL,
            acquisitions: mergedAcquisitions
        )
    }

    func identified(as newID: String) -> OPDSPublication {
        OPDSPublication(
            id: newID,
            identifiers: identifiers,
            title: title,
            authors: authors,
            summary: summary,
            language: language,
            subjects: subjects,
            rights: rights,
            published: published,
            sourceURL: sourceURL,
            attribution: attribution,
            contributors: contributors,
            coverURL: coverURL,
            acquisitions: acquisitions
        )
    }

    var canonicalISBNs: Set<String> {
        Set(identifiers.compactMap(MetadataNormalizer.canonicalISBN13))
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

nonisolated enum OPDSAcquisitionRelation:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case openAccess
    case generic
    case sample
    case borrow
    case buy
    case subscribe
    case unknown

    var isDirectlyDownloadable: Bool {
        self == .openAccess || self == .generic
    }

    var localizedLabel: String {
        switch self {
        case .openAccess: String(localized: "Open access")
        case .generic: String(localized: "Direct acquisition")
        case .sample: String(localized: "Sample")
        case .borrow: String(localized: "Borrow")
        case .buy: String(localized: "Buy")
        case .subscribe: String(localized: "Subscribe")
        case .unknown: String(localized: "Unknown acquisition")
        }
    }
}

nonisolated struct OPDSAcquisition: Identifiable, Hashable, Sendable {
    let url: URL
    let mediaType: String
    let title: String?
    let fileExtension: String
    let relation: OPDSAcquisitionRelation
    let price: Decimal?
    let currency: String?
    let isSupportedFormat: Bool

    var id: String {
        "\(url.absoluteString)|\(mediaType)|\(relation.rawValue)"
    }
    var formatLabel: String {
        if !fileExtension.isEmpty { return fileExtension.uppercased() }
        return mediaType.opdsNonEmpty?.uppercased() ?? "FILE"
    }
    var optionLabel: String { title ?? formatLabel }
    var canImport: Bool {
        relation.isDirectlyDownloadable && isSupportedFormat
    }

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
        title: String?,
        relations: Set<String> = ["acquisition"],
        price: Decimal? = nil,
        currency: String? = nil
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
        let fallbackExtension = pathExtension.opdsNonEmpty ?? ""
        let fileExtension = resolvedExtension ?? fallbackExtension
        return OPDSAcquisition(
            url: url,
            mediaType: mediaType,
            title: title?.opdsNonEmpty,
            fileExtension: fileExtension,
            relation: classify(relations),
            price: price,
            currency: currency?.uppercased().opdsNonEmpty,
            isSupportedFormat: resolvedExtension != nil
        )
    }

    private static func classify(
        _ rawRelations: Set<String>
    ) -> OPDSAcquisitionRelation {
        let relations = Set(rawRelations.map { $0.lowercased() })
        if relations.contains("download")
            || relations.contains("http://opds-spec.org/acquisition/open-access")
            || relations.contains("https://opds-spec.org/acquisition/open-access") {
            return .openAccess
        }
        if relations.contains("preview")
            || relations.contains("sample")
            || relations.contains("http://opds-spec.org/acquisition/sample")
            || relations.contains("https://opds-spec.org/acquisition/sample") {
            return .sample
        }
        if relations.contains("borrow")
            || relations.contains("http://opds-spec.org/acquisition/borrow")
            || relations.contains("https://opds-spec.org/acquisition/borrow") {
            return .borrow
        }
        if relations.contains("buy")
            || relations.contains("http://opds-spec.org/acquisition/buy")
            || relations.contains("https://opds-spec.org/acquisition/buy") {
            return .buy
        }
        if relations.contains("subscribe")
            || relations.contains("http://opds-spec.org/acquisition/subscribe")
            || relations.contains("https://opds-spec.org/acquisition/subscribe") {
            return .subscribe
        }
        if relations.contains("acquisition")
            || relations.contains("enclosure")
            || relations.contains("http://opds-spec.org/acquisition")
            || relations.contains("https://opds-spec.org/acquisition") {
            return .generic
        }
        return .unknown
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
