import Foundation
import Observation
import OSLog
import SwiftData

private nonisolated final class TransferProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFraction = -1.0
    private var lastUpdate = 0.0

    func shouldPublish(_ rawFraction: Double) -> Bool {
        let fraction = min(1, max(0, rawFraction))
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        let isEndpoint = fraction <= 0 || fraction >= 1
        guard isEndpoint
                || fraction - lastFraction >= 0.005
                || now - lastUpdate >= 0.05 else { return false }
        lastFraction = fraction
        lastUpdate = now
        return true
    }
}

@MainActor
@Observable
final class TransferQueue {
    private struct SendRequest: Sendable {
        let descriptor: KindleSendDescriptor
        let artifact: TransferArtifact?
        let drmProtected: Bool
        let generationIsCurrent: @MainActor @Sendable () -> Bool

        var uuid: UUID { descriptor.bookUUID }
        var displayName: String { descriptor.displayName }
        var targetFileName: String { descriptor.targetFileName }
        var fileUnavailable: Bool { descriptor.fileUnavailable || artifact == nil }
    }

    enum Direction: Sendable, Equatable {
        case toDevice
        case fromDevice
    }

    enum Stage: Sendable, Equatable {
        case waiting
        case preparing
        case converting
        case transferring
        case cancelling
        case cancelled
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
    private let onTransferCompleted: (@MainActor @Sendable (KindleSyncTransferRecord) async throws -> Void)?
    private var sendTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var itemIndexByID: [UUID: Int] = [:]
    private var activeItemID: UUID?
    private var failedItemCount = 0
    private var completedItemCount = 0
    private var totalProgress = 0.0

    init(
        toasts: ToastCenter,
        onConversionArtifact: (@MainActor @Sendable (UUID, URL) async -> Void)? = nil,
        onTransferCompleted: (@MainActor @Sendable (KindleSyncTransferRecord) async throws -> Void)? = nil
    ) {
        self.toasts = toasts
        self.onConversionArtifact = onConversionArtifact
        self.onTransferCompleted = onTransferCompleted
    }

    func beginSend(books: [Book], via monitor: DeviceMonitor) {
        guard !isTransferring else { return }
        let requests = Self.makeRequests(for: books)
        guard !requests.isEmpty else { return }
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
        for item in items where !Self.isTerminal(item.stage) {
            if item.id == activeItemID {
                setStage(.cancelling, for: item.id)
            } else {
                markCancelled(item.id)
            }
        }
    }

    var activeItem: Item? {
        guard let activeItemID,
              let index = itemIndexByID[activeItemID],
              items.indices.contains(index) else { return nil }
        return items[index]
    }

    var failedCount: Int {
        failedItemCount
    }

    var completedCount: Int {
        completedItemCount
    }

    var overallProgress: Double {
        guard !items.isEmpty else { return 0 }
        return totalProgress / Double(items.count)
    }

    // MARK: - Sending

    func send(books: [Book], via monitor: DeviceMonitor) async {
        await send(books: books, via: monitor, announcesResult: true)
    }

    func send(books: [Book], via monitor: DeviceMonitor, announcesResult: Bool) async {
        guard !isTransferring else { return }
        let requests = Self.makeRequests(for: books)
        guard !requests.isEmpty else { return }
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
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WinstonTransferArtifacts", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: stagingDirectory)
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
        replaceItems(requests.map { Item(displayName: $0.displayName, direction: .toDevice) })

        let targetGroups = Dictionary(grouping: requests.indices) {
            requests[$0].targetFileName.lowercased()
        }
        let conflictingIndexes = Set(targetGroups.values.flatMap { indexes -> [Int] in
            let owners = Set(indexes.map { requests[$0].uuid })
            return owners.count > 1 ? indexes : []
        })
        var preparedArtifacts: [Int: MaterializedTransferArtifact] = [:]
        preparedArtifacts.reserveCapacity(requests.count)

        for (index, request) in requests.enumerated() {
            if Task.isCancelled { break }
            let itemID = items[index].id
            if conflictingIndexes.contains(index) {
                lastError = "Destination file name collision"
                markFailed(itemID)
                continue
            }
            guard !request.fileUnavailable, !request.drmProtected,
                  let artifact = request.artifact else { continue }
            guard request.generationIsCurrent(), artifact.sourceGenerationIsCurrent() else {
                lastError = TransferArtifactError.sourceChanged.localizedDescription
                markFailed(itemID)
                continue
            }
            setStage(.preparing, for: itemID)
            do {
                let prepared = try await artifact.materialize(in: stagingDirectory)
                guard request.generationIsCurrent(), artifact.sourceGenerationIsCurrent() else {
                    lastError = TransferArtifactError.sourceChanged.localizedDescription
                    markFailed(itemID)
                    continue
                }
                preparedArtifacts[index] = prepared
                setStage(.waiting, for: itemID)
            } catch {
                if error is CancellationError {
                    markCancelled(itemID)
                    break
                }
                lastError = error.localizedDescription
                markFailed(itemID)
            }
        }

        for (index, request) in requests.enumerated() {
            if Task.isCancelled { break }
            let itemID = items[index].id
            guard !Self.isTerminal(items[index].stage) else { continue }

            guard await connection.isAlive() else {
                lastError = "Device disconnected"
                for i in index ..< items.count { markFailed(items[i].id) }
                await monitor.disconnect()
                break
            }
            let preparedArtifact = preparedArtifacts[index]
            await transfer(
                request,
                preparedArtifact: preparedArtifact,
                itemID: itemID,
                connection: connection,
                deviceInfo: deviceInfo
            )
        }

        if Task.isCancelled {
            for item in items where !Self.isTerminal(item.stage) { markCancelled(item.id) }
        }
        let sent = completedItemCount
        let cancelled = items.count { $0.stage == .cancelled }
        Log.device.notice(
            "Send queue finished: \(sent) sent, \(self.failedCount) failed, \(cancelled) cancelled"
        )
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
        preparedArtifact: MaterializedTransferArtifact?,
        itemID: UUID,
        connection: any KindleDeviceConnection,
        deviceInfo: DeviceInfo
    ) async {
        if request.fileUnavailable {
            lastError = "File unavailable"
            markFailed(itemID)
            return
        }
        if request.drmProtected {
            lastError = "DRM-protected"
            toasts.error(String(localized: "\u{201C}\(request.displayName)\u{201D} is DRM\u{2011}protected and can't be sent."))
            markFailed(itemID)
            return
        }
        guard let preparedArtifact,
              request.generationIsCurrent(),
              preparedArtifact.artifact.sourceGenerationIsCurrent() else {
            lastError = TransferArtifactError.sourceChanged.localizedDescription
            markFailed(itemID)
            return
        }

        var sourceURL = preparedArtifact.sourceURL
        var temporaryConversion: URL?
        defer {
            if let temporaryConversion { try? FileManager.default.removeItem(at: temporaryConversion) }
        }

        if EbookConverter.needsConversion(format: preparedArtifact.artifact.sourceFormat) {
            setStage(.converting, for: itemID)
            do {
                sourceURL = try await EbookConverter.convertForKindle(sourceURL)
                temporaryConversion = sourceURL
                if preparedArtifact.artifact.sourceIsPrimary {
                    await onConversionArtifact?(request.uuid, sourceURL)
                }
            } catch {
                if error is CancellationError {
                    markCancelled(itemID)
                    return
                }
                Log.device.error("Convert-for-Kindle failed for \(request.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
                markFailed(itemID)
                return
            }
        }

        guard request.generationIsCurrent(),
              preparedArtifact.artifact.sourceGenerationIsCurrent() else {
            lastError = TransferArtifactError.sourceChanged.localizedDescription
            markFailed(itemID)
            return
        }
        guard !Task.isCancelled else {
            markCancelled(itemID)
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
            let progressGate = TransferProgressGate()
            try await connection.send(
                fileURL: sourceURL,
                fileName: fileName,
                progress: { [weak self] fraction in
                    guard progressGate.shouldPublish(fraction) else { return }
                    Task { @MainActor [weak self] in
                        self?.updateProgress(fraction, for: itemID)
                    }
                }
            )
            Log.device.notice("Transferred \(fileName, privacy: .public)")
            try await connection.removeStaleVariants(baseName: base, keeping: fileName)
            let coverPushed = await pushThumbnail(
                for: request.uuid,
                sentFile: sourceURL,
                connection: connection
            )
            try await onTransferCompleted?(KindleSyncTransferRecord(
                deviceIdentifier: deviceInfo.identifier,
                deviceName: deviceInfo.name,
                bookID: request.uuid,
                assetID: preparedArtifact.artifact.assetGeneration.assetID,
                sourceFormat: preparedArtifact.artifact.sourceFormat,
                sourceSizeBytes: preparedArtifact.sourceSizeBytes,
                sourceFingerprint: preparedArtifact.sourceFingerprint,
                sentFileName: fileName,
                coverVersion: coverPushed ? preparedArtifact.artifact.coverVersion : nil,
                completedAt: .now
            ))
            markDone(itemID)
        } catch {
            if error is CancellationError {
                Log.device.info("Transfer of \(fileName, privacy: .public) cancelled")
                markCancelled(itemID)
                return
            }
            Log.device.error("Transfer of \(fileName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            markFailed(itemID)
        }
    }

    private static func makeRequests(for books: [Book]) -> [SendRequest] {
        var seenBookIDs: Set<UUID> = []
        return books.compactMap { book in
            guard book.hasDigitalFile, seenBookIDs.insert(book.uuid).inserted else { return nil }
            return makeRequest(for: book)
        }
    }

    private static func makeRequest(for book: Book) -> SendRequest {
        makeRequest(
            descriptor: KindleSendPreparation.descriptor(for: book),
            book: book
        )
    }

    private static func makeRequest(for asset: BookAsset, book: Book) -> SendRequest {
        makeRequest(
            descriptor: KindleSendPreparation.descriptor(for: asset, in: book),
            book: book
        )
    }

    private static func makeRequest(
        descriptor: KindleSendDescriptor,
        book: Book
    ) -> SendRequest {
        let generation = descriptor.assetGeneration
        let bookWasAttached = book.modelContext != nil
        let expectedOriginalFileName = book.originalFileName
        let expectedCoverVersion = descriptor.coverVersion
        let expectedDRMProtected = descriptor.drmProtected
        return SendRequest(
            descriptor: descriptor,
            artifact: TransferArtifact(descriptor: descriptor),
            drmProtected: descriptor.drmProtected,
            generationIsCurrent: { [book] in
                if bookWasAttached, book.modelContext == nil { return false }
                guard book.uuid == descriptor.bookUUID,
                      book.originalFileName == expectedOriginalFileName,
                      book.coverVersion == expectedCoverVersion,
                      (book.drmProtected == true) == expectedDRMProtected else { return false }
                if generation.isCatalogued {
                    guard let asset = book.assets.first(where: { $0.uuid == generation.assetID }) else {
                        return false
                    }
                    return asset.fileName == generation.fileName
                        && asset.dateAdded == generation.dateAdded
                }
                return book.fileName == generation.fileName
                    && book.dateAdded == generation.dateAdded
            }
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
        replaceItems([item])

        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "WinstonImports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        guard let fileName = ManagedLeafName(rawValue: book.fileName) else {
            lastError = DeviceError.invalidFileName.localizedDescription
            markFailed(item.id)
            isTransferring = false
            scheduleClear()
            return nil
        }
        let destination = fileName.appending(to: tempDir) ?? tempDir.appending(path: UUID().uuidString)

        defer {
            isTransferring = false
            scheduleClear()
        }

        setStage(.transferring, for: item.id)
        do {
            let progressGate = TransferProgressGate()
            try await connection.copyBook(book, to: destination, progress: { [weak self] fraction in
                guard progressGate.shouldPublish(fraction) else { return }
                Task { @MainActor [weak self] in
                    self?.updateProgress(fraction, for: item.id)
                }
            })
            markDone(item.id)
            return destination
        } catch {
            lastError = error.localizedDescription
            if error is CancellationError {
                markCancelled(item.id)
            } else {
                markFailed(item.id)
                toasts.error(String(localized: "Couldn\u{2019}t copy the book from the device."))
            }
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
        replaceItems([item])
        monitor.suspendPolling()
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WinstonTransferArtifacts", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: stagingDirectory)
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
        let request = Self.makeRequest(descriptor: descriptor, book: book)
        guard !request.fileUnavailable, !request.drmProtected,
              let artifact = request.artifact,
              request.generationIsCurrent(),
              artifact.sourceGenerationIsCurrent() else {
            lastError = TransferArtifactError.sourceChanged.localizedDescription
            markFailed(item.id)
            return false
        }
        let preparedArtifact: MaterializedTransferArtifact
        setStage(.preparing, for: item.id)
        do {
            preparedArtifact = try await artifact.materialize(in: stagingDirectory)
            guard request.generationIsCurrent(), artifact.sourceGenerationIsCurrent() else {
                throw TransferArtifactError.sourceChanged
            }
        } catch {
            lastError = error.localizedDescription
            if error is CancellationError {
                markCancelled(item.id)
            } else {
                markFailed(item.id)
            }
            return false
        }
        setStage(.transferring, for: item.id)
        let pushed = await pushThumbnail(
            for: book.uuid,
            sentFile: preparedArtifact.sourceURL,
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
        do {
            try await onTransferCompleted?(KindleSyncTransferRecord(
                deviceIdentifier: deviceInfo.identifier,
                deviceName: deviceInfo.name,
                bookID: book.uuid,
                assetID: preparedArtifact.artifact.assetGeneration.assetID,
                sourceFormat: preparedArtifact.artifact.sourceFormat,
                sourceSizeBytes: preparedArtifact.sourceSizeBytes,
                sourceFingerprint: preparedArtifact.sourceFingerprint,
                sentFileName: deviceBook.fileName,
                coverVersion: preparedArtifact.artifact.coverVersion,
                completedAt: .now
            ))
        } catch {
            lastError = error.localizedDescription
            markFailed(item.id)
            return false
        }
        markDone(item.id)
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

    private func replaceItems(_ newItems: [Item]) {
        items = newItems
        itemIndexByID = Dictionary(
            uniqueKeysWithValues: newItems.indices.map { (newItems[$0].id, $0) }
        )
        failedItemCount = newItems.count { $0.stage == .failed }
        completedItemCount = newItems.count { $0.stage == .done }
        totalProgress = newItems.reduce(0) { $0 + $1.progress }
        activeItemID = newItems.first {
            !Self.isTerminal($0.stage)
        }?.id
    }

    private func updateProgress(_ fraction: Double, for id: UUID) {
        guard let index = itemIndexByID[id], items.indices.contains(index) else { return }
        guard !Self.isTerminal(items[index].stage) else { return }
        let clamped = max(items[index].progress, min(1, max(0, fraction)))
        totalProgress += clamped - items[index].progress
        items[index].progress = clamped
    }

    private func setStage(_ stage: Stage, for id: UUID) {
        guard let index = itemIndexByID[id], items.indices.contains(index) else { return }
        items[index].stage = stage
        if !Self.isTerminal(stage) {
            activeItemID = id
        }
    }

    private func markDone(_ id: UUID) {
        guard let index = itemIndexByID[id], items.indices.contains(index) else { return }
        guard items[index].stage != .done else { return }
        totalProgress += 1 - items[index].progress
        items[index].progress = 1
        items[index].stage = .done
        completedItemCount += 1
        advanceActiveItem(after: index, completedID: id)
    }

    private func markFailed(_ id: UUID) {
        guard let index = itemIndexByID[id], items.indices.contains(index) else { return }
        guard items[index].stage != .failed else { return }
        if items[index].stage == .done {
            completedItemCount = max(0, completedItemCount - 1)
        }
        items[index].stage = .failed
        failedItemCount += 1
        advanceActiveItem(after: index, completedID: id)
    }

    private func markCancelled(_ id: UUID) {
        guard let index = itemIndexByID[id], items.indices.contains(index) else { return }
        guard !Self.isTerminal(items[index].stage) else { return }
        items[index].stage = .cancelled
        advanceActiveItem(after: index, completedID: id)
    }

    private func advanceActiveItem(after index: Int, completedID: UUID) {
        guard activeItemID == completedID else { return }
        activeItemID = items.dropFirst(index + 1).first {
            !Self.isTerminal($0.stage)
        }?.id
    }

    private static func isTerminal(_ stage: Stage) -> Bool {
        stage == .done || stage == .failed || stage == .cancelled
    }

    private func scheduleClear() {
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, !isTransferring else { return }
            replaceItems([])
            clearTask = nil
        }
    }
}
