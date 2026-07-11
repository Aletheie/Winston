import Foundation

extension Notification.Name {
    static let watchFolderChanged = Notification.Name("cz.annajung.Winston.watchFolderChanged")
}

final class FolderWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    func start(path: String) {
        stop()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd
        let queue = DispatchQueue(label: "cz.annajung.Winston.folderwatch")
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue
        )
        source.setEventHandler {
            NotificationCenter.default.post(name: .watchFolderChanged, object: nil)
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }

    nonisolated static func ebookFiles(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return contents.filter { libraryEbookExtensions.contains($0.pathExtension.lowercased()) }
    }
}

actor WatchFolderStabilityTracker {
    struct Fingerprint: Hashable, Sendable {
        let size: Int64
        let modificationDate: Date
    }

    struct ScanResult: Sendable, Equatable {
        let ready: [URL]
        let needsPolling: Bool
    }

    private struct Candidate {
        var fingerprint: Fingerprint
        var unchangedIntervals: Int
        var lastObservation: Date
        var delivered: Fingerprint?
    }

    private var candidates: [URL: Candidate] = [:]
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 0.9) {
        self.minimumInterval = minimumInterval
    }

    func reset() {
        candidates.removeAll()
    }

    func scan(directory: URL, now: Date = .now) -> ScanResult {
        observe(Self.fingerprints(in: directory), now: now)
    }

    func observe(_ fingerprints: [URL: Fingerprint], now: Date) -> ScanResult {
        candidates = candidates.filter { fingerprints[$0.key] != nil }
        var ready: [URL] = []
        var needsPolling = false

        for (url, fingerprint) in fingerprints {
            var candidate = candidates[url] ?? Candidate(
                fingerprint: fingerprint,
                unchangedIntervals: 0,
                lastObservation: now,
                delivered: nil
            )

            if candidate.fingerprint != fingerprint {
                candidate.fingerprint = fingerprint
                candidate.unchangedIntervals = 0
                candidate.lastObservation = now
            } else if now.timeIntervalSince(candidate.lastObservation) >= minimumInterval {
                candidate.unchangedIntervals += 1
                candidate.lastObservation = now
            }

            if fingerprint.size > 0,
               candidate.unchangedIntervals >= 2,
               candidate.delivered != fingerprint {
                ready.append(url)
                candidate.delivered = fingerprint
            }
            if candidate.delivered != fingerprint { needsPolling = true }
            candidates[url] = candidate
        }

        return ScanResult(
            ready: ready.sorted { $0.path < $1.path },
            needsPolling: needsPolling
        )
    }

    private nonisolated static func fingerprints(in directory: URL) -> [URL: Fingerprint] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var result: [URL: Fingerprint] = [:]
        for url in FolderWatcher.ebookFiles(in: directory) {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modificationDate = values.contentModificationDate else { continue }
            result[url] = Fingerprint(size: Int64(size), modificationDate: modificationDate)
        }
        return result
    }
}
