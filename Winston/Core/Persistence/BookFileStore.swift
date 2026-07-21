import Foundation
import OSLog

nonisolated struct ManagedLeafName: RawRepresentable, Sendable, Hashable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue != ".",
              rawValue != "..",
              !rawValue.contains("/"),
              !rawValue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
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
    // Trash is for user-initiated book removal only; artifact cleanup stays on delete(fileName:).
    // Tests disable trashing so fixtures never land in the user's Trash (process-global, like AppPaths).
    nonisolated(unsafe) static var trashesRemovedBooks = true

    nonisolated static func replacementCopy(
        of source: URL,
        replacing existingFileName: String,
        uuid: UUID
    ) throws -> String {
        let candidate = fileName(for: source, uuid: uuid)
        return try importCopy(of: source, uuid: candidate == existingFileName ? UUID() : uuid)
    }

    nonisolated static func importCopy(of source: URL, uuid: UUID) throws -> String {
        try AppPaths.ensureDirectory(AppPaths.booksDirectory)
        let fileName = fileName(for: source, uuid: uuid)
        guard let destination = validatedURL(for: fileName) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        if source.standardizedFileURL == destination.standardizedFileURL {
            return fileName
        }

        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(fileName).\(UUID().uuidString).importing")
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: temporary) }

        if let portableHTML = try HTMLAssetInliner.portableData(for: source) {
            try portableHTML.write(to: temporary)
        } else {
            try fileManager.copyItem(at: source, to: temporary)
        }
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        return fileName
    }

    private nonisolated static func fileName(for source: URL, uuid: UUID) -> String {
        let ext = source.pathExtension.lowercased()
        return ext.isEmpty ? uuid.uuidString : "\(uuid.uuidString).\(ext)"
    }

    nonisolated static func validatedURL(for fileName: String) -> URL? {
        guard let leaf = ManagedLeafName(rawValue: fileName),
              let candidate = leaf.appending(to: AppPaths.booksDirectory) else { return nil }

        let root = AppPaths.booksDirectory.standardizedFileURL.resolvingSymlinksInPath()
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

    nonisolated static func delete(fileName: String) {
        guard let url = validatedURL(for: fileName) else {
            Log.persistence.error("Refused to delete unsafe managed file name: \(fileName, privacy: .private)")
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func trash(fileName: String) {
        guard let target = validatedURL(for: fileName) else {
            Log.persistence.error("Refused to trash unsafe managed file name: \(fileName, privacy: .private)")
            return
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: target.path(percentEncoded: false)) else { return }
        if trashesRemovedBooks,
           (try? fileManager.trashItem(at: target, resultingItemURL: nil)) != nil {
            return
        }
        do {
            try fileManager.removeItem(at: target)
        } catch {
            Log.persistence.error("Removing book file \(fileName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
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
        if let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxHTMLBytes {
            throw ImportError.sourceTooLarge
        }
        let sourceData = try Data(contentsOf: source, options: .mappedIfSafe)
        guard sourceData.count <= maxHTMLBytes else { throw ImportError.sourceTooLarge }
        guard let html = String(data: sourceData, encoding: .utf8)
                ?? String(data: sourceData, encoding: .isoLatin1) else { return nil }

        let imageTags = try NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
        let ns = html as NSString
        var replacements: [(NSRange, String)] = []
        var cachedURIs: [String: String] = [:]
        var totalImageBytes = 0

        for imageTag in imageTags.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: imageTag.range)
            guard let sourceAttribute = sourceAttribute(in: tag),
                  let uri = dataURI(
                for: sourceAttribute.value,
                relativeTo: source.deletingLastPathComponent(),
                cached: &cachedURIs,
                totalBytes: &totalImageBytes
            ) else { continue }
            var rewrittenTag = tag
            guard let valueRange = Range(sourceAttribute.range, in: rewrittenTag) else { continue }
            let replacement = sourceAttribute.quoted ? uri : "\"\(uri)\""
            rewrittenTag.replaceSubrange(valueRange, with: replacement)
            replacements.append((imageTag.range, rewrittenTag))
        }

        let portable = NSMutableString(string: html)
        for (range, replacement) in replacements.reversed() {
            portable.replaceCharacters(in: range, with: replacement)
        }
        let data = Data((portable as String).utf8)
        guard data.count <= maxPortableHTMLBytes else { throw ImportError.sourceTooLarge }
        return data
    }

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
