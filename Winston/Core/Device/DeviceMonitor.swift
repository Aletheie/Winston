import Foundation
import Observation
import OSLog

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
            deviceFileNames = Set(books.lazy.map(\.matchKey))
            booksRevision &+= 1
        }
    }
    private(set) var deviceFileNames: Set<String> = []
    private(set) var booksRevision = 0
    private(set) var connection: (any KindleDeviceConnection)?
    private(set) var lastError: String?
    private(set) var lastBulkOperationResult: BulkOperationResult?

    private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var deviceDeleteSession: BulkOperationSession?
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

    func userDisconnect() async {
        manuallyDisconnected = true
        Log.device.info("User ejecting the device")
        await connection?.eject()
        connection = nil
        books = []
        state = .disconnected
    }

    // MARK: - Polling

    private func poll() async {
        guard !suspended else { return }
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
            state = .connected(info)
            lastError = nil
            Log.device.info("Connected over \(info.kind == .mtp ? "MTP" : "USB mass storage"): \(info.name, privacy: .public)")
            await refreshBooks()
        } catch {
            await newConnection.disconnect()
            state = .disconnected
            lastError = error.localizedDescription
        }
    }

    func disconnect() async {
        await connection?.disconnect()
        connection = nil
        books = []
        state = .disconnected
    }

    func adoptConnectionForTesting(_ newConnection: any KindleDeviceConnection, info: DeviceInfo) {
        connection = newConnection
        state = .connected(info)
    }

    // MARK: - Books

    func refreshBooks() async {
        guard let connection else { return }
        do {
            let refreshed = try await connection.listBooks()
            guard refreshed != books else { return }
            books = refreshed
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshInfo() async {
        guard let connection else { return }
        if let info = try? await connection.info() {
            let refreshed: State = .connected(info)
            if state != refreshed { state = refreshed }
        }
    }

    func removeBooksLocally(_ ids: Set<DeviceBook.ID>) {
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
        if deviceDeleteSession != nil {
            let rejected = BulkOperationSession(plan: plan)
            let result = await rejected.execute { _ in
                throw BulkOperationDurableError(.operationInProgress)
            }
            lastBulkOperationResult = result
            return result
        }
        let session = BulkOperationSession(plan: plan)
        deviceDeleteSession = session
        let result = await session.execute { [weak self] chunk in
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
        }
        lastBulkOperationResult = result
        if isConnected { await refreshInfo() }
        Log.device.info(
            "Removed \(result.appliedTargetCount) book(s) from device; \(result.conflictCount) conflict(s)"
        )
        return result
    }

    func cancelDeviceDelete() {
        guard let session = deviceDeleteSession else { return }
        Task { await session.cancel() }
    }
}
