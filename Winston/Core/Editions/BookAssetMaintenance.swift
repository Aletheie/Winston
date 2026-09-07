import CryptoKit
import Foundation
import PDFKit

nonisolated enum ContentHasher {
    static func sha256(of url: URL) throws -> String {
        try hash(url, checkingCancellation: false)
    }

    static func sha256Cancellable(of url: URL) throws -> String {
        try hash(url, checkingCancellation: true)
    }

    private static func hash(_ url: URL, checkingCancellation: Bool) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if checkingCancellation { try Task.checkCancellation() }
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum BookAssetValidator {
    static func validate(url: URL) -> AssetValidation {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return .missing }
        switch url.pathExtension.lowercased() {
        case "epub":
            guard let archive = try? EPUBArchive(url: url),
                  let container = archive.entry("META-INF/container.xml"),
                  let opf = MetadataExtractor.parseOPFPath(from: container),
                  archive.entry(opf) != nil
            else { return .corrupt }
            return .ok
        case "pdf":
            return PDFDocument(url: url) == nil ? .corrupt : .ok
        case "mobi", "azw", "azw3":
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .corrupt }
            defer { try? handle.close() }
            guard let header = try? handle.read(upToCount: 80), header.count >= 68 else { return .corrupt }
            return String(data: header[60..<68], encoding: .ascii) == "BOOKMOBI" ? .ok : .corrupt
        default:
            return .ok
        }
    }
}
