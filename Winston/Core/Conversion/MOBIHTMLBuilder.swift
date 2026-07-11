import Foundation
import os

struct MOBIContent: Sendable {
    let html: Data
    let images: [Data]
    let coverIndex: Int?
}

nonisolated enum MOBIHTMLBuilder {

    static func build(from epub: ParsedEPUB, coverJPEG: Data?, archive: EPUBArchive) -> MOBIContent {
        var images: [Data] = []
        var coverIndex: Int?
        var recindexByHref: [String: Int] = [:]

        if let coverJPEG {
            coverIndex = images.count
            images.append(coverJPEG)
            if let coverHref = epub.coverImageHref { recindexByHref[coverHref] = 1 }
        }
        for item in epub.images where recindexByHref[item.href] == nil {
            guard let raw = archive.entry(item.href),
                  let jpeg = jpegData(from: raw) else { continue }
            recindexByHref[item.href] = images.count + 1
            images.append(jpeg)
        }

        var sections: [String] = []
        for item in epub.spine where isHTML(mediaType: item.mediaType, href: item.href) {
            guard let data = archive.entry(item.href) else { continue }
            let xhtml = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            guard !xhtml.isEmpty else { continue }
            let dir = (item.href as NSString).deletingLastPathComponent
            let rewritten = rewriteImages(bodyInner(of: xhtml), dir: dir, recindexByHref: recindexByHref)
            sections.append(rewritten)
        }

        return assemble(sections: sections, images: images, coverIndex: coverIndex)
    }

    static func build(from doc: SourceDocument) -> MOBIContent {
        var images: [Data] = []
        var coverIndex: Int?
        var recindexByHref: [String: Int] = [:]

        if let coverRaw = doc.coverImage, let jpeg = jpegData(from: coverRaw) {
            coverIndex = images.count
            images.append(jpeg)
        }
        for image in doc.images {
            let key = CoverExtractor.resolve(image.ref, dir: "")
            guard recindexByHref[key] == nil, let jpeg = jpegData(from: image.data) else { continue }
            recindexByHref[key] = images.count + 1
            images.append(jpeg)
        }

        let sections = doc.sections.map { rewriteImages($0, dir: "", recindexByHref: recindexByHref) }
        return assemble(sections: sections, images: images, coverIndex: coverIndex)
    }

    private static func assemble(sections: [String], images: [Data], coverIndex: Int?) -> MOBIContent {
        let joined = sections.joined(separator: "<mbp:pagebreak/>")
        let doc = "<html><head><guide></guide></head><body>\(joined)</body></html>"
        return MOBIContent(html: Data(doc.utf8), images: images, coverIndex: coverIndex)
    }

    // MARK: - HTML helpers

    private static func isHTML(mediaType: String, href: String) -> Bool {
        let mt = mediaType.lowercased()
        if mt.contains("html") || mt.contains("xml") { return true }
        let ext = (href as NSString).pathExtension.lowercased()
        return ["xhtml", "html", "htm"].contains(ext)
    }

    static func bodyInner(of xhtml: String) -> String {
        let cleaned = xhtml.removingHTMLNonContent
        guard let open = cleaned.range(of: "<body[^>]*>",
                                       options: [.regularExpression, .caseInsensitive]) else {
            return stripProlog(cleaned)
        }
        if let close = cleaned.range(of: "</body>", options: [.caseInsensitive],
                                     range: open.upperBound ..< cleaned.endIndex) {
            return String(cleaned[open.upperBound ..< close.lowerBound])
        }
        return String(cleaned[open.upperBound...])
    }

    private static func stripProlog(_ html: String) -> String {
        var s = html
        for pattern in ["<\\?xml[^>]*\\?>", "<!DOCTYPE[^>]*>", "<head[\\s\\S]*?</head>", "</?html[^>]*>"] {
            s = s.replacingOccurrences(of: pattern, with: "",
                                       options: [.regularExpression, .caseInsensitive])
        }
        return s
    }

    private static let imgTagRegex = try! NSRegularExpression(
        pattern: "<img\\b[^>]*>", options: [.caseInsensitive]
    )

    static func rewriteImages(_ html: String, dir: String, recindexByHref: [String: Int]) -> String {
        let regex = imgTagRegex
        guard !recindexByHref.isEmpty else {
            return regex.stringByReplacingMatches(
                in: html, range: NSRange(location: 0, length: (html as NSString).length),
                withTemplate: ""
            )
        }
        let ns = html as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let tag = ns.substring(with: m.range)
            if let src = attribute("src", in: tag) {
                let resolved = CoverExtractor.resolve(src, dir: dir)
                if let idx = recindexByHref[resolved] {
                    result += "<img recindex=\"\(idx)\"/>"
                }
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static let attributeRegexes = OSAllocatedUnfairLock<[String: NSRegularExpression]>(initialState: [:])

    static func attribute(_ name: String, in tag: String) -> String? {
        firstGroup(cachedRegex("q:\(name)", pattern: "\(name)\\s*=\\s*[\"']([^\"']*)[\"']"), in: tag)
            ?? firstGroup(cachedRegex("u:\(name)", pattern: "\(name)\\s*=\\s*([^\\s\"'>]+)"), in: tag)
    }

    private static func cachedRegex(_ key: String, pattern: String) -> NSRegularExpression {
        attributeRegexes.withLock { cache in
            if let regex = cache[key] { return regex }
            let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            cache[key] = regex
            return regex
        }
    }

    private static func firstGroup(_ regex: NSRegularExpression, in string: String) -> String? {
        guard let m = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let r = Range(m.range(at: 1), in: string) else { return nil }
        return String(string[r])
    }

    // MARK: - Images

    static func jpegData(from data: Data) -> Data? {
        ImageTranscoder.jpegData(from: data)
    }
}
