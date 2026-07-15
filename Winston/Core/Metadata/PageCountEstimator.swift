import Foundation
import PDFKit

nonisolated enum PageCountEstimator {

    static let charactersPerPage = 1800
    static let mobiBytesPerPage = 2048
    private static let maxTextBytes = 64 * 1_024 * 1_024

    @concurrent static func pageCount(at url: URL, format: String) async -> Int? {
        pageCountSync(at: url, format: format)
    }

    static func pageCountSync(at url: URL, format: String) -> Int? {
        switch format.lowercased() {
        case "pdf":
            guard PDFReader.isWithinSizeLimit(url),
                  let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
            return doc.pageCount
        case "epub":
            guard let archive = try? EPUBArchive(url: url),
                  let containerData = archive.entry("META-INF/container.xml"),
                  let opfPath = MetadataExtractor.parseOPFPath(from: containerData),
                  let opfData = archive.entry(opfPath),
                  let opf = try? XMLDocument(
                      data: opfData,
                      options: .nodeLoadExternalEntitiesNever
                  ) else { return nil }
            return epubPageCount(archive: archive, opfPath: opfPath, opf: opf)
        case "mobi", "azw", "azw3":
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return mobiPageCount(in: data)
        case "txt":
            guard let data = boundedTextData(at: url),
                  let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else { return nil }
            return pages(forCharacters: text.count)
        case "html", "htm":
            guard let data = boundedTextData(at: url),
                  let raw = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else { return nil }
            return pages(forCharacters: raw.removingHTMLNonContent.strippedHTML.count)
        default:
            return nil
        }
    }

    // MARK: - EPUB

    static func epubPageCount(archive: EPUBArchive, opfPath: String, opf: XMLDocument) -> Int? {
        guard let items = try? opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") else {
            return nil
        }
        var hrefByID: [String: String] = [:]
        for item in items {
            guard let element = item as? XMLElement,
                  let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue else { continue }
            hrefByID[id] = href
        }

        let idrefs = ((try? opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']/@idref")) ?? [])
            .compactMap(\.stringValue)
        guard !idrefs.isEmpty else { return nil }

        let opfDir = (opfPath as NSString).deletingLastPathComponent
        var characters = 0
        for idref in idrefs {
            guard let href = hrefByID[idref],
                  let data = archive.entry(CoverExtractor.resolve(href, dir: opfDir)),
                  let html = String(data: data, encoding: .utf8) else { continue }
            characters += html.removingHTMLNonContent.strippedHTML.count
        }
        guard characters > 0 else { return nil }
        return pages(forCharacters: characters)
    }

    // MARK: - MOBI / AZW3

    static func mobiPageCount(in data: Data) -> Int? {
        guard data.count > 132 else { return nil }
        let numRecords = Int(data.readUInt16BE(at: 76))
        guard numRecords > 0 else { return nil }
        let r0 = Int(data.readUInt32BE(at: 78))
        let mobiOff = r0 + 16
        guard mobiOff + 8 <= data.count,
              data[mobiOff] == 0x4D, data[mobiOff + 1] == 0x4F,
              data[mobiOff + 2] == 0x42, data[mobiOff + 3] == 0x49 else { return nil }
        let textLength = Int(data.readUInt32BE(at: r0 + 4))
        guard textLength > 0 else { return nil }
        return max(1, (textLength + mobiBytesPerPage - 1) / mobiBytesPerPage)
    }

    // MARK: - Shared

    static func pages(forCharacters count: Int) -> Int? {
        guard count > 0 else { return nil }
        return max(1, (count + charactersPerPage - 1) / charactersPerPage)
    }

    static func boundedTextData(at url: URL) -> Data? {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxTextBytes { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maxTextBytes else { return nil }
        return data
    }
}
