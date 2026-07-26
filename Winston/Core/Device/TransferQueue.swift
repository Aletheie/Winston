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
        let drmProtected: Bool
        let generationIsCurrent: @MainActor @Sendable () -> Bool

        var uuid: UUID { descriptor.bookUUID }
        var displayName: String { descriptor.displayName }
        var targetFileName: String { descriptor.targetFileName }
        var fileUnavailable: Bool { descriptor.fileUnavailable }
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
    private(set) var activePlan: BulkOperationPlan?
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
            activeSession = nil
            activePlan = nil
            isTransferring = false
            sendTask = nil
            scheduleClear()
        }

        lastError = nil
        replaceItems(requests.map { Item(displayName: $0.displayName, direction: .toDevice) })
        let plan = await Self.makePlan(for: requests)
        activePlan = plan
        let session = BulkOperationSession(plan: plan)
        activeSession = session
        let requestsByTarget = Dictionary(
            uniqueKeysWithValues: requests.map {
                (BulkOperationTargetID.catalogBook($0.uuid), $0)
            }
        )
        let itemIDsByTarget = Dictionary(
            uniqueKeysWithValues: zip(requests, items).map {
                (BulkOperationTargetID.catalogBook($0.0.uuid), $0.1.id)
            }
        )
        for conflict in plan.conflicts {
            if let itemID = itemIDsByTarget[conflict.targetID] {
                markFailed(itemID)
            }
            lastError = Self.message(for: conflict.reason)
        }

        Log.device.info(
            "Send plan: \(plan.affectedTargetCount) change(s), \(plan.conflictCount) conflict(s)"
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
                  let request = requestsByTarget[targetID],
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
            guard request.generationIsCurrent() else {
                self.lastError = TransferArtifactError.sourceChanged.localizedDescription
                self.markFailed(itemID)
                return BulkOperationChunkOutcome(conflicts: [
                    BulkOperationConflict(
                        targetID: targetID,
                        reason: .sourceChanged,
                        detail: self.lastError
                    ),
                ])
            }
            guard await connection.isAlive() else {
                self.lastError = "Device disconnected"
                self.markFailed(itemID)
                await monitor.disconnect()
                throw BulkOperationDurableError(.deviceDisconnected)
            }

            let preparedArtifact: MaterializedTransferArtifact
            self.setStage(.preparing, for: itemID)
            do {
                let artifact = try await TransferArtifact.prepare(
                    descriptor: request.descriptor
                )
                guard request.generationIsCurrent(),
                      artifact.sourceGenerationIsCurrent() else {
                    throw TransferArtifactError.sourceChanged
                }
                preparedArtifact = try await artifact.materialize(in: stagingDirectory)
                guard request.generationIsCurrent(),
                      artifact.sourceGenerationIsCurrent() else {
                    throw TransferArtifactError.sourceChanged
                }
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
                request,
                preparedArtifact: preparedArtifact,
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
        _ request: SendRequest,
        preparedArtifact: MaterializedTransferArtifact,
        itemID: UUID,
        connection: any KindleDeviceConnection,
        deviceInfo: DeviceInfo
    ) async throws -> BulkOperationConflict? {
        let targetID = BulkOperationTargetID.catalogBook(request.uuid)
        if request.fileUnavailable {
            lastError = "File unavailable"
            markFailed(itemID)
            return BulkOperationConflict(targetID: targetID, reason: .unavailable)
        }
        if request.drmProtected {
            lastError = "DRM-protected"
            toasts.error(String(localized: "\u{201C}\(request.displayName)\u{201D} is DRM\u{2011}protected and can't be sent."))
            markFailed(itemID)
            return BulkOperationConflict(targetID: targetID, reason: .drmProtected)
        }
        guard request.generationIsCurrent(),
              preparedArtifact.artifact.sourceGenerationIsCurrent() else {
            lastError = TransferArtifactError.sourceChanged.localizedDescription
            markFailed(itemID)
            return BulkOperationConflict(
                targetID: targetID,
                reason: .sourceChanged,
                detail: lastError
            )
        }

        var sourceURL = preparedArtifact.sourceURL
        var temporaryConversion: URL?
        var shouldAdoptConversion = false
        defer {
            if let temporaryConversion { try? FileManager.default.removeItem(at: temporaryConversion) }
        }

        if EbookConverter.needsConversion(format: preparedArtifact.artifact.sourceFormat) {
            setStage(.converting, for: itemID)
            do {
                sourceURL = try await EbookConverter.convertForKindle(sourceURL)
                temporaryConversion = sourceURL
                shouldAdoptConversion = preparedArtifact.artifact.sourceIsPrimary
            } catch {
                if error is CancellationError {
                    markCancelled(itemID)
                    throw CancellationError()
                }
                Log.device.error("Convert-for-Kindle failed for \(request.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
                markFailed(itemID)
                return BulkOperationConflict(
                    targetID: targetID,
                    reason: .itemFailed,
                    detail: error.localizedDescription
                )
            }
        }

        guard request.generationIsCurrent(),
              preparedArtifact.artifact.sourceGenerationIsCurrent() else {
            lastError = TransferArtifactError.sourceChanged.localizedDescription
            markFailed(itemID)
            return BulkOperationConflict(
                targetID: targetID,
                reason: .sourceChanged,
                detail: lastError
            )
        }
        guard !Task.isCancelled else {
            markCancelled(itemID)
            throw CancellationError()
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
            if shouldAdoptConversion {
                await onConversionArtifact?(request.uuid, sourceURL)
            }
            try await connection.removeStaleVariants(baseName: base, keeping: fileName)
            let coverPushed = await pushThumbnail(
                for: preparedArtifact.artifact.coverOwner,
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
                coverIdentity: coverPushed
                    ? preparedArtifact.artifact.coverOwner.generationKey
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

    private static func makePlan(
        for requests: [SendRequest]
    ) async -> BulkOperationPlan {
        let targetGroups = Dictionary(grouping: requests) {
            $0.targetFileName.lowercased()
        }
        let conflictingBookIDs = Set(targetGroups.values.flatMap { group -> [UUID] in
            Set(group.map(\.uuid)).count > 1 ? group.map(\.uuid) : []
        })
        let candidates = requests.map { request -> BulkOperationCandidate in
            let targetID = BulkOperationTargetID.catalogBook(request.uuid)
            if conflictingBookIDs.contains(request.uuid) {
                return .conflict(targetID, reason: .destinationCollision)
            }
            if request.fileUnavailable {
                return .conflict(targetID, reason: .unavailable)
            }
            if request.drmProtected {
                return .conflict(targetID, reason: .drmProtected)
            }
            return .change(targetID)
        }
        return await BulkOperationPlanner.shared.makePlan(
            operation: .deviceSend,
            requestedTargetIDs: requests.map {
                BulkOperationTargetID.catalogBook($0.uuid)
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
        case .sourceUnavailable, .stagingFailed:
            return .itemFailed
        }
    }

    private static func makeRequests(for books: [Book]) -> [SendRequest] {
        var seenBookIDs: Set<UUID> = []
        return books.compactMap { book in
            guard seenBookIDs.insert(book.uuid).inserted else { return nil }
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
        let expectedCoverOwner = descriptor.coverOwner
        let expectedCoverVersion = descriptor.coverVersion
        let expectedDRMProtected = descriptor.drmProtected
        let expectedSourceFileGeneration = TransferFileGeneration.capture(
            at: descriptor.sourceURL
        )
        return SendRequest(
            descriptor: descriptor,
            drmProtected: descriptor.drmProtected,
            generationIsCurrent: { [book] in
                if bookWasAttached, book.modelContext == nil { return false }
                guard book.uuid == descriptor.bookUUID,
                      book.originalFileName == expectedOriginalFileName,
                      book.coverReference.owner == expectedCoverOwner,
                      book.coverReference.version == expectedCoverVersion,
                      TransferFileGeneration.capture(at: descriptor.sourceURL)
                        == expectedSourceFileGeneration else { return false }
                if generation.isCatalogued {
                    guard let asset = book.assets.first(where: { $0.uuid == generation.assetID }) else {
                        return false
                    }
                    return asset.fileName == generation.fileName
                        && asset.format == generation.format
                        && asset.validationStatus == generation.validationStatus
                        && asset.availability == generation.availability
                        && asset.origin == generation.origin
                        && asset.contentHash == generation.contentHash
                        && asset.sizeBytes == generation.sizeBytes
                        && asset.dateAdded == generation.dateAdded
                        && asset.generatedFromContentHash == generation.generatedFromContentHash
                        && (asset.drmProtected == true) == expectedDRMProtected
                }
                return book.fileName == generation.fileName
                    && book.format == generation.format
                    && book.fileSizeBytes == generation.sizeBytes
                    && book.dateAdded == generation.dateAdded
                    && (book.primaryDRMProtected == true) == expectedDRMProtected
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
              request.generationIsCurrent() else {
            lastError = TransferArtifactError.sourceChanged.localizedDescription
            markFailed(item.id)
            return false
        }
        let preparedArtifact: MaterializedTransferArtifact
        setStage(.preparing, for: item.id)
        do {
            let artifact = try await TransferArtifact.prepare(
                descriptor: request.descriptor
            )
            guard request.generationIsCurrent(),
                  artifact.sourceGenerationIsCurrent() else {
                throw TransferArtifactError.sourceChanged
            }
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
            for: preparedArtifact.artifact.coverOwner,
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
                coverIdentity: preparedArtifact.artifact.coverOwner.generationKey,
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
