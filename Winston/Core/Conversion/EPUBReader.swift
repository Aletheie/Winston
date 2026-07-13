import Foundation

struct ParsedEPUB: Sendable {
    struct Item: Sendable {
        let id: String
        let href: String
        let mediaType: String
        let properties: String
    }

    let zipURL: URL
    let metadata: BookMetadata
    let manifest: [Item]
    let spine: [Item]
    let coverImageHref: String?

    nonisolated var images: [Item] {
        manifest.filter { $0.mediaType.lowercased().hasPrefix("image/") }
    }
}

nonisolated enum EPUBReader {
    enum ReadError: Error, LocalizedError {
        case notAnEPUB
        case missingOPF
        case emptySpine

        var errorDescription: String? {
            switch self {
            case .notAnEPUB:   "Not a readable EPUB container"
            case .missingOPF:  "EPUB is missing its content.opf"
            case .emptySpine:  "EPUB has no readable content"
            }
        }
    }

    static func read(_ url: URL) throws -> ParsedEPUB {
        try read(url, archive: EPUBArchive(url: url))
    }

    static func read(_ url: URL, archive: EPUBArchive) throws -> ParsedEPUB {
        guard let containerData = archive.entry("META-INF/container.xml"),
              let opfPath = MetadataExtractor.parseOPFPath(from: containerData) else {
            throw ReadError.notAnEPUB
        }
        guard let opfData = archive.entry(opfPath),
              let doc = try? XMLDocument(data: opfData, options: []) else {
            throw ReadError.missingOPF
        }
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        var manifest: [ParsedEPUB.Item] = []
        var byID: [String: ParsedEPUB.Item] = [:]
        if let nodes = try? doc.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            for node in nodes {
                guard let el = node as? XMLElement,
                      let id = el.attribute(forName: "id")?.stringValue,
                      let rawHref = el.attribute(forName: "href")?.stringValue else { continue }
                let item = ParsedEPUB.Item(
                    id: id,
                    href: CoverExtractor.resolve(rawHref, dir: opfDir),
                    mediaType: el.attribute(forName: "media-type")?.stringValue ?? "",
                    properties: el.attribute(forName: "properties")?.stringValue ?? ""
                )
                manifest.append(item)
                byID[id] = item
            }
        }

        var spine: [ParsedEPUB.Item] = []
        if let refs = try? doc.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']") {
            for node in refs {
                guard let el = node as? XMLElement,
                      let idref = el.attribute(forName: "idref")?.stringValue,
                      let item = byID[idref] else { continue }
                spine.append(item)
            }
        }
        guard !spine.isEmpty else { throw ReadError.emptySpine }

        let coverHref = CoverExtractor.coverCandidates(from: doc, opfDir: opfDir, archive: archive)
            .first { archive.entry($0) != nil }

        var metadata = MetadataExtractor.parseOPFMetadata(doc)
        metadata.pageCount = PageCountEstimator.epubPageCount(archive: archive, opfPath: opfPath, opf: doc)

        return ParsedEPUB(
            zipURL: url,
            metadata: metadata,
            manifest: manifest,
            spine: spine,
            coverImageHref: coverHref
        )
    }
}
