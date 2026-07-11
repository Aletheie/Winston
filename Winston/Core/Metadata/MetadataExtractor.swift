import Foundation
import PDFKit
import AppKit

// MARK: - MetadataExtractor

enum MetadataExtractor {

    nonisolated static func extractMetadata(from url: URL) -> BookMetadata {
        switch url.pathExtension.lowercased() {
        case "epub":            return extractEPUB(from: url)
        case "mobi", "azw", "azw3": return extractMOBI(from: url)
        case "pdf":             return extractPDF(from: url)
        case "html", "htm":     return extractHTML(from: url)
        default:                return BookMetadata()
        }
    }

    // MARK: - EPUB

    nonisolated private static func extractEPUB(from url: URL) -> BookMetadata {
        guard let archive = try? EPUBArchive(url: url),
              let containerData = archive.entry("META-INF/container.xml"),
              let opfPath = parseOPFPath(from: containerData),
              let opfData = archive.entry(opfPath),
              let doc = try? XMLDocument(data: opfData, options: []) else {
            return BookMetadata()
        }
        return parseOPFMetadata(doc)
    }

    nonisolated static func parseOPFMetadata(_ doc: XMLDocument) -> BookMetadata {
        var meta = BookMetadata()
        meta.title = xpathString(doc, "//*[local-name()='title']")
        meta.author = xpathString(doc, "//*[local-name()='creator']")
        meta.publisher = xpathString(doc, "//*[local-name()='publisher']")
        meta.language = xpathString(doc, "//*[local-name()='language']")

        if let dateStr = xpathString(doc, "//*[local-name()='date']"),
           let range = dateStr.range(of: "\\d{4}", options: .regularExpression) {
            meta.year = String(dateStr[range])
        }

        if let identifiers = try? doc.nodes(forXPath: "//*[local-name()='identifier']") {
            for node in identifiers {
                let text = node.stringValue ?? ""
                let scheme = (try? node.nodes(forXPath: "@*[local-name()='scheme']"))?.first?.stringValue ?? ""
                if scheme.localizedCaseInsensitiveContains("isbn")
                    || text.localizedCaseInsensitiveContains("isbn") {
                    let cleaned = text.replacingOccurrences(of: "[^0-9Xx]", with: "", options: .regularExpression)
                    if cleaned.count >= 10 {
                        meta.isbn = cleaned
                        break
                    }
                }
            }
        }

        if let s = xpathString(doc, "//*[local-name()='meta'][@name='calibre:series']/@content") {
            meta.series = s
        }
        if let i = xpathString(doc, "//*[local-name()='meta'][@name='calibre:series_index']/@content") {
            meta.seriesIndex = i
        }

        if let subjects = try? doc.nodes(forXPath: "//*[local-name()='subject']") {
            meta.tags = subjects.compactMap(\.stringValue).filter { !$0.isEmpty }
        }

        meta.description = xpathString(doc, "//*[local-name()='description']")
        return meta
    }

    // MARK: - MOBI / AZW3

    nonisolated private static func extractMOBI(from url: URL) -> BookMetadata {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > 132 else { return BookMetadata() }

        let numRecords = Int(data.readUInt16BE(at: 76))
        guard numRecords > 0 else { return BookMetadata() }

        let r0 = Int(data.readUInt32BE(at: 78))
        guard r0 + 20 < data.count else { return BookMetadata() }

        let mobiOff = r0 + 16
        guard mobiOff + 8 <= data.count,
              data[mobiOff] == 0x4D, data[mobiOff+1] == 0x4F,
              data[mobiOff+2] == 0x42, data[mobiOff+3] == 0x49
        else { return BookMetadata() }

        let headerLen = Int(data.readUInt32BE(at: mobiOff + 4))
        let textEncoding = data.readUInt32BE(at: mobiOff + 12)
        let encoding: String.Encoding = textEncoding == 65001 ? .utf8 : .windowsCP1252

        var meta = BookMetadata()

        if headerLen >= 76 {
            let nameOff = Int(data.readUInt32BE(at: mobiOff + 68)) + r0
            let nameLen = Int(data.readUInt32BE(at: mobiOff + 72))
            if nameOff + nameLen <= data.count && nameLen > 0 && nameLen < 4096 {
                meta.title = String(data: data[nameOff ..< nameOff + nameLen], encoding: encoding)
            }
        }

        MOBIIdentifiers.forEachEXTHRecord(in: data, mobiOff: mobiOff, headerLen: headerLen) { type, value in
            let str = String(data: value, encoding: encoding) ?? String(data: value, encoding: .utf8)
            switch type {
            case 100: meta.author = str
            case 101: meta.publisher = str
            case 103: meta.description = str
            case 104: meta.isbn = str
            case 106:
                if let s = str, let r = s.range(of: "\\d{4}", options: .regularExpression) {
                    meta.year = String(s[r])
                }
            case 108:
                if let s = str, !s.isEmpty { meta.tags.append(s) }
            case 110: meta.language = str
            case 503:
                if let s = str, !s.isEmpty { meta.title = s }
            default: break
            }
        }

        return meta
    }

    // MARK: - PDF

    nonisolated private static func extractPDF(from url: URL) -> BookMetadata {
        guard let doc = PDFDocument(url: url) else { return BookMetadata() }
        var meta = BookMetadata()
        let attrs = doc.documentAttributes ?? [:]
        meta.title = attrs[PDFDocumentAttribute.titleAttribute] as? String
        meta.author = attrs[PDFDocumentAttribute.authorAttribute] as? String
        if let subject = attrs[PDFDocumentAttribute.subjectAttribute] as? String, !subject.isEmpty {
            meta.tags = [subject]
        }
        return meta
    }

    // MARK: - HTML

    nonisolated private static func extractHTML(from url: URL) -> BookMetadata {
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return BookMetadata()
        }
        let html = raw.removingHTMLNonContent
        guard let range = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>",
                                     options: [.regularExpression, .caseInsensitive]) else {
            return BookMetadata()
        }
        var meta = BookMetadata()
        let text = String(html[range])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodingHTMLEntities()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        meta.title = text.nonEmpty
        return meta
    }

    // MARK: - Shared helpers

    nonisolated private static func xpathString(_ doc: XMLDocument, _ xpath: String) -> String? {
        (try? doc.nodes(forXPath: xpath))?.first?.stringValue
    }

    nonisolated static func parseOPFPath(from data: Data) -> String? {
        guard let doc = try? XMLDocument(data: data, options: []),
              let nodes = try? doc.nodes(forXPath: "//*[local-name()='rootfile']/@full-path"),
              let path = nodes.first?.stringValue else { return nil }
        return path
    }
}
