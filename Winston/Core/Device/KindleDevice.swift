import Foundation

nonisolated enum DeviceConnectionKind: String, Sendable {
    case mtp
    case massStorage
}

nonisolated struct DeviceInfo: Sendable, Equatable {
    var name: String
    var model: String
    var kind: DeviceConnectionKind
    var totalBytes: UInt64
    var freeBytes: UInt64

    var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }
}

nonisolated struct DeviceBook: Identifiable, Sendable, Hashable {
    var mtpItemID: UInt32?
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
        (fileName as NSString).deletingPathExtension.lowercased()
    }

    var sizeDisplay: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

nonisolated enum DeviceError: Error, LocalizedError {
    case notConnected
    case openFailed
    case listFailed
    case transferFailed(code: Int32)
    case deleteFailed(code: Int32)
    case fileMissing

    var errorDescription: String? {
        switch self {
        case .notConnected:               "No device connected"
        case .openFailed:                 "Could not open the device"
        case .listFailed:                 "Could not read the device contents"
        case .transferFailed(let code):   "Transfer failed (error \(code))"
        case .deleteFailed(let code):     "Delete failed (error \(code))"
        case .fileMissing:                "The file no longer exists"
        }
    }
}

nonisolated protocol KindleDeviceConnection: Sendable {
    func info() async throws -> DeviceInfo
    func listBooks() async throws -> [DeviceBook]
    func send(fileURL: URL, fileName: String, progress: @escaping @Sendable (Double) -> Void) async throws
    func copyBook(_ book: DeviceBook, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    func delete(_ book: DeviceBook) async throws
    func pushCoverThumbnail(_ fileURL: URL, named name: String) async throws
    func readClippingsText() async throws -> String?
    func isAlive() async -> Bool
    func disconnect() async
    func eject() async
    func removeStaleVariants(baseName: String, keeping fileName: String) async
    func removeAppleDoubleSidecars() async throws -> Int
}

nonisolated extension KindleDeviceConnection {
    func eject() async { await disconnect() }
    func removeStaleVariants(baseName: String, keeping fileName: String) async {}
}

nonisolated let deviceBookExtensions: Set<String> = ["epub", "mobi", "azw", "azw3", "pdf", "txt", "kfx"]
