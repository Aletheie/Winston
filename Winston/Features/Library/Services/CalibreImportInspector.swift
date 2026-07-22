import AppKit
import Foundation

nonisolated struct CalibreImportInspectedSource: Sendable, Equatable {
    let assetID: UUID
    let url: URL
    let format: String
}

nonisolated struct CalibreImportInspection: Sendable, Equatable {
    let calibreID: Int64
    let sources: [CalibreImportInspectedSource]
    let coverData: Data?
    let unsafeRejectedSources: Int
}

nonisolated enum CalibreImportInspector {
    /// Revalidates source identities and prepares covers off the main actor.
    /// The small bound avoids saturating slow external media.
    @concurrent
    static func inspect(
        _ items: [CalibreImportManifest.Item],
        maximumConcurrentTasks: Int
    ) async -> [Int64: CalibreImportInspection] {
        guard !items.isEmpty else { return [:] }
        let limit = max(1, min(maximumConcurrentTasks, items.count))
        return await withTaskGroup(
            of: CalibreImportInspection.self,
            returning: [Int64: CalibreImportInspection].self
        ) { group in
            var nextIndex = 0
            for _ in 0..<limit {
                let item = items[nextIndex]
                group.addTask { await inspect(item) }
                nextIndex += 1
            }

            var results: [Int64: CalibreImportInspection] = [:]
            while let inspection = await group.next() {
                results[inspection.calibreID] = inspection
                if nextIndex < items.count, !Task.isCancelled {
                    let item = items[nextIndex]
                    group.addTask { await inspect(item) }
                    nextIndex += 1
                }
            }
            return results
        }
    }

    @concurrent
    private static func inspect(
        _ item: CalibreImportManifest.Item
    ) async -> CalibreImportInspection {
        let sourceFiles = [item.book.sourceFile] + item.book.additionalSourceFiles
        var sources: [CalibreImportInspectedSource] = []
        var unsafeRejectedSources = 0
        for (index, source) in sourceFiles.enumerated() {
            guard !Task.isCancelled, item.assetIDs.indices.contains(index) else { break }
            do {
                sources.append(CalibreImportInspectedSource(
                    assetID: item.assetIDs[index],
                    url: try source.revalidatedURL(),
                    format: source.declaredFormat
                ))
            } catch let error as CalibrePathError {
                if error.isSecurityViolation { unsafeRejectedSources += 1 }
            } catch {
                continue
            }
        }

        var coverData: Data?
        if !Task.isCancelled, let cover = item.book.coverSourceFile {
            do {
                let url = try cover.revalidatedURL()
                if let image = NSImage(contentsOf: url) {
                    coverData = ImageTranscoder.jpegData(from: image)
                }
            } catch let error as CalibrePathError {
                if error.isSecurityViolation { unsafeRejectedSources += 1 }
            } catch {
                coverData = nil
            }
        }

        return CalibreImportInspection(
            calibreID: item.calibreID,
            sources: sources,
            coverData: coverData,
            unsafeRejectedSources: unsafeRejectedSources
        )
    }
}
