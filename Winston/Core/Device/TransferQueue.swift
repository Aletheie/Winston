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
    private(set) var activePlan: TransferPlan?
    private(set) var lastBulkOperationResult: BulkOperationResult?

    private let toasts: ToastCenter
    private let onConversionArtifact: (@MainActor @Sendable (UUID, URL) async -> Void)?
    private let onTransferCompleted: (@MainActor @Sendable (KindleSyncTransferRecord) async throws -> Void)?
    private var sendTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var activeSession: BulkOperationSession?
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
        let descriptors = Self.makeDescriptors(for: books)
        guard !descriptors.isEmpty else { return }
        clearTask?.cancel()
        clearTask = nil
        isTransferring = true
        sendTask = Task { [weak self] in
            await self?.performSend(readModel: descriptors, via: monitor)
        }
    }

    func beginSend(
        readModel descriptors: [KindleSendDescriptor],
        via monitor: DeviceMonitor
    ) {
        guard !isTransferring else { return }
        beginSend(descriptors: descriptors, via: monitor)
    }

    func beginSend(asset: BookAsset, for book: Book, via monitor: DeviceMonitor) {
        guard !isTransferring else { return }
        beginSend(
            descriptors: [KindleSendPreparation.descriptor(for: asset, in: book)],
            via: monitor
        )
    }

    func cancel() {
        guard isTransferring else { return }
        sendTask?.cancel()
        if let activeSession {
            Task { await activeSession.cancel() }
        }
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
        let descriptors = Self.makeDescriptors(for: books)
        guard !descriptors.isEmpty else { return }
        clearTask?.cancel()
        clearTask = nil
        isTransferring = true
        await performSend(
            readModel: descriptors,
            via: monitor,
            announcesResult: announcesResult
        )
    }

    func send(
        readModel descriptors: [KindleSendDescriptor],
        via monitor: DeviceMonitor,
        announcesResult: Bool = true
    ) async {
        guard !isTransferring, !descriptors.isEmpty else { return }
        clearTask?.cancel()
        clearTask = nil
        isTransferring = true
        await performSend(
            readModel: descriptors,
            via: monitor,
            announcesResult: announcesResult
        )
    }

    func send(asset: BookAsset, for book: Book, via monitor: DeviceMonitor) async {
        guard !isTransferring else { return }
        let descriptor = KindleSendPreparation.descriptor(for: asset, in: book)
        clearTask?.cancel()
        clearTask = nil
        isTransferring = true
        await performSend(readModel: [descriptor], via: monitor)
    }

    private func performSend(
        readModel descriptors: [KindleSendDescriptor],
        via monitor: DeviceMonitor,
        announcesResult: Bool = true
    ) async {
        let descriptors = Self.uniqueDescriptors(descriptors)
        var pollingSuspended = false
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WinstonTransferArtifacts", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: stagingDirectory)
            if pollingSuspended { monitor.resumePolling() }
            activeSession = nil
            activePlan = nil
            isTransferring = false
            sendTask = nil
            scheduleClear()
        }

        lastError = nil
        replaceItems(descriptors.map {
            Item(displayName: $0.displayName, direction: .toDevice)
        })
        guard let inventory = monitor.inventory else {
            lastError = "Device disconnected"
            for item in items { markFailed(item.id) }
            if announcesResult {
                toasts.error(String(localized: "Some transfers failed (\(failedCount))."))
            }
            return
        }

        let transferPlan = TransferPlanner.makePlan(
            readModel: descriptors,
            inventory: inventory
        )
        activePlan = transferPlan
        let bulkPlan = await Self.makeBulkPlan(from: transferPlan)
        let session = BulkOperationSession(plan: bulkPlan)
        activeSession = session
        let planItemsByTarget = Dictionary(
            uniqueKeysWithValues: transferPlan.items.map {
                (BulkOperationTargetID.catalogBook($0.id), $0)
            }
        )
        let itemIDsByTarget = Dictionary(
            uniqueKeysWithValues: zip(descriptors, items).map {
                (BulkOperationTargetID.catalogBook($0.0.bookUUID), $0.1.id)
            }
        )
        for conflict in transferPlan.conflicts {
            if let itemID = itemIDsByTarget[conflict.targetID] {
                markFailed(itemID)
            }
            lastError = Self.message(for: conflict.reason)
        }

        Log.device.info(
            "Send plan: \(transferPlan.affectedTargetCount) change(s), \(transferPlan.conflictCount) conflict(s)"
        )
        let connection = monitor.connection
        let deviceInfo = monitor.info
        if connection != nil, deviceInfo != nil {
            monitor.suspendPolling()
            pollingSuspended = true
        }

        let result = await session.execute { [weak self] chunk in
            guard let self,
                  let targetID = chunk.targetIDs.first,
                  let planItem = planItemsByTarget[targetID],
                  let itemID = itemIDsByTarget[targetID] else {
                throw BulkOperationDurableError(.executionFailed)
            }
            guard let connection, let deviceInfo else {
                self.lastError = "Device disconnected"
                self.markFailed(itemID)
                throw BulkOperationDurableError(.deviceDisconnected)
            }
            if Task.isCancelled {
                self.markCancelled(itemID)
                throw CancellationError()
            }
            guard deviceInfo.identifier == transferPlan.deviceIdentifier else {
                self.lastError = "Device disconnected"
                self.markFailed(itemID)
                throw BulkOperationDurableError(.deviceDisconnected)
            }
            guard await connection.isAlive() else {
                self.lastError = "Device disconnected"
                self.markFailed(itemID)
                await monitor.disconnect()
                throw BulkOperationDurableError(.deviceDisconnected)
            }

            let artifact: TransferArtifact
            self.setStage(
                planItem.descriptor.requiresConversion ? .converting : .preparing,
                for: itemID
            )
            do {
                artifact = try await TransferArtifactBuilder.build(
                    planItem,
                    in: stagingDirectory
                )
                self.setStage(.waiting, for: itemID)
            } catch is CancellationError {
                self.markCancelled(itemID)
                throw CancellationError()
            } catch {
                self.lastError = error.localizedDescription
                self.markFailed(itemID)
                return BulkOperationChunkOutcome(conflicts: [
                    BulkOperationConflict(
                        targetID: targetID,
                        reason: Self.conflictReason(for: error),
                        detail: error.localizedDescription
                    ),
                ])
            }

            if let conflict = try await self.transfer(
                planItem,
                artifact: artifact,
                itemID: itemID,
                connection: connection,
                deviceInfo: deviceInfo
            ) {
                return BulkOperationChunkOutcome(conflicts: [conflict])
            }
            return .applied([targetID])
        }
        lastBulkOperationResult = result

        if result.completion == .failed {
            for targetID in result.pendingTargetIDs {
                if let itemID = itemIDsByTarget[targetID] {
                    markFailed(itemID)
                }
            }
        } else if result.completion == .cancelled || Task.isCancelled {
            for item in items where !Self.isTerminal(item.stage) { markCancelled(item.id) }
        }
        let sent = completedItemCount
        let cancelled = items.count { $0.stage == .cancelled }
        Log.device.notice(
            "Send session finished: \(sent) sent, \(self.failedCount) failed, \(cancelled) cancelled"
        )
        if announcesResult, result.completion != .cancelled, failedCount > 0 {
            toasts.error(String(localized: "Some transfers failed (\(failedCount))."))
        } else if announcesResult, result.completion != .cancelled, sent > 0 {
            toasts.success(String(localized: "Sent \(sent) to Kindle."))
        }
        if monitor.isConnected {
            await monitor.refreshBooks()
            await monitor.refreshInfo()
        }
    }

    private func transfer(
        _ planItem: TransferPlanItem,
        artifact: TransferArtifact,
        itemID: UUID,
        connection: any KindleDeviceConnection,
        deviceInfo: DeviceInfo
    ) async throws -> BulkOperationConflict? {
        let targetID = BulkOperationTargetID.catalogBook(planItem.id)
        guard !Task.isCancelled else {
            markCancelled(itemID)
            throw CancellationError()
        }

        let fileName = artifact.destination.fileName
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
            let technicalResult = try await connection.transfer(
                artifact.byteTransfer,
                progress: { [weak self] fraction in
                    guard progressGate.shouldPublish(fraction) else { return }
                    Task { @MainActor [weak self] in
                        self?.updateProgress(fraction, for: itemID)
                    }
                }
            )
            guard technicalResult.destination == artifact.destination,
                  technicalResult.bytesTransferred == artifact.byteCount else {
                throw TransferArtifactError.transportResultMismatch
            }
            Log.device.notice("Transferred \(fileName, privacy: .public)")
            if planItem.descriptor.requiresConversion, artifact.sourceIsPrimary {
                await onConversionArtifact?(artifact.bookID, artifact.fileURL)
            }
            try await connection.removeStaleVariants(baseName: base, keeping: fileName)
            let coverPushed = await pushThumbnail(
                for: artifact.coverOwner,
                sentFile: artifact.fileURL,
                connection: connection
            )
            try await onTransferCompleted?(KindleSyncTransferRecord(
                deviceIdentifier: deviceInfo.identifier,
                deviceName: deviceInfo.name,
                bookID: artifact.bookID,
                assetID: artifact.assetGeneration.assetID,
                sourceFormat: artifact.sourceFormat,
                sourceSizeBytes: artifact.sourceSizeBytes,
                sourceFingerprint: artifact.sourceFingerprint,
                artifactFormat: artifact.format,
                artifactSizeBytes: artifact.byteCount,
                artifactFingerprint: artifact.fingerprint,
                sentFileName: technicalResult.destination.fileName,
                transportIdentifier: technicalResult.transportIdentifier,
                coverVersion: coverPushed ? artifact.coverVersion : nil,
                coverIdentity: coverPushed
                    ? artifact.coverOwner.generationKey
                    : nil,
                completedAt: .now
            ))
            markDone(itemID)
            return nil
        } catch {
            if error is CancellationError {
                Log.device.info("Transfer of \(fileName, privacy: .public) cancelled")
                markCancelled(itemID)
                throw CancellationError()
            }
            Log.device.error("Transfer of \(fileName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            markFailed(itemID)
            return BulkOperationConflict(
                targetID: targetID,
                reason: .itemFailed,
                detail: error.localizedDescription
            )
        }
    }

    private static func makeBulkPlan(
        from transferPlan: TransferPlan
    ) async -> BulkOperationPlan {
        let conflictsByTarget = Dictionary(
            transferPlan.conflicts.map { ($0.targetID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let candidates = transferPlan.requestedBookIDs.map { bookID in
            let targetID = BulkOperationTargetID.catalogBook(bookID)
            if let conflict = conflictsByTarget[targetID] {
                return BulkOperationCandidate.conflict(
                    targetID,
                    reason: conflict.reason,
                    detail: conflict.detail
                )
            }
            return BulkOperationCandidate.change(targetID)
        }
        return await BulkOperationPlanner.shared.makePlan(
            operation: .deviceSend,
            requestedTargetIDs: transferPlan.requestedBookIDs.map {
                BulkOperationTargetID.catalogBook($0)
            },
            candidates: candidates,
            chunkSize: 1
        )
    }

    private static func message(
        for reason: BulkOperationConflictReason
    ) -> String {
        switch reason {
        case .missingTarget:
            "Book unavailable"
        case .invalidTarget:
            "Invalid transfer target"
        case .unavailable:
            "File unavailable"
        case .drmProtected:
            "DRM-protected"
        case .destinationCollision:
            "Destination file name collision"
        case .sourceChanged:
            TransferArtifactError.sourceChanged.localizedDescription
        case .itemFailed:
            "Transfer failed"
        }
    }

    private static func conflictReason(
        for error: Error
    ) -> BulkOperationConflictReason {
        guard let artifactError = error as? TransferArtifactError else {
            return .itemFailed
        }
        switch artifactError {
        case .sourceChanged:
            return .sourceChanged
        case .sourceUnavailable, .stagingFailed, .transportResultMismatch:
            return .itemFailed
        }
    }

    private static func makeDescriptors(
        for books: [Book]
    ) -> [KindleSendDescriptor] {
        uniqueDescriptors(books.map {
            KindleSendPreparation.descriptor(for: $0)
        })
    }

    private static func uniqueDescriptors(
        _ descriptors: [KindleSendDescriptor]
    ) -> [KindleSendDescriptor] {
        var seenBookIDs: Set<UUID> = []
        return descriptors.filter {
            seenBookIDs.insert($0.bookUUID).inserted
        }
    }

    private func beginSend(
        descriptors: [KindleSendDescriptor],
        via monitor: DeviceMonitor
    ) {
        guard !descriptors.isEmpty else { return }
        clearTask?.cancel()
        clearTask = nil
        isTransferring = true
        sendTask = Task { [weak self] in
            await self?.performSend(readModel: descriptors, via: monitor)
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
              let deviceInfo = monitor.info,
              let inventory = monitor.inventory else { return false }
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
        let plan = TransferPlanner.makePlan(
            readModel: [descriptor],
            inventory: inventory
        )
        guard let planItem = plan.items.first else {
            lastError = plan.conflicts.first.map {
                Self.message(for: $0.reason)
            } ?? TransferArtifactError.sourceUnavailable.localizedDescription
            markFailed(item.id)
            return false
        }
        let artifact: TransferArtifact
        setStage(.preparing, for: item.id)
        do {
            artifact = try await TransferArtifactBuilder.build(
                planItem,
                in: stagingDirectory
            )
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
            for: artifact.coverOwner,
            sentFile: artifact.fileURL,
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
                bookID: artifact.bookID,
                assetID: artifact.assetGeneration.assetID,
                sourceFormat: artifact.sourceFormat,
                sourceSizeBytes: artifact.sourceSizeBytes,
                sourceFingerprint: artifact.sourceFingerprint,
                artifactFormat: artifact.format,
                artifactSizeBytes: artifact.byteCount,
                artifactFingerprint: artifact.fingerprint,
                sentFileName: deviceBook.fileName,
                transportIdentifier: deviceBook.mtpItemID.map(String.init)
                    ?? deviceBook.path,
                coverVersion: artifact.coverVersion,
                coverIdentity: artifact.coverOwner.generationKey,
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

    private func pushThumbnail(
        for owner: CoverOwner,
        sentFile: URL,
        connection: any KindleDeviceConnection
    ) async -> Bool {
        let thumbnail = await Task.detached(priority: .utility) {
            KindleCoverThumbnail.prepare(sentFile: sentFile, coverOwner: owner)
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
