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

private nonisolated enum DurableTransferBoundaryError: Error, LocalizedError {
    case checkpointFailed(String)
    case deliveryUnknown(String)
    case postProcessingPending(String)

    var errorDescription: String? {
        switch self {
        case .checkpointFailed(let detail):
            "The transfer recovery checkpoint could not be saved. \(detail)"
        case .deliveryUnknown(let detail):
            "Winston could not determine whether the Kindle received the book. \(detail)"
        case .postProcessingPending(let detail):
            "The book was sent, but follow-up work is still pending. \(detail)"
        }
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
    private(set) var lastWarning: String?
    private(set) var activePlan: TransferPlan?
    private(set) var lastBulkOperationResult: BulkOperationResult?
    private(set) var journalLoadIssue: TransferQueueJournalLoadIssue?
    private(set) var quarantinedJournalURL: URL?

    private let toasts: ToastCenter
    private let onConversionArtifact: (@MainActor @Sendable (UUID, URL) async -> Void)?
    private let onTransferCompleted: (@MainActor @Sendable (KindleSyncTransferRecord) async throws -> Void)?
    private let journalStore: TransferQueueJournalStore
    private let importSourceLeases: ImportSourceLeaseStore
    private let now: @Sendable () -> Date
    private var sendTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var activeSession: BulkOperationSession?
    @ObservationIgnored private var itemIndexByID: [UUID: Int] = [:]
    @ObservationIgnored private var bookIDByItemID: [UUID: UUID] = [:]
    private var durableJob: DurableTransferJob?
    private var activeItemID: UUID?
    private var failedItemCount = 0
    private var completedItemCount = 0
    private var totalProgress = 0.0

    init(
        toasts: ToastCenter,
        onConversionArtifact: (@MainActor @Sendable (UUID, URL) async -> Void)? = nil,
        onTransferCompleted: (@MainActor @Sendable (KindleSyncTransferRecord) async throws -> Void)? = nil,
        journalDirectory: URL? = nil,
        importSourceLeases: ImportSourceLeaseStore = ImportSourceLeaseStore(),
        journalStoreOverride: TransferQueueJournalStore? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.toasts = toasts
        self.onConversionArtifact = onConversionArtifact
        self.onTransferCompleted = onTransferCompleted
        self.importSourceLeases = importSourceLeases
        self.now = now
        let store = journalStoreOverride ?? TransferQueueJournalStore(
            directory: journalDirectory ?? Self.defaultJournalDirectory(),
            now: now
        )
        journalStore = store
        let loadResult = store.load()
        journalLoadIssue = loadResult.issue
        quarantinedJournalURL = loadResult.quarantinedURL
        if var loadedJob = loadResult.job,
           loadedJob.items.contains(where: { $0.state == .inFlight }) {
            for index in loadedJob.items.indices
                where loadedJob.items[index].state == .inFlight {
                loadedJob.items[index].state = .deliveryUnknown
                loadedJob.items[index].detail =
                    "The previous process ended while delivery was in flight."
            }
            loadedJob.updatedAt = now()
            do {
                try store.save(loadedJob)
                durableJob = loadedJob
            } catch {
                durableJob = loadResult.job
                lastWarning =
                    "Could not checkpoint interrupted Kindle transfers: \(error.localizedDescription)"
            }
        } else {
            durableJob = loadResult.job
        }
        if let job = loadResult.job, job.isTerminal {
            do {
                try store.remove()
                durableJob = nil
            } catch {
                Log.device.error(
                    "Could not remove terminal transfer journal: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    var pendingTransferCount: Int {
        durableJob?.items.count { !$0.state.isTerminal } ?? 0
    }

    var pendingTransferDeviceIdentifier: String? {
        pendingTransferCount > 0 ? durableJob?.deviceIdentifier : nil
    }

    var hasUnresolvedDelivery: Bool {
        !(durableJob?.unresolvedItems.isEmpty ?? true)
    }

    func beginSend(books: [Book], via monitor: DeviceMonitor) {
        launchSend(
            descriptors: Self.makeDescriptors(for: books),
            via: monitor
        )
    }

    func beginSend(
        readModel descriptors: [KindleSendDescriptor],
        via monitor: DeviceMonitor
    ) {
        launchSend(descriptors: descriptors, via: monitor)
    }

    func beginSend(asset: BookAsset, for book: Book, via monitor: DeviceMonitor) {
        launchSend(
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

    /// Resumes only items that never crossed the verified payload commit point.
    /// Completed/committed items in the journal are intentionally skipped.
    func resumePending(via monitor: DeviceMonitor, announcesResult: Bool = true) async {
        guard !isTransferring,
              let durableJob,
              durableJob.resumePolicy == .sameDeviceAutomatically,
              durableJob.deviceIdentifier == monitor.info?.identifier
        else { return }
        await monitor.refreshBooks()
        await monitor.refreshInfo()
        guard reconcileUnknownDeliveries(using: monitor.inventory) else {
            if hasUnresolvedDelivery {
                lastError = String(
                    localized: "A Kindle transfer needs review before it can be retried."
                )
                if announcesResult { toasts.error(lastError ?? "") }
            }
            return
        }
        guard let durableJob = self.durableJob else { return }
        let descriptors = durableJob.items.compactMap {
            switch $0.state {
            case .pending, .payloadCommitted:
                $0.descriptor
            case .inFlight, .deliveryUnknown, .completed, .failed, .cancelled:
                nil
            }
        }
        guard !descriptors.isEmpty else {
            finishDurableJobIfTerminal()
            return
        }

        guard let task = launchSend(
            descriptors: descriptors,
            via: monitor,
            announcesResult: announcesResult,
            resumingJobID: durableJob.id
        ) else { return }
        await awaitSendTask(task)
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

    /// A value-only projection for sync presentation. The durable journal
    /// remains the source of truth whenever delivery crossed an uncertain or
    /// committed transport boundary.
    var kindleSyncExecutionSnapshots: [UUID: KindleTransferExecutionSnapshot] {
        var snapshots: [UUID: KindleTransferExecutionSnapshot] = [:]
        snapshots.reserveCapacity(bookIDByItemID.count)
        for item in items {
            guard let bookID = bookIDByItemID[item.id] else { continue }
            let durableItem = durableJob?.items.first {
                $0.descriptor.bookUUID == bookID
            }
            let conflictDetail = lastBulkOperationResult?.conflicts.first {
                $0.targetID == .catalogBook(bookID)
            }?.detail

            let outcome: KindleSyncExecutionOutcome
            let retryEligibility: KindleSyncRetryEligibility
            switch durableItem?.state {
            case .inFlight, .deliveryUnknown:
                outcome = .deliveryUnknown
                retryEligibility = .deliveryUnknown
            case .payloadCommitted:
                if item.stage == .done {
                    outcome = .succeeded
                    retryEligibility = .notNeeded
                } else {
                    outcome = .failed
                    retryEligibility = .durableRecovery
                }
            case .pending, .completed, .failed, .cancelled, nil:
                switch item.stage {
                case .waiting:
                    outcome = item.id == activeItemID ? .running : .pending
                    retryEligibility = .notNeeded
                case .preparing, .converting, .transferring, .cancelling:
                    outcome = .running
                    retryEligibility = .notNeeded
                case .done:
                    outcome = .succeeded
                    retryEligibility = .notNeeded
                case .failed:
                    outcome = .failed
                    retryEligibility = .safe
                case .cancelled:
                    outcome = .cancelled
                    retryEligibility = .safe
                }
            }
            snapshots[bookID] = KindleTransferExecutionSnapshot(
                bookID: bookID,
                outcome: outcome,
                progress: outcome.isTerminal ? 1 : item.progress,
                detail: durableItem?.detail ?? conflictDetail
                    ?? (outcome == .failed ? lastError : nil),
                retryEligibility: retryEligibility
            )
        }
        return snapshots
    }

    // MARK: - Sending

    func send(books: [Book], via monitor: DeviceMonitor) async {
        await send(books: books, via: monitor, announcesResult: true)
    }

    func send(books: [Book], via monitor: DeviceMonitor, announcesResult: Bool) async {
        await send(
            descriptors: Self.makeDescriptors(for: books),
            via: monitor,
            announcesResult: announcesResult
        )
    }

    func send(
        readModel descriptors: [KindleSendDescriptor],
        via monitor: DeviceMonitor,
        announcesResult: Bool = true
    ) async {
        await send(
            descriptors: descriptors,
            via: monitor,
            announcesResult: announcesResult
        )
    }

    func send(asset: BookAsset, for book: Book, via monitor: DeviceMonitor) async {
        await send(
            descriptors: [
                KindleSendPreparation.descriptor(for: asset, in: book),
            ],
            via: monitor,
            announcesResult: true
        )
    }

    private func executeSend(
        readModel descriptors: [KindleSendDescriptor],
        via monitor: DeviceMonitor,
        announcesResult: Bool = true,
        resumingJobID: UUID? = nil
    ) async {
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
            finishDurableJobIfTerminal()
            scheduleClear()
        }

        lastError = nil
        lastWarning = nil
        replaceItems(
            descriptors.map {
                Item(displayName: $0.displayName, direction: .toDevice)
            },
            bookIDs: descriptors.map(\.bookUUID)
        )
        guard let inventory = monitor.inventory else {
            lastError = "Device disconnected"
            for item in items { markFailed(item.id) }
            if announcesResult {
                toasts.error(String(localized: "Some transfers failed (\(failedCount))."))
            }
            return
        }

        var transferPlan = TransferPlanner.makePlan(
            readModel: descriptors,
            inventory: inventory
        )
        if let resumingJobID {
            guard durableJob?.id == resumingJobID else {
                lastError = "Transfer recovery record changed"
                for item in items { markFailed(item.id) }
                return
            }
            transferPlan = validatedResumePlan(transferPlan)
        } else if !transferPlan.items.isEmpty {
            guard beginDurableJob(for: transferPlan) else {
                for item in items where !Self.isTerminal(item.stage) {
                    markFailed(item.id)
                }
                if announcesResult {
                    toasts.error(String(localized: "The transfer could not be saved for recovery."))
                }
                return
            }
        }
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
            lastError = Self.message(for: conflict.reason)
            if let itemID = itemIDsByTarget[conflict.targetID] {
                markFailed(itemID)
            }
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

            do {
                let warning: BulkOperationWarning?
                if self.durableState(for: planItem.id) == .payloadCommitted {
                    warning = try await self.resumePostProcessing(
                        planItem,
                        artifact: artifact,
                        itemID: itemID,
                        connection: connection,
                        deviceInfo: deviceInfo
                    )
                } else {
                    warning = try await self.transfer(
                        planItem,
                        artifact: artifact,
                        itemID: itemID,
                        connection: connection,
                        deviceInfo: deviceInfo
                    )
                }
                return .applied(
                    [targetID],
                    warnings: [warning].compactMap { $0 }
                )
            } catch is CancellationError {
                self.markCancelled(itemID)
                throw CancellationError()
            } catch let boundaryError as DurableTransferBoundaryError {
                Log.device.error(
                    "Transfer recovery requires attention for \(artifact.destination.fileName, privacy: .public): \(boundaryError.localizedDescription, privacy: .public)"
                )
                self.lastError = boundaryError.localizedDescription
                self.markRecoveryRequired(itemID)
                return BulkOperationChunkOutcome(conflicts: [
                    BulkOperationConflict(
                        targetID: targetID,
                        reason: .itemFailed,
                        detail: boundaryError.localizedDescription
                    ),
                ])
            } catch {
                Log.device.error(
                    "Transfer of \(artifact.destination.fileName, privacy: .public) failed before payload verification: \(error.localizedDescription, privacy: .public)"
                )
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
        } else if announcesResult,
                  result.completion != .cancelled,
                  !result.warnings.isEmpty {
            toasts.info(String(
                localized: "Sent \(sent) to Kindle; some follow-up work needs attention."
            ))
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
    ) async throws -> BulkOperationWarning? {
        guard !Task.isCancelled else {
            markCancelled(itemID)
            throw CancellationError()
        }

        let fileName = artifact.destination.fileName
        setStage(.transferring, for: itemID)
        let signposter = Log.deviceSignposter
        let interval = signposter.beginInterval(
            "SendBook", id: signposter.makeSignpostID(), "\(fileName, privacy: .public)"
        )
        defer { signposter.endInterval("SendBook", interval) }

        Log.device.info("Transferring \(fileName, privacy: .public)")
        let progressGate = TransferProgressGate()
        try checkpointInFlight(itemID, artifact: artifact)
        let technicalResult: DeviceTransferResult
        do {
            technicalResult = try await connection.transfer(
                artifact.byteTransfer,
                progress: { [weak self] fraction in
                    guard progressGate.shouldPublish(fraction) else { return }
                    Task { @MainActor [weak self] in
                        self?.updateProgress(fraction, for: itemID)
                    }
                }
            )
        } catch {
            checkpointDeliveryUnknown(itemID, detail: error.localizedDescription)
            throw DurableTransferBoundaryError.deliveryUnknown(
                error.localizedDescription
            )
        }
        guard technicalResult.destination == artifact.destination,
              technicalResult.bytesTransferred == artifact.byteCount else {
            let detail = TransferArtifactError.transportResultMismatch
                .localizedDescription
            checkpointDeliveryUnknown(itemID, detail: detail)
            throw DurableTransferBoundaryError.deliveryUnknown(detail)
        }

        try checkpointPayloadCommitted(
            itemID,
            technicalResult: technicalResult
        )
        Log.device.notice("Transferred and verified \(fileName, privacy: .public)")
        return try await resumePostProcessing(
            planItem,
            artifact: artifact,
            itemID: itemID,
            connection: connection,
            deviceInfo: deviceInfo
        )
    }

    private func resumePostProcessing(
        _ planItem: TransferPlanItem,
        artifact: TransferArtifact,
        itemID: UUID,
        connection: any KindleDeviceConnection,
        deviceInfo: DeviceInfo
    ) async throws -> BulkOperationWarning? {
        guard var payload = durablePayload(for: planItem.id) else {
            throw DurableTransferBoundaryError.postProcessingPending(
                "The verified payload checkpoint is incomplete."
            )
        }
        guard payload.destinationFileName.caseInsensitiveCompare(
            artifact.destination.fileName
        ) == .orderedSame,
        (payload.expectedByteCount.map { $0 == artifact.byteCount } ?? true),
        (payload.artifactFingerprint.map {
            $0.caseInsensitiveCompare(artifact.fingerprint) == .orderedSame
        } ?? true) else {
            throw DurableTransferBoundaryError.postProcessingPending(
                "The source generation no longer reproduces the verified payload."
            )
        }
        if payload.expectedByteCount == nil || payload.artifactFingerprint == nil {
            payload.expectedByteCount = artifact.byteCount
            payload.artifactFingerprint = artifact.fingerprint
            try checkpointPayload(itemID, payload)
        }

        if planItem.descriptor.requiresConversion,
           artifact.sourceIsPrimary,
           !payload.conversionAdopted {
            await onConversionArtifact?(artifact.bookID, artifact.fileURL)
            payload.conversionAdopted = true
            try checkpointPayload(itemID, payload)
        }

        let fileName = artifact.destination.fileName
        let base = (fileName as NSString).deletingPathExtension
        var postProcessingFailures: [String] = []
        if !payload.staleVariantsRemoved {
            do {
                try await connection.removeStaleVariants(
                    baseName: base,
                    keeping: fileName
                )
                payload.staleVariantsRemoved = true
                try checkpointPayload(itemID, payload)
            } catch {
                postProcessingFailures.append(error.localizedDescription)
                Log.device.error(
                    "Post-transfer cleanup failed for \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if !payload.coverProcessed {
            switch await pushThumbnailOutcome(
                for: artifact.coverOwner,
                sentFile: artifact.fileURL,
                connection: connection
            ) {
            case .pushed:
                payload.coverProcessed = true
                payload.coverPushed = true
                try checkpointPayload(itemID, payload)
            case .unavailable:
                payload.coverProcessed = true
                payload.coverPushed = false
                try checkpointPayload(itemID, payload)
            case .failed(let detail):
                postProcessingFailures.append(detail)
            }
        }

        if !payload.receiptPersisted {
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
                    sentFileName: payload.destinationFileName,
                    transportIdentifier: payload.transportIdentifier,
                    coverVersion: payload.coverPushed
                        ? artifact.coverVersion
                        : nil,
                    coverIdentity: payload.coverPushed
                        ? artifact.coverOwner.generationKey
                        : nil,
                    completedAt: payload.payloadCommittedAt ?? now()
                ))
                payload.receiptPersisted = true
                try checkpointPayload(itemID, payload)
            } catch {
                postProcessingFailures.append(error.localizedDescription)
                Log.device.error(
                    "Transfer receipt persistence failed for \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        guard postProcessingFailures.isEmpty else {
            let detail = postProcessingFailures.joined(separator: " ")
            lastWarning = detail
            throw DurableTransferBoundaryError.postProcessingPending(detail)
        }
        guard markDone(itemID) else {
            throw DurableTransferBoundaryError.checkpointFailed(
                lastWarning ?? "The completion checkpoint was not saved."
            )
        }
        return nil
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

    @discardableResult
    private func launchSend(
        descriptors: [KindleSendDescriptor],
        via monitor: DeviceMonitor,
        announcesResult: Bool = true,
        resumingJobID: UUID? = nil
    ) -> Task<Void, Never>? {
        let descriptors = Self.uniqueDescriptors(descriptors)
        guard !isTransferring, !descriptors.isEmpty else { return nil }
        clearTask?.cancel()
        clearTask = nil
        isTransferring = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.executeSend(
                readModel: descriptors,
                via: monitor,
                announcesResult: announcesResult,
                resumingJobID: resumingJobID
            )
        }
        sendTask = task
        return task
    }

    private func send(
        descriptors: [KindleSendDescriptor],
        via monitor: DeviceMonitor,
        announcesResult: Bool
    ) async {
        guard let task = launchSend(
            descriptors: descriptors,
            via: monitor,
            announcesResult: announcesResult
        ) else { return }
        await awaitSendTask(task)
    }

    private func awaitSendTask(_ task: Task<Void, Never>) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func copyToLibrary(
        _ book: DeviceBook,
        via monitor: DeviceMonitor
    ) async -> WinstonImportSourceLease? {
        let leases = await copyToLibrary([book], via: monitor)
        return leases.first
    }

    func copyToLibrary(
        _ books: [DeviceBook],
        via monitor: DeviceMonitor
    ) async -> [WinstonImportSourceLease] {
        guard let connection = monitor.connection,
              !isTransferring,
              !books.isEmpty else { return [] }

        clearTask?.cancel()
        clearTask = nil
        isTransferring = true
        let transferItems = books.map {
            Item(displayName: $0.displayName, direction: .fromDevice)
        }
        replaceItems(transferItems)

        defer {
            isTransferring = false
            scheduleClear()
        }

        var leases: [WinstonImportSourceLease] = []
        leases.reserveCapacity(books.count)
        var reportedFailure = false

        for (index, book) in books.enumerated() {
            let item = transferItems[index]
            if Task.isCancelled {
                for remaining in transferItems[index...] {
                    markCancelled(remaining.id)
                }
                break
            }

            guard let fileName = ManagedLeafName(rawValue: book.fileName) else {
                lastError = DeviceError.invalidFileName.localizedDescription
                markFailed(item.id)
                continue
            }

            let lease: WinstonImportSourceLease
            do {
                lease = try importSourceLeases.create(fileName: fileName)
            } catch {
                lastError = error.localizedDescription
                markFailed(item.id)
                continue
            }

            setStage(.transferring, for: item.id)
            do {
                let progressGate = TransferProgressGate()
                try await connection.copyBook(
                    book,
                    to: lease.fileURL,
                    progress: { [weak self] fraction in
                        guard progressGate.shouldPublish(fraction) else { return }
                        Task { @MainActor [weak self] in
                            self?.updateProgress(fraction, for: item.id)
                        }
                    }
                )
                markDone(item.id)
                leases.append(lease)
            } catch {
                do {
                    try importSourceLeases.remove(lease)
                } catch {
                    Log.device.error(
                        "Could not clean failed device import lease: \(error.localizedDescription, privacy: .public)"
                    )
                }
                lastError = error.localizedDescription
                if error is CancellationError {
                    markCancelled(item.id)
                    for remaining in transferItems.dropFirst(index + 1) {
                        markCancelled(remaining.id)
                    }
                    break
                }
                markFailed(item.id)
                if !reportedFailure {
                    toasts.error(String(localized: "Couldn\u{2019}t copy the book from the device."))
                    reportedFailure = true
                }
            }
        }
        return leases
    }

    // MARK: - Cover thumbnail (best-effort)

    private enum ThumbnailOutcome {
        case pushed
        case unavailable
        case failed(String)

        var succeeded: Bool {
            if case .pushed = self { return true }
            return false
        }
    }

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
                completedAt: now()
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
        await pushThumbnailOutcome(
            for: owner,
            sentFile: sentFile,
            connection: connection
        ).succeeded
    }

    private func pushThumbnailOutcome(
        for owner: CoverOwner,
        sentFile: URL,
        connection: any KindleDeviceConnection
    ) async -> ThumbnailOutcome {
        let thumbnail = await Task.detached(priority: .utility) {
            KindleCoverThumbnail.prepare(sentFile: sentFile, coverOwner: owner)
        }.value
        guard let thumbnail else {
            Log.device.info("No cover thumbnail to push for \(sentFile.lastPathComponent, privacy: .public)")
            return .unavailable
        }
        do {
            try await connection.pushCoverThumbnail(thumbnail.fileURL, named: thumbnail.name)
            Log.device.info("Pushed cover thumbnail \(thumbnail.name, privacy: .public)")
            try? FileManager.default.removeItem(at: thumbnail.fileURL)
            return .pushed
        } catch {
            Log.device.error("Cover thumbnail push failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: thumbnail.fileURL)
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Durable send journal

    private func beginDurableJob(for plan: TransferPlan) -> Bool {
        let timestamp = now()
        let job = DurableTransferJob(
            schemaVersion: DurableTransferJob.currentSchemaVersion,
            id: UUID(),
            deviceIdentifier: plan.deviceIdentifier,
            resumePolicy: .sameDeviceAutomatically,
            createdAt: timestamp,
            updatedAt: timestamp,
            items: plan.items.map {
                DurableTransferItem(
                    descriptor: $0.descriptor,
                    sourceFileGeneration: $0.sourceFileGeneration,
                    state: .pending,
                    detail: nil
                )
            }
        )
        do {
            try journalStore.save(job)
            durableJob = job
            return true
        } catch {
            lastError = error.localizedDescription
            Log.device.error(
                "Could not create durable transfer journal: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func validatedResumePlan(_ plan: TransferPlan) -> TransferPlan {
        guard let durableJob else { return plan }
        let frozenItems = Dictionary(
            uniqueKeysWithValues: durableJob.items.map {
                ($0.descriptor.bookUUID, $0)
            }
        )
        var validItems: [TransferPlanItem] = []
        var conflicts = plan.conflicts
        for item in plan.items {
            guard let frozen = frozenItems[item.id],
                  frozen.state == .pending
                    || frozen.state == .payloadCommitted,
                  frozen.sourceFileGeneration == item.sourceFileGeneration else {
                conflicts.append(BulkOperationConflict(
                    targetID: .catalogBook(item.id),
                    reason: .sourceChanged,
                    detail: TransferArtifactError.sourceChanged.localizedDescription
                ))
                continue
            }
            validItems.append(item)
        }
        return TransferPlan(
            deviceIdentifier: plan.deviceIdentifier,
            requestedBookIDs: plan.requestedBookIDs,
            items: validItems,
            conflicts: conflicts
        )
    }

    private func durableState(for bookID: UUID) -> DurableTransferItemState? {
        durableJob?.items.first {
            $0.descriptor.bookUUID == bookID
        }?.state
    }

    private func durablePayload(for bookID: UUID) -> DurableTransferPayload? {
        durableJob?.items.first {
            $0.descriptor.bookUUID == bookID
        }?.payload
    }

    private func checkpointInFlight(
        _ itemID: UUID,
        artifact: TransferArtifact
    ) throws {
        guard let bookID = bookIDByItemID[itemID] else {
            throw DurableTransferBoundaryError.checkpointFailed(
                "The transfer item is not represented in the recovery journal."
            )
        }
        do {
            try mutateDurableItem(bookID: bookID) { item in
                guard item.state == .pending else {
                    throw CocoaError(.fileWriteUnknown)
                }
                item.state = .inFlight
                item.detail = nil
                item.payload = DurableTransferPayload(
                    attemptID: UUID(),
                    destinationFileName: artifact.destination.fileName,
                    expectedByteCount: artifact.byteCount,
                    artifactFingerprint: artifact.fingerprint,
                    transportIdentifier: nil,
                    payloadCommittedAt: nil,
                    conversionAdopted: false,
                    staleVariantsRemoved: false,
                    coverProcessed: false,
                    coverPushed: false,
                    receiptPersisted: false
                )
            }
        } catch {
            throw DurableTransferBoundaryError.checkpointFailed(
                error.localizedDescription
            )
        }
    }

    private func checkpointDeliveryUnknown(
        _ itemID: UUID,
        detail: String
    ) {
        guard let bookID = bookIDByItemID[itemID] else { return }
        do {
            try mutateDurableItem(bookID: bookID) { item in
                guard item.state == .inFlight else { return }
                item.state = .deliveryUnknown
                item.detail = detail
            }
        } catch {
            let message =
                "Could not checkpoint unknown Kindle delivery: \(error.localizedDescription)"
            lastWarning = message
            Log.device.error("\(message, privacy: .public)")
        }
    }

    private func checkpointPayloadCommitted(
        _ itemID: UUID,
        technicalResult: DeviceTransferResult
    ) throws {
        guard let bookID = bookIDByItemID[itemID] else {
            throw DurableTransferBoundaryError.checkpointFailed(
                "The transfer item is not represented in the recovery journal."
            )
        }
        do {
            try mutateDurableItem(bookID: bookID) { item in
                guard item.state == .inFlight
                        || item.state == .deliveryUnknown,
                      var payload = item.payload else {
                    throw CocoaError(.fileWriteUnknown)
                }
                payload.transportIdentifier =
                    technicalResult.transportIdentifier
                payload.payloadCommittedAt = now()
                item.payload = payload
                item.state = .payloadCommitted
                item.detail = nil
            }
        } catch {
            throw DurableTransferBoundaryError.checkpointFailed(
                error.localizedDescription
            )
        }
    }

    private func checkpointPayload(
        _ itemID: UUID,
        _ payload: DurableTransferPayload
    ) throws {
        guard let bookID = bookIDByItemID[itemID] else {
            throw DurableTransferBoundaryError.checkpointFailed(
                "The transfer item is not represented in the recovery journal."
            )
        }
        do {
            try mutateDurableItem(bookID: bookID) { item in
                guard item.state == .payloadCommitted else {
                    throw CocoaError(.fileWriteUnknown)
                }
                item.payload = payload
            }
        } catch {
            throw DurableTransferBoundaryError.checkpointFailed(
                error.localizedDescription
            )
        }
    }

    private func mutateDurableItem(
        bookID: UUID,
        mutation: (inout DurableTransferItem) throws -> Void
    ) throws {
        guard var job = durableJob,
              let index = job.items.firstIndex(where: {
                  $0.descriptor.bookUUID == bookID
              }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try mutation(&job.items[index])
        job.updatedAt = now()
        try journalStore.save(job)
        durableJob = job
    }

    private func reconcileUnknownDeliveries(
        using inventory: DeviceInventorySnapshot?
    ) -> Bool {
        guard let inventory, var job = durableJob else {
            return durableJob?.unresolvedItems.isEmpty ?? true
        }
        var changed = false
        var hasAmbiguousItem = false
        for index in job.items.indices
            where job.items[index].state == .deliveryUnknown
                || job.items[index].state == .inFlight {
            guard var payload = job.items[index].payload else {
                hasAmbiguousItem = true
                continue
            }
            let destination = inventory.books.first {
                $0.fileName.caseInsensitiveCompare(
                    payload.destinationFileName
                ) == .orderedSame
            }
            if let destination {
                guard let expectedByteCount = payload.expectedByteCount,
                      destination.sizeBytes == expectedByteCount else {
                    hasAmbiguousItem = true
                    continue
                }
                payload.payloadCommittedAt = payload.payloadCommittedAt ?? now()
                job.items[index].payload = payload
                job.items[index].state = .payloadCommitted
                job.items[index].detail = nil
            } else {
                job.items[index].state = .pending
                job.items[index].detail = nil
                job.items[index].payload = nil
            }
            changed = true
        }
        guard changed else { return !hasAmbiguousItem }
        job.updatedAt = now()
        do {
            try journalStore.save(job)
            durableJob = job
            return !hasAmbiguousItem
        } catch {
            let message =
                "Could not save Kindle delivery reconciliation: \(error.localizedDescription)"
            lastWarning = message
            Log.device.error("\(message, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func updateDurableState(
        for itemID: UUID,
        state: DurableTransferItemState,
        detail: String?
    ) -> Bool {
        guard let bookID = bookIDByItemID[itemID],
              var job = durableJob,
              let index = job.items.firstIndex(where: {
                  $0.descriptor.bookUUID == bookID
              })
        else { return true }

        let previous = job.items[index].state
        let transitionIsAllowed = switch (previous, state) {
        case (.pending, .failed), (.pending, .cancelled),
             (.payloadCommitted, .completed):
            true
        default:
            false
        }
        guard transitionIsAllowed else { return false }
        guard previous != state || job.items[index].detail != detail else {
            return true
        }

        job.items[index].state = state
        job.items[index].detail = detail
        job.updatedAt = now()
        do {
            try journalStore.save(job)
            durableJob = job
            return true
        } catch {
            let message = "Could not update transfer recovery record: \(error.localizedDescription)"
            lastWarning = message
            Log.device.error("\(message, privacy: .public)")
            return false
        }
    }

    private func finishDurableJobIfTerminal() {
        guard durableJob?.isTerminal == true else { return }
        do {
            try journalStore.remove()
            durableJob = nil
        } catch {
            let message = "Could not remove completed transfer recovery record: \(error.localizedDescription)"
            lastWarning = message
            Log.device.error("\(message, privacy: .public)")
        }
    }

    private static func defaultJournalDirectory() -> URL {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return AppPaths.transferQueueJournalDirectory
        }
        return FileManager.default.temporaryDirectory
            .appending(path: "WinstonTransferQueueTests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    // MARK: - Bookkeeping

    private func replaceItems(
        _ newItems: [Item],
        bookIDs: [UUID]? = nil
    ) {
        items = newItems
        itemIndexByID = Dictionary(
            uniqueKeysWithValues: newItems.indices.map { (newItems[$0].id, $0) }
        )
        if let bookIDs, bookIDs.count == newItems.count {
            bookIDByItemID = Dictionary(
                uniqueKeysWithValues: zip(newItems, bookIDs).map {
                    ($0.0.id, $0.1)
                }
            )
        } else {
            bookIDByItemID = [:]
        }
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

    @discardableResult
    private func markDone(_ id: UUID) -> Bool {
        guard let index = itemIndexByID[id], items.indices.contains(index) else {
            return false
        }
        guard items[index].stage != .done else { return true }
        guard updateDurableState(
            for: id,
            state: .completed,
            detail: nil
        ) else {
            markRecoveryRequired(id)
            return false
        }
        totalProgress += 1 - items[index].progress
        items[index].progress = 1
        items[index].stage = .done
        completedItemCount += 1
        advanceActiveItem(after: index, completedID: id)
        return true
    }

    private func markFailed(_ id: UUID) {
        guard let index = itemIndexByID[id], items.indices.contains(index) else { return }
        guard items[index].stage != .failed else { return }
        if items[index].stage == .done {
            completedItemCount = max(0, completedItemCount - 1)
        }
        items[index].stage = .failed
        failedItemCount += 1
        _ = updateDurableState(for: id, state: .failed, detail: lastError)
        advanceActiveItem(after: index, completedID: id)
    }

    private func markCancelled(_ id: UUID) {
        guard let index = itemIndexByID[id], items.indices.contains(index) else { return }
        guard !Self.isTerminal(items[index].stage) else { return }
        items[index].stage = .cancelled
        _ = updateDurableState(for: id, state: .cancelled, detail: nil)
        advanceActiveItem(after: index, completedID: id)
    }

    private func markRecoveryRequired(_ id: UUID) {
        guard let index = itemIndexByID[id], items.indices.contains(index) else {
            return
        }
        guard items[index].stage != .failed else { return }
        if items[index].stage == .done {
            completedItemCount = max(0, completedItemCount - 1)
        }
        items[index].stage = .failed
        failedItemCount += 1
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
