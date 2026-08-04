import Foundation
import Observation
import OSLog

nonisolated struct KindleRemovalFeedback: Equatable, Sendable {
    nonisolated enum Style: Equatable, Sendable {
        case success
        case info
        case error
    }

    let style: Style
    let message: String

    static func make(for result: BulkOperationResult) -> KindleRemovalFeedback {
        let removed = result.appliedTargetCount
        let requested = result.plan.requestedTargetCount
        let unresolved = max(
            0,
            requested - removed - result.plan.unchangedTargetCount
        )

        switch result.outcomeKind {
        case .success where removed == 1:
            return KindleRemovalFeedback(
                style: .success,
                message: String(
                    localized: "Removed 1 book from the Kindle. Winston preserved its library copy."
                )
            )
        case .success:
            return KindleRemovalFeedback(
                style: .success,
                message: String(
                    localized: "Removed \(removed) books from the Kindle. Winston preserved their library copies."
                )
            )
        case .partialSuccess:
            return KindleRemovalFeedback(
                style: .info,
                message: String(
                    localized: "Removed \(removed) of \(requested) books from the Kindle. \(unresolved) could not be removed; Winston preserved all library copies."
                )
            )
        case .cancelled where removed == 0:
            return KindleRemovalFeedback(
                style: .info,
                message: String(
                    localized: "Kindle removal cancelled. No books were removed, and Winston preserved all library copies."
                )
            )
        case .cancelled:
            return KindleRemovalFeedback(
                style: .info,
                message: String(
                    localized: "Kindle removal cancelled after removing \(removed) of \(requested) books. Winston preserved all library copies."
                )
            )
        case .conflict:
            return KindleRemovalFeedback(
                style: .error,
                message: String(
                    localized: "No books were removed from the Kindle. \(unresolved) changed or became unavailable; Winston preserved all library copies."
                )
            )
        case .failure:
            if let detail = result.durableFailure?.detail, !detail.isEmpty {
                return KindleRemovalFeedback(
                    style: .error,
                    message: String(
                        localized: "Couldn’t remove books from the Kindle: \(detail)"
                    )
                )
            }
            return KindleRemovalFeedback(
                style: .error,
                message: String(
                    localized: "Couldn’t remove books from the Kindle. Winston preserved all library copies."
                )
            )
        }
    }
}

@MainActor
@Observable
final class DeviceMonitor {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected(DeviceInfo)
    }

    private(set) var state: State = .disconnected
    private(set) var books: [DeviceBook] = [] {
        didSet {
            publishInventoryChange(from: oldValue, to: books)
        }
    }
    private(set) var deviceFileNames: Set<String> = []
    private(set) var inventoryGeneration = 0
    private(set) var lastInventoryDelta = DeviceInventoryDelta.empty
    private(set) var connection: (any KindleDeviceConnection)?
    private(set) var lastError: String?
    private(set) var lastBulkOperationResult: BulkOperationResult?
    private(set) var deviceDeleteProgress: BulkOperationProgress?
    private(set) var isDeletingBooks = false
    private(set) var isCancellingDeviceDelete = false
    private(set) var isEjecting = false

    private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var deviceDeleteSession: BulkOperationSession?
    @ObservationIgnored private var verifiedTransfers: [String: DeviceBook] = [:]
    private var suspended = false
    private var manuallyDisconnected = false

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var info: DeviceInfo? {
        if case .connected(let info) = state { return info }
        return nil
    }

    var inventory: DeviceInventorySnapshot? {
        info.map {
            DeviceInventorySnapshot(
                generation: inventoryGeneration,
                info: $0,
                books: books
            )
        }
    }

    var booksRevision: Int { inventoryGeneration }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func suspendPolling() { suspended = true }
    func resumePolling() { suspended = false }

    func userDisconnect() async throws {
        guard let activeConnection = connection else {
            throw DeviceError.notConnected
        }
        guard !isEjecting else { return }
        isEjecting = true
        defer { isEjecting = false }
        manuallyDisconnected = true
        lastError = nil
        Log.device.info("User ejecting the device")
        do {
            try await activeConnection.eject()
            clearConnection(ifCurrent: activeConnection)
        } catch {
            let connectionChanged = !isCurrentConnection(activeConnection)
            let physicallyDisconnected = await !activeConnection.isAlive()
            if connectionChanged || physicallyDisconnected {
                clearConnection(ifCurrent: activeConnection)
                manuallyDisconnected = false
                Log.device.info(
                    "Device disappeared while eject was in flight; treating it as disconnected"
                )
                return
            }

            manuallyDisconnected = false
            lastError = error.localizedDescription
            Log.device.error(
                "User eject failed while the device remained connected: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - Polling

    private func poll() async {
        guard !suspended, !isEjecting else { return }
        if let connection {
            if await !connection.isAlive() {
                await disconnect()
            }
            return
        }
        if manuallyDisconnected {
            if !(await deviceStillPresent()) { manuallyDisconnected = false }
            return
        }
        await scanAndConnect()
    }

    private func deviceStillPresent() async -> Bool {
        await Task.detached(priority: .utility) {
            if MassStorageDeviceConnection.detectKindleVolume() != nil { return true }
            return MTPDeviceConnection.kindlePresent()
        }.value
    }

    private func scanAndConnect() async {
        let volume = await Task.detached(priority: .utility) {
            MassStorageDeviceConnection.detectKindleVolume()
        }.value
        if let volume {
            do {
                await connect(try MassStorageDeviceConnection(volumeURL: volume))
            } catch {
                state = .disconnected
                lastError = error.localizedDescription
            }
            return
        }

        let mtpPresent = await Task.detached(priority: .utility) {
            MTPDeviceConnection.kindlePresent()
        }.value

        if mtpPresent {
            let mtp = MTPDeviceConnection()
            do {
                try await mtp.connect()
                await connect(mtp)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func connect(_ newConnection: any KindleDeviceConnection) async {
        state = .connecting
        do {
            let info = try await newConnection.info()
            connection = newConnection
            lastError = nil
            // Keep the public state stable while the first inventory is read.
            // Publishing `.connected` before `books` made SwiftUI insert a
            // conditional toolbar item during AppKit's initial toolbar layout,
            // which can recurse and leave the window unresponsive.
            let inventoryLoaded = await refreshBooks()
            guard isCurrentConnection(newConnection) else { return }
            if !inventoryLoaded {
                guard await newConnection.isAlive() else {
                    clearConnection(ifCurrent: newConnection)
                    return
                }
            }
            state = .connected(info)
            Log.device.info("Connected over \(info.kind == .mtp ? "MTP" : "USB mass storage"): \(info.name, privacy: .public)")
        } catch {
            await newConnection.disconnect()
            state = .disconnected
            lastError = error.localizedDescription
        }
    }

    func disconnect() async {
        await connection?.disconnect()
        connection = nil
        verifiedTransfers = [:]
        books = []
        state = .disconnected
    }

    func adoptConnectionForTesting(_ newConnection: any KindleDeviceConnection, info: DeviceInfo) {
        verifiedTransfers = [:]
        connection = newConnection
        state = .connected(info)
    }

    private func isCurrentConnection(
        _ candidate: any KindleDeviceConnection
    ) -> Bool {
        guard let connection else { return false }
        return ObjectIdentifier(connection) == ObjectIdentifier(candidate)
    }

    private func clearConnection(
        ifCurrent candidate: any KindleDeviceConnection
    ) {
        guard isCurrentConnection(candidate) else { return }
        connection = nil
        verifiedTransfers = [:]
        books = []
        state = .disconnected
    }

    // MARK: - Books

    @discardableResult
    func refreshBooks() async -> Bool {
        guard let connection else { return false }
        do {
            let refreshed = try await connection.listBooks()
            let refreshedMatchKeys = Set(refreshed.lazy.map(\.matchKey))
            verifiedTransfers = verifiedTransfers.filter {
                !refreshedMatchKeys.contains($0.key)
            }
            let pendingVerification = verifiedTransfers.values.filter { verified in
                !refreshed.contains { listed in
                    listed.id == verified.id || listed.matchKey == verified.matchKey
                }
            }
            let merged = (refreshed + pendingVerification).sorted {
                let order = $0.fileName.localizedCaseInsensitiveCompare($1.fileName)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            guard merged != books else { return true }
            books = merged
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Publishes an already verified transport result immediately. Some Kindle
    /// transports expose a stale directory listing briefly after a write; keep
    /// the verified entry until a later listing confirms it.
    func recordVerifiedTransfer(
        _ result: DeviceTransferResult,
        deviceIdentifier: String,
        modifiedDate: Date = .now
    ) {
        guard let info, info.identifier == deviceIdentifier else { return }
        let book = DeviceBook(
            mtpItemID: info.kind == .mtp
                ? result.transportIdentifier.flatMap(UInt32.init)
                : nil,
            path: info.kind == .massStorage
                ? result.destination.relativePath
                : nil,
            fileName: result.destination.fileName,
            sizeBytes: result.bytesTransferred,
            modifiedDate: modifiedDate
        )
        verifiedTransfers[book.matchKey] = book

        var updated = books
        if let index = updated.firstIndex(where: {
            $0.id == book.id || $0.matchKey == book.matchKey
        }) {
            updated[index] = book
        } else {
            updated.append(book)
        }
        updated.sort {
            let order = $0.fileName.localizedCaseInsensitiveCompare($1.fileName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        if updated != books { books = updated }
    }

    func refreshInfo() async {
        guard let connection else { return }
        if let info = try? await connection.info() {
            let refreshed: State = .connected(info)
            if state != refreshed { state = refreshed }
        }
    }

    func removeBooksLocally(_ ids: Set<DeviceBook.ID>) {
        let removedMatchKeys = Set(
            books.lazy.filter { ids.contains($0.id) }.map(\.matchKey)
        )
        verifiedTransfers = verifiedTransfers.filter {
            !removedMatchKeys.contains($0.key)
        }
        books.removeAll { ids.contains($0.id) }
    }

    @discardableResult
    func removeFromDevice(matching keys: Set<String>) async -> Int {
        let ids = Set(books.lazy.filter { keys.contains($0.matchKey) }.map(\.id))
        return await removeFromDevice(ids: ids).appliedTargetCount
    }

    func planDeviceRemoval(ids: Set<DeviceBook.ID>) async -> BulkOperationPlan {
        let orderedIDs = ids.sorted()
        let liveIDs = Set(books.map(\.id))
        let candidates = orderedIDs.map { id -> BulkOperationCandidate in
            let targetID = BulkOperationTargetID.deviceBook(id)
            return liveIDs.contains(id)
                ? .change(targetID)
                : .conflict(targetID, reason: .missingTarget)
        }
        return await BulkOperationPlanner.shared.makePlan(
            operation: .deviceDelete,
            requestedTargetIDs: orderedIDs.map(BulkOperationTargetID.deviceBook),
            candidates: candidates,
            chunkSize: 1
        )
    }

    @discardableResult
    func removeFromDevice(
        ids: Set<DeviceBook.ID>
    ) async -> BulkOperationResult {
        let plan = await planDeviceRemoval(ids: ids)
        if isDeletingBooks || deviceDeleteSession != nil {
            let rejected = BulkOperationSession(plan: plan)
            let result = await rejected.execute { _ in
                throw BulkOperationDurableError(.operationInProgress)
            }
            lastBulkOperationResult = result
            return result
        }
        isDeletingBooks = true
        isCancellingDeviceDelete = false
        let session = BulkOperationSession(plan: plan)
        deviceDeleteSession = session
        let result = await session.execute(onProgress: { [weak self] progress in
            self?.deviceDeleteProgress = progress
        }) { [weak self] chunk in
            guard let self else {
                throw BulkOperationDurableError(.executionFailed)
            }
            guard let targetID = chunk.targetIDs.first,
                  let id = targetID.deviceBookID else {
                return BulkOperationChunkOutcome(conflicts: chunk.targetIDs.map {
                    BulkOperationConflict(targetID: $0, reason: .invalidTarget)
                })
            }
            guard let book = self.books.first(where: { $0.id == id }) else {
                return BulkOperationChunkOutcome(conflicts: [
                    BulkOperationConflict(targetID: targetID, reason: .missingTarget),
                ])
            }
            guard let connection = self.connection,
                  await connection.isAlive() else {
                await self.disconnect()
                throw BulkOperationDurableError(.deviceDisconnected)
            }
            do {
                try await connection.delete(book)
                self.removeBooksLocally([book.id])
                return .applied([targetID])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.device.error(
                    "Delete from device failed for \(book.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                if await !connection.isAlive() {
                    await self.disconnect()
                    throw BulkOperationDurableError(
                        .deviceDisconnected,
                        detail: error.localizedDescription
                    )
                }
                return BulkOperationChunkOutcome(conflicts: [
                    BulkOperationConflict(
                        targetID: targetID,
                        reason: .itemFailed,
                        detail: error.localizedDescription
                    ),
                ])
            }
        }
        if deviceDeleteSession === session {
            deviceDeleteSession = nil
            deviceDeleteProgress = nil
        }
        isDeletingBooks = false
        isCancellingDeviceDelete = false
        lastBulkOperationResult = result
        if isConnected { await refreshInfo() }
        Log.device.info(
            "Removed \(result.appliedTargetCount) book(s) from device; \(result.conflictCount) conflict(s)"
        )
        return result
    }

    func cancelDeviceDelete() {
        guard let session = deviceDeleteSession else { return }
        isCancellingDeviceDelete = true
        Task { await session.cancel() }
    }

    private func publishInventoryChange(
        from oldBooks: [DeviceBook],
        to newBooks: [DeviceBook]
    ) {
        guard oldBooks != newBooks else { return }
        let oldByID = Dictionary(
            oldBooks.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        let newByID = Dictionary(
            newBooks.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        let inserted = newByID.keys
            .filter { oldByID[$0] == nil }
            .compactMap { newByID[$0] }
            .sorted { $0.id < $1.id }
        let removed = oldByID.keys
            .filter { newByID[$0] == nil }
            .compactMap { oldByID[$0] }
            .sorted { $0.id < $1.id }
        let updated = newByID.keys
            .filter { id in
                guard let old = oldByID[id], let new = newByID[id] else {
                    return false
                }
                return old != new
            }
            .compactMap { newByID[$0] }
            .sorted { $0.id < $1.id }
        let updatedIDs = Set(updated.map(\.id))
        let changedMatchKeys = Set(
            inserted.map(\.matchKey)
                + removed.map(\.matchKey)
                + updated.map(\.matchKey)
                + updatedIDs.compactMap { oldByID[$0]?.matchKey }
        )
        let previousGeneration = inventoryGeneration
        inventoryGeneration &+= 1
        lastInventoryDelta = DeviceInventoryDelta(
            fromGeneration: previousGeneration,
            toGeneration: inventoryGeneration,
            inserted: inserted,
            updated: updated,
            removed: removed,
            changedMatchKeys: changedMatchKeys
        )
        deviceFileNames = Set(newBooks.lazy.map(\.matchKey))
    }
}
