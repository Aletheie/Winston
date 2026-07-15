import Foundation

nonisolated enum TextReader {
    enum ReadError: Error, LocalizedError {
        case unreadable
        case empty
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn’t read the text file"
            case .empty:      "The text file is empty"
            case .tooLarge:   "The text file is too large to convert safely"
            }
        }
    }

    private static let maxDocumentBytes = 64 * 1_024 * 1_024

    static func read(_ url: URL) throws -> SourceDocument {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxDocumentBytes {
            throw ReadError.tooLarge
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw ReadError.unreadable }
        guard data.count <= maxDocumentBytes else { throw ReadError.tooLarge }
        guard let text = decode(data) else { throw ReadError.unreadable }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")

        let blocks = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !blocks.isEmpty else { throw ReadError.empty }

        var html = ""
        for block in blocks {
            if isHeading(block) {
                html += "<h2>\(block.htmlEscaped)</h2>"
            } else {
                let inner = block.htmlEscaped.replacingOccurrences(of: "\n", with: "<br/>")
                html += "<p>\(inner)</p>"
            }
        }

        let title = url.deletingPathExtension().lastPathComponent
        var meta = BookMetadata()
        meta.title = title
        return SourceDocument(
            title: title, metadata: meta, sections: [html], images: [], coverImage: nil
        )
    }

    // MARK: - Helpers

    private static func isHeading(_ block: String) -> Bool {
        guard !block.contains("\n"), block.count <= 60 else { return false }
        if block.range(of: "^(chapter|kapitola|part|část)\\b",
                       options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if block.range(of: "^\\d+\\.?$", options: .regularExpression) != nil { return true }
        let letters = block.filter(\.isLetter)
        return !letters.isEmpty && letters.allSatisfy(\.isUppercase)
    }

    private static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1250) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}
