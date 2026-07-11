import Foundation
import ZIPFoundation
import os

// One instance = one open zip. Conversion opens the archive once and threads it
// through the whole pipeline (pinned by ConversionPipelineTests).
nonisolated final class EPUBArchive {
    private let archive: Archive
    private let url: URL

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
        var data = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                data.append(chunk)
            }
        } catch {
            Log.metadata.error("Extracting \(path, privacy: .public) from \(self.url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return data.isEmpty ? nil : data
    }

    static func entry(_ path: String, in zipURL: URL) -> Data? {
        guard let archive = try? EPUBArchive(url: zipURL) else {
            Log.metadata.error("Couldn't open \(zipURL.lastPathComponent, privacy: .public) as a zip archive")
            return nil
        }
        return archive.entry(path)
    }
}
