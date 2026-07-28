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

    private let directory: URL

    init(directory: URL = AppPaths.derivedCoversDirectory) {
        self.directory = directory
    }

    func loadData(for key: DerivedCoverKey) -> Data? {
        try? Data(contentsOf: url(for: key))
    }

    /// Installs a cache entry without replacing an entry another extraction
    /// already published for the same immutable key.
    func installIfMissing(_ data: Data, for key: DerivedCoverKey) -> Bool {
        let destination = url(for: key)
        if FileManager.default.fileExists(
            atPath: destination.path(percentEncoded: false)
        ) {
            return true
        }
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
            return true
        } catch {
            return FileManager.default.fileExists(
                atPath: destination.path(percentEncoded: false)
            )
        }
    }

    func fileURL(for key: DerivedCoverKey) -> URL {
        url(for: key)
    }

    private func url(for key: DerivedCoverKey) -> URL {
        directory.appending(path: key.storageFileName)
    }
}
