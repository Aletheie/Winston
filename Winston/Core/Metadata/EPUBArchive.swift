import Foundation
import ZIPFoundation
import os

// One instance = one open zip. Conversion opens the archive once and threads it
// through the whole pipeline (pinned by ConversionPipelineTests).
nonisolated final class EPUBArchive {
    private struct ExtractionBudget {
        var paths: Set<String> = []
        var totalBytes: UInt64 = 0
        var rejectedEntry = false
    }

    private static let maxEntryBytes: UInt64 = 64 * 1_024 * 1_024
    private static let maxArchiveBytes: UInt64 = 256 * 1_024 * 1_024
    private static let maxCompressionRatio: UInt64 = 200

    private let archive: Archive
    private let url: URL
    private let extractionBudget = OSAllocatedUnfairLock(initialState: ExtractionBudget())

    var rejectedUnsafeEntry: Bool {
        extractionBudget.withLock { $0.rejectedEntry }
    }

    private static let openCounts = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])
    static func openCount(for url: URL) -> Int {
        openCounts.withLock { $0[url.path] ?? 0 }
    }

    init(url: URL) throws {
        self.archive = try Archive(url: url, accessMode: .read)
        self.url = url
        Self.openCounts.withLock { $0[url.path, default: 0] += 1 }
    }

    func entry(_ path: String) -> Data? {
        if let data = rawEntry(path) { return data }
        if let decoded = path.removingPercentEncoding, decoded != path {
            return rawEntry(decoded)
        }
        return nil
    }

    private func rawEntry(_ path: String) -> Data? {
        guard let entry = archive[path] else { return nil }
        guard reserve(entry, path: path) else {
            Log.metadata.error("Refusing oversized EPUB entry \(path, privacy: .public) in \(self.url.lastPathComponent, privacy: .public)")
            return nil
        }
        var data = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                data.append(chunk)
            }
        } catch {
            release(size: entry.uncompressedSize, path: path)
            Log.metadata.error("Extracting \(path, privacy: .public) from \(self.url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return data.isEmpty ? nil : data
    }

    private func reserve(_ entry: Entry, path: String) -> Bool {
        let size = entry.uncompressedSize
        let compressed = entry.compressedSize
        guard size <= Self.maxEntryBytes,
              size == 0 || (compressed > 0 && (
                  compressed >= size || size <= compressed * Self.maxCompressionRatio
              )) else {
            extractionBudget.withLock { $0.rejectedEntry = true }
            return false
        }
        return extractionBudget.withLock { budget in
            if budget.paths.contains(path) { return true }
            guard budget.totalBytes <= Self.maxArchiveBytes - size else {
                budget.rejectedEntry = true
                return false
            }
            budget.paths.insert(path)
            budget.totalBytes += size
            return true
        }
    }

    private func release(size: UInt64, path: String) {
        extractionBudget.withLock { budget in
            guard budget.paths.remove(path) != nil else { return }
            budget.totalBytes -= size
        }
    }

    static func entry(_ path: String, in zipURL: URL) -> Data? {
        guard let archive = try? EPUBArchive(url: zipURL) else {
            Log.metadata.error("Couldn't open \(zipURL.lastPathComponent, privacy: .public) as a zip archive")
            return nil
        }
        return archive.entry(path)
    }
}
