import Foundation
import OSLog

nonisolated struct ManagedLeafName: RawRepresentable, Sendable, Hashable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue != ".",
              rawValue != ".."
        else { return nil }
        // Keep the predicate explicit: optimized Swift builds can incorrectly
        // share contains/allSatisfy specializations of bound CharacterSet methods.
        let controls = CharacterSet.controlCharacters
        for scalar in rawValue.unicodeScalars where scalar == "/" || controls.contains(scalar) {
            return nil
        }
        self.rawValue = rawValue
    }

    func appending(to directory: URL) -> URL? {
        let root = directory.standardizedFileURL
        let candidate = root.appending(path: rawValue).standardizedFileURL
        guard candidate.deletingLastPathComponent() == root else { return nil }
        return candidate
    }
}

enum BookFileStore {
    /// Constructs a managed URL from catalog data without touching the
    /// filesystem. Callers that perform I/O must still use `validatedURL`.
    nonisolated static func catalogURL(
        for fileName: String, in directory: URL = AppPaths.booksDirectory
    ) -> URL? {
        guard let leaf = ManagedLeafName(rawValue: fileName),
              let candidate = leaf.appending(to: directory) else { return nil }
        return candidate
    }

    nonisolated static func validatedURL(
        for fileName: String, in directory: URL = AppPaths.booksDirectory
    ) -> URL? {
        guard let candidate = catalogURL(for: fileName, in: directory) else { return nil }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent() == root else { return nil }
        return candidate
    }

    nonisolated static func url(for fileName: String) -> URL {
        guard let url = validatedURL(for: fileName) else {
            Log.persistence.error("Rejected unsafe managed file name: \(fileName, privacy: .private)")
            return AppPaths.booksDirectory.appending(path: ".invalid-managed-reference")
        }
        return url
    }

    nonisolated static func size(of fileName: String) -> Int64 {
        guard let url = validatedURL(for: fileName) else { return 0 }
        let path = url.path(percentEncoded: false)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int64) ?? 0
    }

}

nonisolated enum HTMLAssetInliner {
    private enum ImportError: Error { case sourceTooLarge }
    private static let maxHTMLBytes = 32 * 1_024 * 1_024
    private static let maxImageBytes = 8 * 1_024 * 1_024
    private static let maxTotalImageBytes = 24 * 1_024 * 1_024
    private static let maxPortableHTMLBytes = 64 * 1_024 * 1_024

    static func portableData(for source: URL) throws -> Data? {
        guard ["html", "htm"].contains(source.pathExtension.lowercased()) else { return nil }
        try Task.checkCancellation()
        if let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxHTMLBytes {
            throw ImportError.sourceTooLarge
        }
        let sourceData = try Data(contentsOf: source, options: .mappedIfSafe)
        guard sourceData.count <= maxHTMLBytes else { throw ImportError.sourceTooLarge }
        guard let html = String(data: sourceData, encoding: .utf8)
                ?? String(data: sourceData, encoding: .isoLatin1) else { return nil }

        let ns = html as NSString
        var cachedURIs: [String: String] = [:]
        var totalImageBytes = 0
        var output = Data()
        var cursor = 0
        var failure: (any Error)?
        output.reserveCapacity(sourceData.count)

        imageTagsRegex.enumerateMatches(
            in: html,
            options: [.reportProgress],
            range: NSRange(location: 0, length: ns.length)
        ) { match, _, stop in
            do {
                try Task.checkCancellation()
                guard let match,
                      let attribute = sourceAttribute(in: ns.substring(with: match.range)),
                      let uri = dataURI(
                        for: attribute.value,
                        relativeTo: source.deletingLastPathComponent(),
                        cached: &cachedURIs,
                        totalBytes: &totalImageBytes
                      ) else { return }
                let valueRange = NSRange(
                    location: match.range.location + attribute.range.location,
                    length: attribute.range.length
                )
                try append(ns.substring(with: NSRange(
                    location: cursor,
                    length: valueRange.location - cursor
                )), to: &output)
                try append(attribute.quoted ? uri : "\"\(uri)\"", to: &output)
                cursor = NSMaxRange(valueRange)
            } catch {
                failure = error
                stop.pointee = true
            }
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        try append(ns.substring(from: cursor), to: &output)
        return output
    }

    // Count every reference, including repeated cached images, before growing
    // the result. Appending once avoids repeatedly shifting an expanding HTML string.
    private static func append(_ fragment: String, to output: inout Data) throws {
        guard fragment.utf8.count <= maxPortableHTMLBytes - output.count else {
            throw ImportError.sourceTooLarge
        }
        output.append(contentsOf: fragment.utf8)
    }

    private static let imageTagsRegex = try! NSRegularExpression(
        pattern: "<img\\b[^>]*>", options: [.caseInsensitive]
    )

    private static let sourceAttributeRegex = try! NSRegularExpression(
        pattern: "(?:^|\\s)src\\s*=\\s*(?:([\\\"'])([^\\\"']*)\\1|([^\\s\\\"'>]+))",
        options: [.caseInsensitive]
    )

    private static func sourceAttribute(in tag: String) -> (value: String, range: NSRange, quoted: Bool)? {
        let fullRange = NSRange(location: 0, length: (tag as NSString).length)
        guard let match = sourceAttributeRegex.firstMatch(in: tag, range: fullRange) else { return nil }
        let quotedRange = match.range(at: 2)
        let valueRange = quotedRange.location == NSNotFound ? match.range(at: 3) : quotedRange
        guard valueRange.location != NSNotFound else { return nil }
        return ((tag as NSString).substring(with: valueRange), valueRange, quotedRange.location != NSNotFound)
    }

    private static func dataURI(
        for ref: String,
        relativeTo baseDirectory: URL,
        cached: inout [String: String],
        totalBytes: inout Int
    ) -> String? {
        let lower = ref.lowercased()
        guard !lower.hasPrefix("data:"), !lower.hasPrefix("http:"), !lower.hasPrefix("https:") else {
            return nil
        }
        if let cached = cached[ref] { return cached }

        let path = ref.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ref
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.hasPrefix("/") else { return nil }

        let root = baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appending(path: decoded)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rawRootPath = root.path(percentEncoded: false)
        let rootPath = rawRootPath.hasSuffix("/") ? rawRootPath : rawRootPath + "/"
        guard file.path(percentEncoded: false).hasPrefix(rootPath) else { return nil }

        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
        guard let size = values.fileSize,
              size <= maxImageBytes,
              totalBytes <= maxTotalImageBytes - size,
              let mime = mimeType(for: file.pathExtension) else { return nil }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        guard data.count == size else { return nil }

        totalBytes += size
        let uri = "data:\(mime);base64,\(data.base64EncodedString())"
        cached[ref] = uri
        return uri
    }

    private static func mimeType(for fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png":         "image/png"
        case "gif":         "image/gif"
        case "webp":        "image/webp"
        case "tif", "tiff": "image/tiff"
        case "heic", "heif": "image/heic"
        default: nil
        }
    }
}
