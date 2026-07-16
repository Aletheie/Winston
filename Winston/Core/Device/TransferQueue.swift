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
        let targetFileName: String
        let format: String
        let sourceFingerprint: String
        let coverVersion: Int
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
    private let onConversionArtifact: (@MainActor @Sendable (UUID, URL) async -> Void)?
    private let onTransferCompleted: (@MainActor @Sendable (KindleSyncTransferRecord) -> Void)?
    private var sendTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?

    init(
        toasts: ToastCenter,
        onConversionArtifact: (@MainActor @Sendable (UUID, URL) async -> Void)? = nil,
        onTransferCompleted: (@MainActor @Sendable (KindleSyncTransferRecord) -> Void)? = nil
    ) {
        self.toasts = toasts
        self.onConversionArtifact = onConversionArtifact
        self.onTransferCompleted = onTransferCompleted
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

    func beginSend(asset: BookAsset, for book: Book, via monitor: DeviceMonitor) {
        guard !isTransferring else { return }
        beginSend(requests: [Self.makeRequest(for: asset, book: book)], via: monitor)
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
        await send(books: books, via: monitor, announcesResult: true)
    }

    func send(books: [Book], via monitor: DeviceMonitor, announcesResult: Bool) async {
        guard !isTransferring else { return }
        let requests = books.map(Self.makeRequest)
        clearTask?.cancel()
        clearTask = nil
        isTransferring = true
        await performSend(requests: requests, via: monitor, announcesResult: announcesResult)
    }

    func send(asset: BookAsset, for book: Book, via monitor: DeviceMonitor) async {
        guard !isTransferring else { return }
        let request = Self.makeRequest(for: asset, book: book)
        clearTask?.cancel()
        clearTask = nil
        isTransferring = true
        await performSend(requests: [request], via: monitor)
    }

    private func performSend(
        requests: [SendRequest],
        via monitor: DeviceMonitor,
        announcesResult: Bool = true
    ) async {
        var pollingSuspended = false
        defer {
            if pollingSuspended { monitor.resumePolling() }
            isTransferring = false
            sendTask = nil
            scheduleClear()
        }

        guard let connection = monitor.connection, let deviceInfo = monitor.info else {
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
            await transfer(
                request,
                itemID: itemID,
                connection: connection,
                deviceInfo: deviceInfo
            )
        }

        if Task.isCancelled {
            for item in items where item.stage != .done { markFailed(item.id) }
        }
        let sent = items.filter { $0.stage == .done }.count
        Log.device.notice("Send queue finished: \(sent) sent, \(self.failedCount) failed")
        if announcesResult, !Task.isCancelled, failedCount > 0 {
            toasts.error(String(localized: "Some transfers failed (\(failedCount))."))
        } else if announcesResult, !Task.isCancelled, sent > 0 {
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
        connection: any KindleDeviceConnection,
        deviceInfo: DeviceInfo
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
                await onConversionArtifact?(request.uuid, sourceURL)
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

        let fileName = request.targetFileName
        let base = (fileName as NSString).deletingPathExtension
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
            let coverPushed = await pushThumbnail(
                for: request.uuid,
                sentFile: sourceURL,
                connection: connection
            )
            onTransferCompleted?(KindleSyncTransferRecord(
                deviceIdentifier: deviceInfo.identifier,
                deviceName: deviceInfo.name,
                bookID: request.uuid,
                sourceFingerprint: request.sourceFingerprint,
                sentFileName: fileName,
                coverVersion: coverPushed ? request.coverVersion : nil,
                completedAt: .now
            ))
        } catch {
            Log.device.error("Transfer of \(fileName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            markFailed(itemID)
        }
    }

    private static func makeRequest(for book: Book) -> SendRequest {
        let descriptor = KindleSendPreparation.descriptor(for: book)
        return SendRequest(
            uuid: book.uuid,
            displayName: book.displayTitle,
            sourceURL: descriptor.sourceURL,
            targetFileName: descriptor.targetFileName,
            format: descriptor.sourceFormat,
            sourceFingerprint: descriptor.sourceFingerprint,
            coverVersion: descriptor.coverVersion,
            drmProtected: book.drmProtected == true
        )
    }

    private static func makeRequest(for asset: BookAsset, book: Book) -> SendRequest {
        if asset.validationStatus == .missing || asset.validationStatus == .corrupt {
            return makeRequest(for: book)
        }
        if asset.fileName != book.fileName, asset.origin == .generated {
            let primaryHash = book.assets.first(where: { $0.fileName == book.fileName })?.contentHash
            guard let primaryHash, asset.generatedFromContentHash == primaryHash else {
                return makeRequest(for: book)
            }
        }
        let descriptor = KindleSendPreparation.descriptor(for: book)
        let requiresConversion = EbookConverter.needsConversion(format: asset.format)
        let targetFormat = requiresConversion
            ? EbookConverter.kindleTarget(forFormat: asset.format).ext
            : asset.format.lowercased()
        let baseName = (book.originalFileName as NSString).deletingPathExtension
        return SendRequest(
            uuid: book.uuid,
            displayName: book.displayTitle,
            sourceURL: asset.fileURL,
            targetFileName: "\(baseName).\(targetFormat)",
            format: asset.format,
            sourceFingerprint: descriptor.sourceFingerprint,
            coverVersion: descriptor.coverVersion,
            drmProtected: book.drmProtected == true
        )
    }

    private func beginSend(requests: [SendRequest], via monitor: DeviceMonitor) {
        clearTask?.cancel()
        clearTask = nil
        isTransferring = true
        sendTask = Task { [weak self] in
            await self?.performSend(requests: requests, via: monitor)
        }
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

    func repairCover(
        for book: Book,
        deviceBook: DeviceBook,
        via monitor: DeviceMonitor,
        announcesResult: Bool = true
    ) async -> Bool {
        guard !isTransferring,
              let connection = monitor.connection,
              let deviceInfo = monitor.info else { return false }
        let descriptor = KindleSendPreparation.descriptor(for: book)
        guard !descriptor.requiresConversion,
              descriptor.targetFormat.caseInsensitiveCompare(deviceBook.format) == .orderedSame else {
            lastError = "No matching Kindle format"
            if announcesResult {
                toasts.error(String(localized: "Couldn’t repair the Kindle cover for “\(book.displayTitle)”."))
            }
            return false
        }

        clearTask?.cancel()
        clearTask = nil
        isTransferring = true
        let item = Item(displayName: book.displayTitle, direction: .toDevice)
        items = [item]
        setStage(.transferring, for: item.id)
        monitor.suspendPolling()
        defer {
            monitor.resumePolling()
            isTransferring = false
            scheduleClear()
        }

        guard await connection.isAlive() else {
            lastError = "Device disconnected"
            markFailed(item.id)
            await monitor.disconnect()
            return false
        }
        let pushed = await pushThumbnail(
            for: book.uuid,
            sentFile: descriptor.sourceURL,
            connection: connection
        )
        guard pushed else {
            lastError = "Cover thumbnail unavailable"
            markFailed(item.id)
            if announcesResult {
                toasts.error(String(localized: "Couldn’t repair the Kindle cover for “\(book.displayTitle)”."))
            }
            return false
        }
        markDone(item.id)
        onTransferCompleted?(KindleSyncTransferRecord(
            deviceIdentifier: deviceInfo.identifier,
            deviceName: deviceInfo.name,
            bookID: book.uuid,
            sourceFingerprint: descriptor.sourceFingerprint,
            sentFileName: deviceBook.fileName,
            coverVersion: descriptor.coverVersion,
            completedAt: .now
        ))
        if announcesResult {
            toasts.success(String(localized: "Repaired the Kindle cover for “\(book.displayTitle)”."))
        }
        return true
    }

    private func pushThumbnail(for uuid: UUID, sentFile: URL, connection: any KindleDeviceConnection) async -> Bool {
        let thumbnail = await Task.detached(priority: .utility) {
            KindleCoverThumbnail.prepare(sentFile: sentFile, coverSourceUUID: uuid)
        }.value
        guard let thumbnail else {
            Log.device.info("No cover thumbnail to push for \(sentFile.lastPathComponent, privacy: .public)")
            return false
        }
        var succeeded = false
        do {
            try await connection.pushCoverThumbnail(thumbnail.fileURL, named: thumbnail.name)
            Log.device.info("Pushed cover thumbnail \(thumbnail.name, privacy: .public)")
            succeeded = true
        } catch {
            Log.device.error("Cover thumbnail push failed: \(error.localizedDescription, privacy: .public)")
        }
        try? FileManager.default.removeItem(at: thumbnail.fileURL)
        return succeeded
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
