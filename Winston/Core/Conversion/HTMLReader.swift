import Foundation

nonisolated enum HTMLReader {
    enum ReadError: Error, LocalizedError {
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn’t read the HTML file"
            case .empty:      "The HTML file has no readable body"
            }
        }
    }

    static func read(_ url: URL) throws -> SourceDocument {
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
            guard !lower.hasPrefix("http"), !lower.hasPrefix("data:") else { continue }
            let fileURL = baseDir.appending(path: src)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            seen.insert(src)
            images.append(.init(ref: src, data: data))
        }
        return images
    }
}
