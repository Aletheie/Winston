import CryptoKit
import Foundation
import PDFKit
import SwiftData

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

@MainActor
enum BookAssetMaintenance {
    private struct CompletedHash {
        let job: CatalogAnalysisJob<CatalogAssetInspectionProposal<String>>
        let proposal: CatalogAssetInspectionProposal<String>
    }

    @discardableResult
    static func backfillMissingHashes(
        context: ModelContext,
        mutations: CatalogMutationService? = nil,
        hashFile: @escaping @Sendable (URL) async -> String? = { url in
            try? ContentHasher.sha256Cancellable(of: url)
        }
    ) async -> Int {
        let resolvedMutations = mutations ?? CatalogMutationService(modelContext: context)
        let coordinator = resolvedMutations.analysisCoordinator
        let assets = (try? context.fetch(FetchDescriptor<BookAsset>())) ?? []
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        let snapshots = assets.compactMap { asset -> BookAnalysisSnapshot? in
            guard asset.contentHash == nil else { return nil }
            let book = asset.book ?? books.first { book in
                book.assets.contains(where: { $0.uuid == asset.uuid })
            }
            guard let book else { return nil }
            return BookAnalysisSnapshot(book: book, sourceAsset: asset)
        }
        guard !snapshots.isEmpty else { return 0 }

        var processed = 0
        // Hash and persist in chunks so quitting mid-backfill keeps the work done so far.
        for chunkStart in stride(from: 0, to: snapshots.count, by: 50) {
            guard !Task.isCancelled else { break }
            let chunk = Array(snapshots[chunkStart ..< min(chunkStart + 50, snapshots.count)])
            var completed: [CompletedHash] = []
            for pairStart in stride(from: 0, to: chunk.count, by: 2) {
                let pair = chunk[pairStart ..< min(pairStart + 2, chunk.count)]
                let jobs: [CatalogAnalysisJob<CatalogAssetInspectionProposal<String>>] = pair.compactMap { snapshot in
                    guard let assetID = snapshot.assetID else { return nil }
                    return coordinator.start(
                        snapshot: snapshot,
                        kind: .assetHash(assetID: assetID)
                    ) { snapshot in
                        await CatalogAnalysisWorker.inspect(snapshot: snapshot, operation: hashFile)
                    }
                }
                for job in jobs {
                    if let proposal = await coordinator.value(for: job) {
                        completed.append(CompletedHash(job: job, proposal: proposal))
                    } else {
                        coordinator.finish(job.ticket)
                    }
                }
            }

            if Task.isCancelled {
                completed.forEach { coordinator.finish($0.job.ticket) }
                break
            }

            var valid: [(BookAnalysisSnapshot, CatalogAssetInspectionProposal<String>, BookAsset)] = []
            for result in completed {
                let snapshot = result.job.snapshot
                guard coordinator.isCurrent(result.job.ticket),
                      result.proposal.sourceIsCurrent(for: snapshot),
                      let book = try? resolvedMutations.book(id: snapshot.bookID),
                      snapshot.matches(book),
                      let assetID = snapshot.assetID,
                      let asset = book.assets.first(where: { $0.uuid == assetID }),
                      asset.contentHash == nil else { continue }
                valid.append((snapshot, result.proposal, asset))
            }

            if !valid.isEmpty {
                let preimages = valid.map { CatalogBookAssetPreimage($0.2) }
                let bookIDs = Set(valid.map { $0.0.bookID })
                do {
                    try resolvedMutations.commit(
                        .applyAnalysisBatch(
                            bookIDs: Array(bookIDs),
                            kind: .assetHash(assetID: valid[0].2.uuid)
                        ),
                        affectedBookIDs: bookIDs,
                        revertingOnFailure: { preimages.forEach { $0.restore() } }
                    ) {
                        for (snapshot, proposal, _) in valid {
                            let book = try resolvedMutations.book(id: snapshot.bookID)
                            guard snapshot.matches(book),
                                  proposal.sourceIsCurrent(for: snapshot),
                                  let assetID = snapshot.assetID,
                                  let asset = book.assets.first(where: { $0.uuid == assetID }),
                                  asset.contentHash == nil else {
                                throw CatalogMutationError.staleAnalysis
                            }
                            asset.contentHash = proposal.value
                        }
                    }
                    processed += valid.count
                } catch {
                    // Best-effort startup maintenance; every asset preimage was restored.
                }
            }
            completed.forEach { coordinator.finish($0.job.ticket) }
        }
        return processed
    }
}
