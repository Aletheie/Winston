import CryptoKit
import Foundation
import PDFKit
import SwiftData

nonisolated enum ContentHasher {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
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

@MainActor
enum BookAssetMaintenance {
    private struct HashSnapshot: Sendable {
        let uuid: UUID
        let fileName: String
        let dateAdded: Date
    }

    @discardableResult
    static func backfillMissingHashes(
        context: ModelContext,
        hashFile: @escaping @Sendable (URL) async -> String? = { url in
            await Task.detached(priority: .utility) {
                try? ContentHasher.sha256(of: url)
            }.value
        }
    ) async -> Int {
        let assets = (try? context.fetch(FetchDescriptor<BookAsset>())) ?? []
        let snapshots = assets.filter { $0.contentHash == nil }.map {
            HashSnapshot(uuid: $0.uuid, fileName: $0.fileName, dateAdded: $0.dateAdded)
        }
        guard !snapshots.isEmpty else { return 0 }

        var processed = 0
        for snapshot in snapshots {
            guard !Task.isCancelled else { break }
            let result = await hashFile(BookFileStore.url(for: snapshot.fileName))
            guard let result else { continue }
            let uuid = snapshot.uuid
            let descriptor = FetchDescriptor<BookAsset>(predicate: #Predicate { $0.uuid == uuid })
            guard let asset = try? context.fetch(descriptor).first,
                  asset.contentHash == nil,
                  asset.fileName == snapshot.fileName,
                  asset.dateAdded == snapshot.dateAdded else { continue }
            asset.contentHash = result
            processed += 1
            if processed.isMultiple(of: 50) { context.saveQuietly() }
        }
        if processed > 0 { context.saveQuietly() }
        return processed
    }
}
