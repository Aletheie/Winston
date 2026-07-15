import Foundation

nonisolated enum HTMLReader {
    enum ReadError: Error, LocalizedError {
        case unreadable
        case empty
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn’t read the HTML file"
            case .empty:      "The HTML file has no readable body"
            case .tooLarge:   "The HTML file is too large to convert safely"
            }
        }
    }

    private static let maxDocumentBytes = 64 * 1_024 * 1_024
    private static let maxInlineImageBytes = 8 * 1_024 * 1_024

    static func read(_ url: URL) throws -> SourceDocument {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxDocumentBytes {
            throw ReadError.tooLarge
        }
        guard let data = try? Data(contentsOf: url),
              let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ReadError.unreadable
        }

        let body = MOBIHTMLBuilder.bodyInner(of: html)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReadError.empty
        }

        let images = loadImages(in: body, baseDir: url.deletingLastPathComponent())
        let docTitle = title(in: html) ?? url.deletingPathExtension().lastPathComponent
        var meta = BookMetadata()
        meta.title = docTitle
        return SourceDocument(
            title: docTitle, metadata: meta, sections: [body], images: images, coverImage: nil
        )
    }

    // MARK: - Helpers

    private static func title(in html: String) -> String? {
        let cleaned = html.removingHTMLNonContent
        guard let range = cleaned.range(of: "<title[^>]*>([\\s\\S]*?)</title>",
                                        options: [.regularExpression, .caseInsensitive]) else { return nil }
        let text = String(cleaned[range])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodingHTMLEntities()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.nonEmpty
    }

    private static func loadImages(in body: String, baseDir: URL) -> [SourceDocument.Image] {
        guard let regex = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive]) else {
            return []
        }
        let ns = body as NSString
        var images: [SourceDocument.Image] = []
        var seen = Set<String>()
        for match in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard let src = MOBIHTMLBuilder.attribute("src", in: tag), !seen.contains(src) else { continue }
            let lower = src.lowercased()
            if lower.hasPrefix("data:"),
               let comma = src.firstIndex(of: ","),
               src[..<comma].lowercased().hasSuffix(";base64"),
               src.distance(from: src.index(after: comma), to: src.endIndex) <= maxInlineImageBytes * 4 / 3 + 4,
               let data = Data(base64Encoded: String(src[src.index(after: comma)...])),
               data.count <= maxInlineImageBytes {
                seen.insert(src)
                images.append(.init(ref: src, data: data))
                continue
            }
            guard !lower.hasPrefix("http") else { continue }
            guard let fileURL = localAssetURL(for: src, inside: baseDir),
                  let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= maxInlineImageBytes,
                  let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
                  data.count == size else { continue }
            seen.insert(src)
            images.append(.init(ref: src, data: data))
        }
        return images
    }

    private static func localAssetURL(for ref: String, inside directory: URL) -> URL? {
        let path = ref.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ref
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.hasPrefix("/") else { return nil }

        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appending(path: decoded).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return file.path(percentEncoded: false).hasPrefix(prefix) ? file : nil
    }
}
