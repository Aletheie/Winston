import Foundation
@testable import Winston

actor FakeKindleConnection: KindleDeviceConnection {
    enum UncertainTransferMode: Sendable, Equatable {
        case none
        case committedThenThrows
        case partialThenThrows
    }

    struct SentFile: Sendable, Equatable {
        var fileName: String
        var byteCount: Int
    }

    private(set) var sentFiles: [SentFile] = []
    private(set) var pushedThumbnails: [String] = []
    private(set) var staleVariantCalls: [[String]] = []
    private(set) var deletedFileNames: [String] = []
    private(set) var ejected = false
    private(set) var transferAttempts = 0

    private var alive = true
    private var failEject = false
    private var failCopies = false
    private var blockEject = false
    private var ejectStarted = false
    private var ejectStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedEject: CheckedContinuation<Void, Never>?
    private var failSends = false
    private var uncertainTransferMode: UncertainTransferMode = .none
    private var failCleanup = false
    private var failThumbnails = false
    private var blockSends = false
    private var blockSendsCooperatively = false
    private var sendStarted = false
    private var sendStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedSend: CheckedContinuation<Void, Never>?
    private var books: [DeviceBook] = []

    func setAlive(_ value: Bool) { alive = value }
    func setFailEject(_ value: Bool) { failEject = value }
    func setFailCopies(_ value: Bool) { failCopies = value }
    func setBlockEject(_ value: Bool) { blockEject = value }
    func setFailSends(_ value: Bool) { failSends = value }
    func setUncertainTransferMode(_ value: UncertainTransferMode) {
        uncertainTransferMode = value
    }
    func setFailCleanup(_ value: Bool) { failCleanup = value }
    func setFailThumbnails(_ value: Bool) { failThumbnails = value }
    func setBlockSends(_ value: Bool) { blockSends = value }
    func setBlockSendsCooperatively(_ value: Bool) { blockSendsCooperatively = value }
    func setBooks(_ value: [DeviceBook]) { books = value }

    func waitUntilSendStarts() async {
        if sendStarted { return }
        await withCheckedContinuation { sendStartWaiters.append($0) }
    }

    func waitUntilEjectStarts() async {
        if ejectStarted { return }
        await withCheckedContinuation { ejectStartWaiters.append($0) }
    }

    func releaseBlockedEject() {
        blockEject = false
        blockedEject?.resume()
        blockedEject = nil
    }

    func releaseBlockedSend() {
        blockSends = false
        blockedSend?.resume()
        blockedSend = nil
    }

    static let fakeInfo = DeviceInfo(name: "Fake Kindle", model: "Test", kind: .massStorage,
                                     totalBytes: 8_000_000_000, freeBytes: 6_000_000_000)

    // MARK: - KindleDeviceConnection

    func info() async throws -> DeviceInfo { Self.fakeInfo }

    func listBooks() async throws -> [DeviceBook] { books }

    func transfer(
        _ request: DeviceByteTransfer,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DeviceTransferResult {
        sendStarted = true
        let waiters = sendStartWaiters
        sendStartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if blockSendsCooperatively {
            try await Task.sleep(for: .seconds(60))
        }
        if blockSends {
            await withCheckedContinuation { blockedSend = $0 }
        }
        transferAttempts += 1
        guard !failSends else { throw DeviceError.transferFailed(code: -1) }
        let bytes = (try? Data(contentsOf: request.sourceURL))?.count ?? 0
        guard UInt64(bytes) == request.expectedByteCount else {
            throw DeviceError.fileMissing
        }
        progress(1)
        let fileName = request.destination.fileName
        if uncertainTransferMode == .partialThenThrows {
            books.append(DeviceBook(
                path: request.destination.relativePath,
                fileName: fileName,
                sizeBytes: UInt64(bytes / 2)
            ))
            throw DeviceError.transferFailed(code: -6)
        }
        sentFiles.append(SentFile(fileName: fileName, byteCount: bytes))
        books.append(DeviceBook(
            path: request.destination.relativePath,
            fileName: fileName,
            sizeBytes: UInt64(bytes)
        ))
        if uncertainTransferMode == .committedThenThrows {
            throw DeviceError.transferFailed(code: -7)
        }
        return DeviceTransferResult(
            destination: request.destination,
            bytesTransferred: UInt64(bytes),
            transportIdentifier: "fake-\(sentFiles.count)"
        )
    }

    func copyBook(_ book: DeviceBook, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !failCopies else { throw DeviceError.transferFailed(code: -5) }
        try Data("fake book".utf8).write(to: destination)
        progress(1)
    }

    func delete(_ book: DeviceBook) async throws {
        deletedFileNames.append(book.fileName)
        books.removeAll { $0.id == book.id }
    }

    func pushCoverThumbnail(_ fileURL: URL, named name: String) async throws {
        guard !failThumbnails else { throw DeviceError.transferFailed(code: -3) }
        pushedThumbnails.append(name)
    }

    func readClippingsText() async throws -> String? { nil }

    func isAlive() async -> Bool { alive }

    func disconnect() async {}

    func eject() async throws {
        ejected = true
        ejectStarted = true
        let waiters = ejectStartWaiters
        ejectStartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if blockEject {
            await withCheckedContinuation { blockedEject = $0 }
        }
        if failEject {
            throw CocoaError(.fileWriteVolumeReadOnly)
        }
        alive = false
    }

    func removeStaleVariants(baseName: String, keeping fileName: String) async throws {
        guard !failCleanup else { throw DeviceError.transferFailed(code: -4) }
        staleVariantCalls.append([baseName, fileName])
    }

    func removeAppleDoubleSidecars() async throws -> Int { 0 }
}
