import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class TransferQueue {
    private struct SendRequest: Sendable {
        let uuid: UUID
        let displayName: String
        let sourceURL: URL
        let originalFileName: String
        let format: String
        let drmProtected: Bool
    }

    enum Direction: Sendable, Equatable {
        case toDevice
        case fromDevice
    }

    enum Stage: Sendable, Equatable {
        case waiting
        case converting
        case transferring
        case done
        case failed
    }

    struct Item: Identifiable, Sendable, Equatable {
        let id = UUID()
        var displayName: String
        var direction: Direction
        var stage: Stage = .waiting
        var progress: Double = 0
        var failed: Bool { stage == .failed }
    }

    private(set) var items: [Item] = []
    private(set) var isTransferring = false
    private(set) var lastError: String?

    private let toasts: ToastCenter
    private var sendTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?

    init(toasts: ToastCenter) {
        self.toasts = toasts
    }

    func beginSend(books: [Book], via monitor: DeviceMonitor) {
        guard !isTransferring else { return }
        let requests = books.map(Self.makeRequest)
        clearTask?.cancel()
        clearTask = nil
        isTransferring = true
        sendTask = Task { [weak self] in
            await self?.performSend(requests: requests, via: monitor)
        }
    }

    func cancel() {
        guard isTransferring else { return }
        sendTask?.cancel()
        for index in items.indices where items[index].stage != .done {
            items[index].stage = .failed
        }
    }

    var activeItem: Item? {
        items.first { $0.stage == .waiting || $0.stage == .converting || $0.stage == .transferring }
    }

    var failedCount: Int {
        items.filter { $0.stage == .failed }.count
    }

    var overallProgress: Double {
        guard !items.isEmpty else { return 0 }
        return items.reduce(0) { $0 + $1.progress } / Double(items.count)
    }

    // MARK: - Sending

    func send(books: [Book], via monitor: DeviceMonitor) async {
        guard !isTransferring else { return }
        let requests = books.map(Self.makeRequest)
        clearTask?.cancel()
        clearTask = nil
        isTransferring = true
        await performSend(requests: requests, via: monitor)
    }

    private func performSend(requests: [SendRequest], via monitor: DeviceMonitor) async {
        var pollingSuspended = false
        defer {
            if pollingSuspended { monitor.resumePolling() }
            isTransferring = false
            sendTask = nil
            scheduleClear()
        }

        guard let connection = monitor.connection else {
            lastError = "Device disconnected"
            return
        }
        Log.device.info("Send queue: \(requests.count) book(s)")

        lastError = nil
        monitor.suspendPolling()
        pollingSuspended = true
        items = requests.map { Item(displayName: $0.displayName, direction: .toDevice) }

        for (index, request) in requests.enumerated() {
            if Task.isCancelled { break }
            let itemID = items[index].id

            guard await connection.isAlive() else {
                lastError = "Device disconnected"
                for i in index ..< items.count { markFailed(items[i].id) }
                await monitor.disconnect()
                break
            }
            await transfer(request, itemID: itemID, connection: connection)
        }

        if Task.isCancelled {
            for item in items where item.stage != .done { markFailed(item.id) }
        }
        let sent = items.filter { $0.stage == .done }.count
        Log.device.notice("Send queue finished: \(sent) sent, \(self.failedCount) failed")
        if !Task.isCancelled, failedCount > 0 {
            toasts.error(String(localized: "Some transfers failed (\(failedCount))."))
        } else if !Task.isCancelled, sent > 0 {
            toasts.success(String(localized: "Sent \(sent) to Kindle."))
        }
        if monitor.isConnected {
            await monitor.refreshBooks()
            await monitor.refreshInfo()
        }
    }

    private func transfer(
        _ request: SendRequest,
        itemID: UUID,
        connection: any KindleDeviceConnection
    ) async {
        if request.drmProtected {
            lastError = "DRM-protected"
            toasts.error(String(localized: "\u{201C}\(request.displayName)\u{201D} is DRM\u{2011}protected and can't be sent."))
            markFailed(itemID)
            return
        }

        var sourceURL = request.sourceURL
        var temporaryConversion: URL?
        defer {
            if let temporaryConversion { try? FileManager.default.removeItem(at: temporaryConversion) }
        }

        if EbookConverter.needsConversion(format: request.format) {
            setStage(.converting, for: itemID)
            do {
                sourceURL = try await EbookConverter.convertForKindle(sourceURL)
                temporaryConversion = sourceURL
            } catch {
                Log.device.error("Convert-for-Kindle failed for \(request.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
                markFailed(itemID)
                return
            }
        }

        guard !Task.isCancelled else {
            markFailed(itemID)
            return
        }

        let base = (request.originalFileName as NSString).deletingPathExtension
        let fileName = "\(base).\(sourceURL.pathExtension)"
        setStage(.transferring, for: itemID)
        let signposter = Log.deviceSignposter
        let interval = signposter.beginInterval(
            "SendBook", id: signposter.makeSignpostID(), "\(fileName, privacy: .public)"
        )
        defer { signposter.endInterval("SendBook", interval) }

        do {
            Log.device.info("Transferring \(fileName, privacy: .public)")
            try await connection.send(
                fileURL: sourceURL,
                fileName: fileName,
                progress: { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.updateProgress(fraction, for: itemID)
                    }
                }
            )
            guard !Task.isCancelled else {
                markFailed(itemID)
                return
            }
            Log.device.notice("Transferred \(fileName, privacy: .public)")
            markDone(itemID)
            await connection.removeStaleVariants(baseName: base, keeping: fileName)
            await pushThumbnail(for: request.uuid, sentFile: sourceURL, connection: connection)
        } catch {
            Log.device.error("Transfer of \(fileName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            markFailed(itemID)
        }
    }

    private static func makeRequest(for book: Book) -> SendRequest {
        SendRequest(
            uuid: book.uuid,
            displayName: book.displayTitle,
            sourceURL: book.fileURL,
            originalFileName: book.originalFileName,
            format: book.format,
            drmProtected: book.drmProtected == true
        )
    }

    func copyToLibrary(_ book: DeviceBook, via monitor: DeviceMonitor) async -> URL? {
        guard let connection = monitor.connection, !isTransferring else { return nil }

        clearTask?.cancel()
        clearTask = nil
        isTransferring = true
        let item = Item(displayName: book.displayName, direction: .fromDevice)
        items = [item]

        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "WinstonImports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let destination = tempDir.appending(path: book.fileName)

        defer {
            isTransferring = false
            scheduleClear()
        }

        setStage(.transferring, for: item.id)
        do {
            try await connection.copyBook(book, to: destination, progress: { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.updateProgress(fraction, for: item.id)
                }
            })
            markDone(item.id)
            return destination
        } catch {
            lastError = error.localizedDescription
            markFailed(item.id)
            toasts.error(String(localized: "Couldn\u{2019}t copy the book from the device."))
            return nil
        }
    }

    // MARK: - Cover thumbnail (best-effort)

    private func pushThumbnail(for uuid: UUID, sentFile: URL, connection: any KindleDeviceConnection) async {
        let thumbnail = await Task.detached(priority: .utility) {
            KindleCoverThumbnail.prepare(sentFile: sentFile, coverSourceUUID: uuid)
        }.value
        guard let thumbnail else {
            Log.device.info("No cover thumbnail to push for \(sentFile.lastPathComponent, privacy: .public)")
            return
        }
        do {
            try await connection.pushCoverThumbnail(thumbnail.fileURL, named: thumbnail.name)
            Log.device.info("Pushed cover thumbnail \(thumbnail.name, privacy: .public)")
        } catch {
            Log.device.error("Cover thumbnail push failed: \(error.localizedDescription, privacy: .public)")
        }
        try? FileManager.default.removeItem(at: thumbnail.fileURL)
    }

    // MARK: - Bookkeeping

    private func updateProgress(_ fraction: Double, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].progress = fraction
    }

    private func setStage(_ stage: Stage, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].stage = stage
    }

    private func markDone(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].progress = 1
        items[index].stage = .done
    }

    private func markFailed(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].stage = .failed
    }

    private func scheduleClear() {
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, !isTransferring else { return }
            items = []
            clearTask = nil
        }
    }
}
