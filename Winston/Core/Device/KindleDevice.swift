import Foundation

nonisolated enum DeviceConnectionKind: String, Sendable {
    case mtp
    case massStorage
}

nonisolated struct DeviceInfo: Sendable, Equatable {
    var identifier: String
    var name: String
    var model: String
    var kind: DeviceConnectionKind
    var totalBytes: UInt64
    var freeBytes: UInt64

    init(
        name: String,
        model: String,
        kind: DeviceConnectionKind,
        totalBytes: UInt64,
        freeBytes: UInt64,
        identifier: String? = nil
    ) {
        self.name = name
        self.model = model
        self.kind = kind
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.identifier = identifier ?? Self.fallbackIdentifier(
            name: name,
            model: model,
            kind: kind,
            totalBytes: totalBytes
        )
    }

    var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }

    private static func fallbackIdentifier(
        name: String,
        model: String,
        kind: DeviceConnectionKind,
        totalBytes: UInt64
    ) -> String {
        let parts = [kind.rawValue, model, name, String(totalBytes)]
        return parts
            .joined(separator: "|")
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }
}

nonisolated struct DeviceBook: Identifiable, Sendable, Hashable {
    var mtpItemID: UInt32?
    /// Mass-storage paths are mount-root-relative (for example `documents/book.mobi`).
    /// Absolute device paths must never cross the mounted-volume boundary.
    var path: String?
    var fileName: String
    var sizeBytes: UInt64
    var modifiedDate: Date? = nil

    var id: String { mtpItemID.map { "mtp-\($0)" } ?? "fs-\(path ?? fileName)" }
    var format: String { (fileName as NSString).pathExtension.uppercased() }

    var displayName: String {
        Book.cleanFilename((fileName as NSString).deletingPathExtension)
    }

    var matchKey: String {
        DevicePathAllocator.rawMatchKey(for: fileName)
    }

    var legacyMatchKey: String {
        DevicePathAllocator.legacyMatchKey(for: fileName)
    }

    var sizeDisplay: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

/// A validated, allocator-owned path in the device documents namespace.
/// Transport implementations receive this value instead of catalog identity.
nonisolated struct DeviceTransferPath: Sendable, Equatable, Hashable {
    let fileName: String

    var relativePath: String { "documents/\(fileName)" }

    init?(fileName: String) {
        guard let leaf = ManagedLeafName(rawValue: fileName) else { return nil }
        self.fileName = leaf.rawValue
    }
}

/// The complete input understood by a device transport: immutable bytes and
/// their already-allocated destination. It contains no book or edition identity.
nonisolated struct DeviceByteTransfer: Sendable, Equatable {
    let sourceURL: URL
    let destination: DeviceTransferPath
    let expectedByteCount: UInt64
}

/// Purely technical transport output. Catalog receipts are assembled above this
/// boundary from this result and the exact immutable transfer artifact.
nonisolated struct DeviceTransferResult: Sendable, Equatable {
    let destination: DeviceTransferPath
    let bytesTransferred: UInt64
    let transportIdentifier: String?
}

nonisolated struct DeviceInventorySnapshot: Sendable, Equatable {
    let generation: Int
    let info: DeviceInfo
    let books: [DeviceBook]

    init(
        generation: Int = 0,
        info: DeviceInfo,
        books: [DeviceBook]
    ) {
        self.generation = generation
        self.info = info
        self.books = books
    }
}

nonisolated struct DeviceInventoryDelta: Sendable, Equatable {
    let fromGeneration: Int
    let toGeneration: Int
    let inserted: [DeviceBook]
    let updated: [DeviceBook]
    let removed: [DeviceBook]
    let changedMatchKeys: Set<String>

    init(
        fromGeneration: Int,
        toGeneration: Int,
        inserted: [DeviceBook],
        updated: [DeviceBook],
        removed: [DeviceBook],
        changedMatchKeys: Set<String>? = nil
    ) {
        self.fromGeneration = fromGeneration
        self.toGeneration = toGeneration
        self.inserted = inserted
        self.updated = updated
        self.removed = removed
        self.changedMatchKeys = changedMatchKeys ?? Set(
            inserted.map(\.matchKey)
                + updated.map(\.matchKey)
                + removed.map(\.matchKey)
        )
    }

    static let empty = DeviceInventoryDelta(
        fromGeneration: 0,
        toGeneration: 0,
        inserted: [],
        updated: [],
        removed: [],
        changedMatchKeys: []
    )

    var isEmpty: Bool {
        fromGeneration == toGeneration
            && inserted.isEmpty
            && updated.isEmpty
            && removed.isEmpty
    }

}

nonisolated enum DeviceError: Error, LocalizedError, Equatable {
    case notConnected
    case openFailed
    case listFailed
    case transferFailed(code: Int32)
    case deleteFailed(code: Int32)
    case fileMissing
    case invalidFileName
    case unsafePath

    var errorDescription: String? {
        localizedDescription()
    }

    func localizedDescription(locale: Locale? = nil) -> String {
        let bundle = locale.map(WinstonLocalization.bundle(for:))
            ?? WinstonLocalization.bundle
        let locale = locale ?? .current
        return switch self {
        case .notConnected:
            String(
                localized: "No device connected",
                bundle: bundle,
                locale: locale
            )
        case .openFailed:
            String(
                localized: "Could not open the device",
                bundle: bundle,
                locale: locale
            )
        case .listFailed:
            String(
                localized: "Could not read the device contents",
                bundle: bundle,
                locale: locale
            )
        case .transferFailed(let code):
            String(
                localized: "Transfer failed (error \(code))",
                bundle: bundle,
                locale: locale
            )
        case .deleteFailed(let code):
            String(
                localized: "Delete failed (error \(code))",
                bundle: bundle,
                locale: locale
            )
        case .fileMissing:
            String(
                localized: "The file no longer exists",
                bundle: bundle,
                locale: locale
            )
        case .invalidFileName:
            String(
                localized: "The destination file name is invalid",
                bundle: bundle,
                locale: locale
            )
        case .unsafePath:
            String(
                localized: "The device path violates the mounted-volume boundary",
                bundle: bundle,
                locale: locale
            )
        }
    }
}

nonisolated protocol KindleDeviceConnection: AnyObject, Sendable {
    func info() async throws -> DeviceInfo
    func listBooks() async throws -> [DeviceBook]
    func transfer(
        _ request: DeviceByteTransfer,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DeviceTransferResult
    func copyBook(_ book: DeviceBook, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    func delete(_ book: DeviceBook) async throws
    func pushCoverThumbnail(_ fileURL: URL, named name: String) async throws
    func readClippingsText() async throws -> String?
    func isAlive() async -> Bool
    func disconnect() async
    func eject() async throws
    func removeStaleVariants(baseName: String, keeping fileName: String) async throws
    func removeAppleDoubleSidecars() async throws -> Int
}

nonisolated extension KindleDeviceConnection {
    func eject() async throws { await disconnect() }
    func removeStaleVariants(baseName: String, keeping fileName: String) async throws {}

    /// Compatibility adapter for callers that already own a leaf name. New send
    /// flows allocate `DeviceTransferPath` in `TransferPlanner`.
    func send(
        fileURL: URL,
        fileName: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let destination = DeviceTransferPath(fileName: fileName),
              let values = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
              ]),
              values.isRegularFile == true else {
            throw DeviceError.invalidFileName
        }
        _ = try await transfer(
            DeviceByteTransfer(
                sourceURL: fileURL,
                destination: destination,
                expectedByteCount: UInt64(max(0, values.fileSize ?? 0))
            ),
            progress: progress
        )
    }
}

nonisolated let deviceBookExtensions: Set<String> = ["epub", "mobi", "azw", "azw3", "pdf", "txt", "kfx"]
