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
            await Task.detached(priority: .background) {
                try? ContentHasher.sha256(of: url)
            }.value
        }
    ) async -> Int {
        let assets = (try? context.fetch(FetchDescriptor<BookAsset>())) ?? []
        let snapshots = assets.filter { $0.contentHash == nil }.map {
            HashSnapshot(uuid: $0.uuid, fileName: $0.fileName, dateAdded: $0.dateAdded)
        }
        guard !snapshots.isEmpty else { return 0 }

        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.uuid, $0) })
        var processed = 0
        // Hash and persist in chunks so quitting mid-backfill keeps the work done so far.
        for chunkStart in stride(from: 0, to: snapshots.count, by: 50) {
            guard !Task.isCancelled else { break }
            let chunk = Array(snapshots[chunkStart ..< min(chunkStart + 50, snapshots.count)])
            let results = await hashSnapshots(chunk, hashFile: hashFile)
            var chunkProcessed = 0
            for result in results {
                let snapshot = result.snapshot
                guard let asset = assetsByID[snapshot.uuid],
                      asset.modelContext != nil,
                      asset.contentHash == nil,
                      asset.fileName == snapshot.fileName,
                      asset.dateAdded == snapshot.dateAdded else { continue }
                asset.contentHash = result.hash
                chunkProcessed += 1
            }
            if chunkProcessed > 0 { context.saveQuietly() }
            processed += chunkProcessed
        }
        return processed
    }

    @concurrent
    private static func hashSnapshots(
        _ snapshots: [HashSnapshot],
        hashFile: @escaping @Sendable (URL) async -> String?
    ) async -> [(snapshot: HashSnapshot, hash: String)] {
        let concurrency = min(2, snapshots.count)
        guard concurrency > 0 else { return [] }
        return await withTaskGroup(
            of: (HashSnapshot, String?).self,
            returning: [(snapshot: HashSnapshot, hash: String)].self
        ) { group in
            var nextIndex = 0
            var results: [(snapshot: HashSnapshot, hash: String)] = []
            results.reserveCapacity(snapshots.count)

            while nextIndex < concurrency {
                let snapshot = snapshots[nextIndex]
                group.addTask(priority: .background) {
                    (snapshot, await hashFile(BookFileStore.url(for: snapshot.fileName)))
                }
                nextIndex += 1
            }
            while let (snapshot, hash) = await group.next() {
                if let hash { results.append((snapshot, hash)) }
                guard nextIndex < snapshots.count, !Task.isCancelled else { continue }
                let pending = snapshots[nextIndex]
                group.addTask(priority: .background) {
                    (pending, await hashFile(BookFileStore.url(for: pending.fileName)))
                }
                nextIndex += 1
            }
            return results
        }
    }
}
