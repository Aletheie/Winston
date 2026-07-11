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
    private(set) var books: [DeviceBook] = []
    private(set) var connection: (any KindleDeviceConnection)?
    private(set) var lastError: String?

    private var pollTask: Task<Void, Never>?
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
        if MassStorageDeviceConnection.detectKindleVolume() != nil { return true }
        return await Task.detached(priority: .utility) { MTPDeviceConnection.kindlePresent() }.value
    }

    private func scanAndConnect() async {
        if let volume = MassStorageDeviceConnection.detectKindleVolume() {
            await connect(MassStorageDeviceConnection(volumeURL: volume))
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
            books = try await connection.listBooks()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshInfo() async {
        guard let connection else { return }
        if let info = try? await connection.info() {
            state = .connected(info)
        }
    }

    func removeBooksLocally(_ ids: Set<DeviceBook.ID>) {
        books.removeAll { ids.contains($0.id) }
    }

    var deviceFileNames: Set<String> {
        Set(books.map(\.matchKey))
    }

    @discardableResult
    func removeFromDevice(matching keys: Set<String>) async -> Int {
        guard let connection, !keys.isEmpty else { return 0 }
        let targets = books.filter { keys.contains($0.matchKey) }
        guard !targets.isEmpty else { return 0 }

        var removed: Set<DeviceBook.ID> = []
        for book in targets {
            do {
                try await connection.delete(book)
                removed.insert(book.id)
            } catch {
                Log.device.error("Delete from device failed for \(book.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        removeBooksLocally(removed)
        await refreshInfo()
        Log.device.info("Removed \(removed.count) book(s) from device")
        return removed.count
    }
}
