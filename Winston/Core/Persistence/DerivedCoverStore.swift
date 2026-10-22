import CryptoKit
import Foundation

/// Identity for a discardable cover preview derived from one immutable asset
/// generation. It deliberately cannot be converted to `CoverOwner`: derived
/// bytes must never enter the authoritative cover namespace.
nonisolated struct DerivedCoverKey: Hashable, Sendable {
    static let currentExtractorVersion = 1

    let assetID: UUID
    let contentFingerprint: String
    let extractorVersion: Int
    let maxPixel: Int

    init(
        assetID: UUID,
        contentHash: String?,
        fileName: String,
        sizeBytes: Int64,
        extractorVersion: Int = currentExtractorVersion,
        maxPixel: Int
    ) {
        self.assetID = assetID
        let normalizedHash = contentHash?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        contentFingerprint = if let normalizedHash, !normalizedHash.isEmpty {
            normalizedHash
        } else {
            // Legacy assets may not have been hashed yet. Filename and size
            // keep their previews isolated until maintenance fills the hash.
            "legacy:\(fileName):\(sizeBytes)"
        }
        self.extractorVersion = extractorVersion
        self.maxPixel = max(1, maxPixel)
    }

    var storageFileName: String {
        let material = [
            assetID.uuidString.lowercased(),
            contentFingerprint,
            String(extractorVersion),
            String(maxPixel),
        ].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }
}

actor DerivedCoverStore {
    static let shared = DerivedCoverStore()

    private struct Entry {
        let sizeBytes: Int
        var lastAccess: Date
        var persistedAccess: Date
    }

    private let directory: URL
    private let byteLimit: Int
    private let countLimit: Int
    private var entries: [String: Entry] = [:]
    private var totalBytes = 0
    private var hasLoadedInventory = false

    init(
        directory: URL = AppPaths.derivedCoversDirectory,
        byteLimit: Int = 256 * 1_024 * 1_024,
        countLimit: Int = 20_000
    ) {
        self.directory = directory
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(0, countLimit)
    }

    func loadData(for key: DerivedCoverKey) -> Data? {
        loadInventoryIfNeeded()
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        didAccess(key)
        return data
    }

    /// Installs a cache entry without replacing an entry another extraction
    /// already published for the same immutable key.
    func installIfMissing(_ data: Data, for key: DerivedCoverKey) -> Bool {
        loadInventoryIfNeeded()
        let destination = url(for: key)
        if registerEntry(at: destination) {
            didAccess(key)
            trimIfNeeded(protecting: key.storageFileName)
            return true
        }
        // A preview that cannot fit remains usable in the memory cache. Do
        // not evict the whole disk cache trying to accommodate one payload.
        guard data.count <= byteLimit, countLimit > 0 else { return false }
        let temporary = directory.appending(
            path: ".\(key.storageFileName).\(UUID().uuidString).tmp"
        )
        do {
            try AppPaths.ensureDirectory(directory)
            try data.write(to: temporary, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporary) }
            // A hard link publishes the complete temporary file atomically and
            // fails with EEXIST instead of replacing another writer's result.
            try FileManager.default.linkItem(at: temporary, to: destination)
        } catch {
            // Another store may have won the atomic publication race.
        }
        guard registerEntry(at: destination) else { return false }
        didAccess(key)
        trimIfNeeded(protecting: key.storageFileName)
        return true
    }

    func fileURL(for key: DerivedCoverKey) -> URL {
        loadInventoryIfNeeded()
        return url(for: key)
    }

    /// Called after a successful decode. Persist recency at most once per
    /// minute per entry; scrolling back and forth must not rewrite metadata
    /// on every disk-cache hit. Modification dates survive app restarts.
    func didAccess(_ key: DerivedCoverKey) {
        let name = key.storageFileName
        guard var entry = entries[name] else { return }
        let now = Date.now
        entry.lastAccess = now
        if now.timeIntervalSince(entry.persistedAccess) >= 60 {
            do {
                try FileManager.default.setAttributes(
                    [.modificationDate: now],
                    ofItemAtPath: url(for: key).path(percentEncoded: false)
                )
                entry.persistedAccess = now
            } catch {
                // A cache hit remains valid if persisting recency fails.
            }
        }
        entries[name] = entry
    }

    private func loadInventoryIfNeeded() {
        guard !hasLoadedInventory else { return }
        // All filesystem work stays on this actor. Inventory is read once,
        // then maintained incrementally, never rescanned for each insertion.
        hasLoadedInventory = true
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where Self.isCacheFileName(file.lastPathComponent) {
            _ = registerEntry(at: file)
        }
        trimIfNeeded()
    }

    @discardableResult
    private func registerEntry(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey,
        ]), values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize else { return false }
        let name = url.lastPathComponent
        let modified = values.contentModificationDate ?? .distantPast
        totalBytes -= entries[name]?.sizeBytes ?? 0
        entries[name] = Entry(
            sizeBytes: size,
            lastAccess: max(entries[name]?.lastAccess ?? .distantPast, modified),
            persistedAccess: modified
        )
        totalBytes += size
        return true
    }

    private func trimIfNeeded(protecting protectedName: String? = nil) {
        guard totalBytes > byteLimit || entries.count > countLimit else { return }
        // Free ten percent at a time to amortize sorting and filesystem work
        // across subsequent writes instead of sorting on every insertion.
        let targetBytes = byteLimit - byteLimit / 10
        let targetCount = countLimit - countLimit / 10
        let oldest = entries.sorted {
            if $0.value.lastAccess != $1.value.lastAccess {
                return $0.value.lastAccess < $1.value.lastAccess
            }
            return $0.key < $1.key
        }
        for (name, entry) in oldest {
            guard totalBytes > targetBytes || entries.count > targetCount else { break }
            guard name != protectedName else { continue }
            let file = directory.appending(path: name)
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                // Already-removed files must not consume the accounting
                // budget; actual deletion failures remain tracked for retry.
                guard !FileManager.default.fileExists(
                    atPath: file.path(percentEncoded: false)
                ) else { continue }
            }
            entries.removeValue(forKey: name)
            totalBytes -= entry.sizeBytes
        }
    }

    private static func isCacheFileName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 68, name.hasSuffix(".jpg") else { return false }
        return bytes.prefix(64).allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func url(for key: DerivedCoverKey) -> URL {
        directory.appending(path: key.storageFileName)
    }
}
