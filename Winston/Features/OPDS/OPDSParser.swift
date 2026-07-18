import Foundation

nonisolated enum OPDSParser {
    enum ParseError: Error, Equatable, Sendable {
        case unsupportedDocument
        case malformedDocument
    }

    static func parse(_ data: Data, baseURL: URL, contentType: String? = nil) throws -> OPDSFeed {
        let type = contentType?.lowercased() ?? ""
        let firstByte = data.first { byte in
            byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D
        }

        if type.contains("json") || firstByte == 0x7B || firstByte == 0x5B {
            return try parseJSON(data, baseURL: baseURL)
        }
        if type.contains("xml") || type.contains("atom") || firstByte == 0x3C {
            return try parseAtom(data, baseURL: baseURL)
        }
        throw ParseError.unsupportedDocument
    }

    // MARK: - OPDS 1 / Atom

    private static func parseAtom(_ data: Data, baseURL: URL) throws -> OPDSFeed {
        let delegate = AtomFeedDelegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        guard parser.parse(), parser.parserError == nil else {
            throw ParseError.malformedDocument
        }
        return delegate.feed
    }

    // MARK: - OPDS 2 / JSON

    private static func parseJSON(_ data: Data, baseURL: URL) throws -> OPDSFeed {
        let document: JSONFeed
        do {
            document = try JSONDecoder().decode(JSONFeed.self, from: data)
        } catch {
            throw ParseError.malformedDocument
        }

        let groupNavigation = document.groups.flatMap(\.navigation)
        let navigation = unique(
            (document.navigation + groupNavigation).compactMap { link -> OPDSNavigationItem? in
                guard let url = resolveURL(link.href, baseURL: baseURL),
                      let title = link.title?.opdsNonEmpty else { return nil }
                return OPDSNavigationItem(
                    title: title,
                    subtitle: nil,
                    url: url,
                    coverURL: nil
                )
            },
            by: { $0.id }
        )

        let groupPublications = document.groups.flatMap(\.publications)
        let publications = mergeProviderVariants(unique(
            (document.publications + groupPublications).compactMap { publication in
                makePublication(publication, baseURL: baseURL)
            },
            by: { $0.id }
        ))

        let nextURL = document.links.first(where: { $0.relations.contains("next") })
            .flatMap { resolveURL($0.href, baseURL: baseURL) }
        let searchTemplate = document.links.first(where: {
            $0.relations.contains("search") && ($0.templated || $0.href.contains("{"))
        }).flatMap { resolveTemplate($0.href, baseURL: baseURL) }

        return OPDSFeed(
            title: document.metadata.title?.opdsNonEmpty ?? "Catalog",
            subtitle: (document.metadata.subtitle ?? document.metadata.description)?.opdsNonEmpty,
            navigation: navigation,
            publications: publications,
            nextURL: nextURL,
            searchTemplate: searchTemplate
        )
    }

    private static func makePublication(_ wire: JSONPublication, baseURL: URL) -> OPDSPublication? {
        guard let title = wire.metadata.title?.opdsNonEmpty else { return nil }
        let acquisitionLinks = wire.links.filter { link in
            link.relations.contains { relation in
                relation == "download"
                    || relation == "enclosure"
                    || relation == "acquisition"
                    || relation.hasPrefix("http://opds-spec.org/acquisition")
                    || relation.hasPrefix("https://opds-spec.org/acquisition")
            }
        }
        let acquisitions = unique(
            acquisitionLinks.compactMap { link -> OPDSAcquisition? in
                guard let url = resolveURL(link.href, baseURL: baseURL) else { return nil }
                return OPDSAcquisition.make(url: url, mediaType: link.type, title: link.title)
            },
            by: \.id
        )
        guard !acquisitions.isEmpty else { return nil }

        let coverLinks = wire.images + wire.links.filter { link in
            link.relations.contains { relation in
                relation == "cover" || relation.contains("/image")
            }
        }
        let coverURL = coverLinks.lazy.compactMap { resolveURL($0.href, baseURL: baseURL) }
            .first(where: \.isOPDSHTTPURL)
        let authors = unique(wire.metadata.author.values.compactMap(\.opdsNonEmpty), by: { $0 })
        let identifier = wire.metadata.identifier?.opdsNonEmpty
            ?? acquisitions.first?.url.absoluteString
            ?? "\(title)|\(authors.joined(separator: ","))"

        return OPDSPublication(
            id: identifier,
            title: title,
            authors: authors,
            summary: wire.metadata.description?.strippedHTML.opdsNonEmpty,
            language: wire.metadata.language.values.first?.opdsNonEmpty,
            coverURL: coverURL,
            acquisitions: acquisitions
        )
    }

    fileprivate static func resolveURL(_ href: String, baseURL: URL) -> URL? {
        guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
              url.isOPDSHTTPURL else { return nil }
        return url
    }

    fileprivate static func resolveTemplate(_ href: String, baseURL: URL) -> String? {
        var protected = href
        var replacements: [(token: String, template: String)] = []
        var searchStart = protected.startIndex
        var index = 0
        while let open = protected[searchStart...].firstIndex(of: "{"),
              let close = protected[open...].firstIndex(of: "}") {
            let range = open...close
            let template = String(protected[range])
            let token = "__WINSTON_OPDS_TEMPLATE_\(index)__"
            protected.replaceSubrange(range, with: token)
            replacements.append((token, template))
            searchStart = protected.index(open, offsetBy: token.count)
            index += 1
        }
        guard let resolved = URL(string: protected, relativeTo: baseURL)?.absoluteURL,
              resolved.isOPDSHTTPURL else { return nil }
        var value = resolved.absoluteString
        for replacement in replacements {
            value = value.replacingOccurrences(of: replacement.token, with: replacement.template)
        }
        return value
    }

    fileprivate static func unique<T, Key: Hashable>(
        _ values: [T],
        by key: (T) -> Key
    ) -> [T] {
        var seen: Set<Key> = []
        return values.filter { seen.insert(key($0)).inserted }
    }

    fileprivate static func mergeProviderVariants(
        _ publications: [OPDSPublication]
    ) -> [OPDSPublication] {
        var merged: [OPDSPublication] = []
        var indexes: [String: Int] = [:]
        for publication in publications {
            guard let workID = gutenbergWorkID(publication.id) else {
                merged.append(publication)
                continue
            }
            if let index = indexes[workID] {
                merged[index] = merged[index].merging(publication, id: workID)
            } else {
                indexes[workID] = merged.count
                merged.append(publication.identified(as: workID))
            }
        }
        return merged
    }

    private static func gutenbergWorkID(_ id: String) -> String? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4,
              parts[0].lowercased() == "urn",
              parts[1].lowercased() == "gutenberg",
              Int(parts[2]) != nil else { return nil }
        return parts.prefix(3).joined(separator: ":")
    }
}

// MARK: - Atom parser

private nonisolated final class AtomFeedDelegate: NSObject, XMLParserDelegate {
    private enum CaptureField {
        case feedTitle
        case feedSubtitle
        case entryID
        case entryTitle
        case entrySummary
        case entryLanguage
        case entryAuthor
    }

    private struct Capture {
        let field: CaptureField
        let depth: Int
        var text = ""
    }

    private struct Link {
        let relations: Set<String>
        let type: String?
        let title: String?
        let href: String
    }

    private struct Entry {
        var id: String?
        var title: String?
        var summary: String?
        var language: String?
        var authors: [String] = []
        var links: [Link] = []
    }

    private let baseURL: URL
    private var depth = 0
    private var authorDepth = 0
    private var capture: Capture?
    private var currentEntry: Entry?
    private var feedTitle: String?
    private var feedSubtitle: String?
    private var feedLinks: [Link] = []
    private var navigation: [OPDSNavigationItem] = []
    private var publications: [OPDSPublication] = []

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    var feed: OPDSFeed {
        let nextURL = feedLinks.first(where: { $0.relations.contains("next") })
            .flatMap(resolve)
        let searchTemplate = feedLinks.first(where: { link in
            link.relations.contains("search")
                && link.type?.lowercased().contains("opensearchdescription") != true
                && link.href.contains("{")
        }).flatMap { OPDSParser.resolveTemplate($0.href, baseURL: baseURL) }
        return OPDSFeed(
            title: feedTitle?.opdsNonEmpty ?? "Catalog",
            subtitle: feedSubtitle?.strippedHTML.opdsNonEmpty,
            navigation: OPDSParser.unique(navigation, by: \.id),
            publications: OPDSParser.mergeProviderVariants(
                OPDSParser.unique(publications, by: \.id)
            ),
            nextURL: nextURL,
            searchTemplate: searchTemplate
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        if capture != nil { return }
        let name = localName(elementName)

        switch name {
        case "entry":
            currentEntry = Entry()
        case "author":
            authorDepth += 1
        case "link":
            guard let href = attributeDict["href"]?.opdsNonEmpty else { return }
            let relations = Set((attributeDict["rel"] ?? "alternate")
                .split(whereSeparator: \.isWhitespace)
                .map { String($0).lowercased() })
            let link = Link(
                relations: relations,
                type: attributeDict["type"]?.lowercased(),
                title: attributeDict["title"]?.opdsNonEmpty,
                href: href
            )
            if currentEntry != nil {
                currentEntry?.links.append(link)
            } else {
                feedLinks.append(link)
            }
        case "thumbnail" where currentEntry != nil:
            guard let href = attributeDict["url"]?.opdsNonEmpty else { return }
            currentEntry?.links.append(Link(
                relations: ["cover"],
                type: attributeDict["type"]?.lowercased(),
                title: nil,
                href: href
            ))
        case "title":
            beginCapture(currentEntry == nil ? .feedTitle : .entryTitle)
        case "subtitle" where currentEntry == nil:
            beginCapture(.feedSubtitle)
        case "id" where currentEntry != nil:
            beginCapture(.entryID)
        case "summary" where currentEntry != nil,
             "content" where currentEntry != nil:
            if currentEntry?.summary == nil { beginCapture(.entrySummary) }
        case "language" where currentEntry != nil:
            beginCapture(.entryLanguage)
        case "name" where currentEntry != nil && authorDepth > 0:
            beginCapture(.entryAuthor)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        capture?.text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if let active = capture, active.depth == depth {
            finishCapture(active)
            capture = nil
        }

        let name = localName(elementName)
        if name == "entry", let entry = currentEntry {
            finishEntry(entry)
            currentEntry = nil
        } else if name == "author" {
            authorDepth = max(0, authorDepth - 1)
        }
        depth -= 1
    }

    private func beginCapture(_ field: CaptureField) {
        capture = Capture(field: field, depth: depth)
    }

    private func finishCapture(_ capture: Capture) {
        let text = capture.text.opdsNonEmpty
        switch capture.field {
        case .feedTitle: feedTitle = text
        case .feedSubtitle: feedSubtitle = text
        case .entryID: currentEntry?.id = text
        case .entryTitle: currentEntry?.title = text
        case .entrySummary: currentEntry?.summary = text
        case .entryLanguage: currentEntry?.language = text
        case .entryAuthor:
            if let text { currentEntry?.authors.append(text) }
        }
    }

    private func finishEntry(_ entry: Entry) {
        let acquisitionLinks = entry.links.filter { link in
            link.relations.contains { relation in
                relation == "acquisition"
                    || relation == "enclosure"
                    || relation.hasPrefix("http://opds-spec.org/acquisition")
                    || relation.hasPrefix("https://opds-spec.org/acquisition")
            }
        }
        let acquisitions = acquisitionLinks.compactMap { link -> OPDSAcquisition? in
            guard let url = resolve(link) else { return nil }
            return OPDSAcquisition.make(url: url, mediaType: link.type, title: link.title)
        }
        let uniqueAcquisitions = OPDSParser.unique(acquisitions, by: \.id)
        let coverURL = entry.links.lazy
            .filter { link in link.relations.contains(where: { $0.contains("/image") || $0 == "cover" }) }
            .compactMap(resolve)
            .first(where: \.isOPDSHTTPURL)
        let title = entry.title?.opdsNonEmpty ?? "Untitled"

        if !uniqueAcquisitions.isEmpty {
            let id = entry.id?.opdsNonEmpty
                ?? uniqueAcquisitions.first?.url.absoluteString
                ?? "\(title)|\(entry.authors.joined(separator: ","))"
            publications.append(OPDSPublication(
                id: id,
                title: title,
                authors: OPDSParser.unique(entry.authors.compactMap(\.opdsNonEmpty), by: { $0 }),
                summary: entry.summary?.strippedHTML.opdsNonEmpty,
                language: entry.language?.opdsNonEmpty,
                coverURL: coverURL,
                acquisitions: uniqueAcquisitions
            ))
            return
        }

        let navigationLink = entry.links.first(where: { link in
            link.relations.contains("subsection")
                || link.relations.contains("collection")
                || link.relations.contains("related")
                || link.type?.contains("opds-catalog") == true
                || link.type?.contains("opds+json") == true
        })
        guard let navigationLink, let url = resolve(navigationLink) else { return }
        let subtitle = entry.authors.first?.opdsNonEmpty ?? entry.summary?.strippedHTML.opdsNonEmpty
        navigation.append(OPDSNavigationItem(
            title: title,
            subtitle: subtitle,
            url: url,
            coverURL: coverURL
        ))
    }

    private func resolve(_ link: Link) -> URL? {
        OPDSParser.resolveURL(link.href, baseURL: baseURL)
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
    }
}

// MARK: - OPDS 2 wire format

private nonisolated struct JSONFeed: Decodable {
    let metadata: JSONMetadata
    let links: [JSONLink]
    let navigation: [JSONLink]
    let publications: [JSONPublication]
    let groups: [JSONGroup]

    private enum CodingKeys: String, CodingKey {
        case metadata, links, navigation, publications, groups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decodeIfPresent(JSONMetadata.self, forKey: .metadata) ?? JSONMetadata()
        links = try container.decodeIfPresent([JSONLink].self, forKey: .links) ?? []
        navigation = try container.decodeIfPresent([JSONLink].self, forKey: .navigation) ?? []
        publications = try container.decodeIfPresent([JSONPublication].self, forKey: .publications) ?? []
        groups = try container.decodeIfPresent([JSONGroup].self, forKey: .groups) ?? []
    }
}

private nonisolated struct JSONGroup: Decodable {
    let navigation: [JSONLink]
    let publications: [JSONPublication]

    private enum CodingKeys: String, CodingKey { case navigation, publications }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        navigation = try container.decodeIfPresent([JSONLink].self, forKey: .navigation) ?? []
        publications = try container.decodeIfPresent([JSONPublication].self, forKey: .publications) ?? []
    }
}

private nonisolated struct JSONPublication: Decodable {
    let metadata: JSONMetadata
    let links: [JSONLink]
    let images: [JSONLink]

    private enum CodingKeys: String, CodingKey { case metadata, links, images }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decodeIfPresent(JSONMetadata.self, forKey: .metadata) ?? JSONMetadata()
        links = try container.decodeIfPresent([JSONLink].self, forKey: .links) ?? []
        images = try container.decodeIfPresent([JSONLink].self, forKey: .images) ?? []
    }
}

private nonisolated struct JSONMetadata: Decodable {
    var title: String?
    var subtitle: String?
    var description: String?
    var identifier: String?
    var author = FlexibleContributors()
    var language = FlexibleStrings()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, description, identifier, author, language
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        identifier = try? container.decodeIfPresent(String.self, forKey: .identifier)
        author = (try? container.decodeIfPresent(FlexibleContributors.self, forKey: .author)) ?? FlexibleContributors()
        language = (try? container.decodeIfPresent(FlexibleStrings.self, forKey: .language)) ?? FlexibleStrings()
    }
}

private nonisolated struct JSONLink: Decodable {
    let href: String
    let type: String?
    let title: String?
    let rel: FlexibleStrings
    let templated: Bool

    private enum CodingKeys: String, CodingKey { case href, type, title, rel, templated }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        href = try container.decode(String.self, forKey: .href)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        rel = (try? container.decodeIfPresent(FlexibleStrings.self, forKey: .rel)) ?? FlexibleStrings()
        templated = (try? container.decodeIfPresent(Bool.self, forKey: .templated)) ?? false
    }

    var relations: Set<String> {
        Set(rel.values.map { $0.lowercased() })
    }
}

private nonisolated struct FlexibleStrings: Decodable {
    var values: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            values = [value]
        } else if let values = try? container.decode([String].self) {
            self.values = values
        }
    }
}

private nonisolated struct FlexibleContributors: Decodable {
    private struct Contributor: Decodable {
        let name: String
    }

    var values: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            values = [value]
        } else if let values = try? container.decode([String].self) {
            self.values = values
        } else if let value = try? container.decode(Contributor.self) {
            values = [value.name]
        } else if let values = try? container.decode([Contributor].self) {
            self.values = values.map(\.name)
        }
    }
}
