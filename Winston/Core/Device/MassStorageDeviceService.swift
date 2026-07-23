import Foundation
import AppKit
import OSLog
import os

actor MassStorageDeviceConnection: KindleDeviceConnection {
    private let volumeURL: URL
    private let boundary: MountedVolumeBoundary
    private let copyChunkHook: (@Sendable (Int64) throws -> Void)?
    private let connectionState = OSAllocatedUnfairLock<Bool>(initialState: true)

    init(
        volumeURL: URL,
        copyChunkHook: (@Sendable (Int64) throws -> Void)? = nil
    ) throws {
        let boundary = try MountedVolumeBoundary(mountURL: volumeURL)
        self.boundary = boundary
        self.volumeURL = boundary.rootURL
        self.copyChunkHook = copyChunkHook
    }

    // MARK: - Detection

    nonisolated static func detectKindleVolume() -> URL? {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        for volume in volumes {
            let values = try? volume.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsRemovable == true else { continue }

            guard let boundary = try? MountedVolumeBoundary(mountURL: volume) else {
                continue
            }
            let name = values?.volumeName ?? ""
            let hasDocuments = (try? boundary.directoryExists(["documents"])) == true
            let hasSystem = (try? boundary.directoryExists(["system"])) == true

            if name.localizedCaseInsensitiveContains("kindle") || (hasDocuments && hasSystem) {
                return boundary.rootURL
            }
        }
        return nil
    }

    // MARK: - KindleDeviceConnection

    func info() throws -> DeviceInfo {
        try ensureConnected()
        let values = try? volumeURL.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeUUIDStringKey,
        ])
        let name = values?.volumeName ?? "Kindle"
        return DeviceInfo(
            name: name,
            model: name,
            kind: .massStorage,
            totalBytes: UInt64(values?.volumeTotalCapacity ?? 0),
            freeBytes: UInt64(values?.volumeAvailableCapacity ?? 0),
            identifier: values?.volumeUUIDString.map { "usb:\($0)" }
        )
    }

    func listBooks() throws -> [DeviceBook] {
        try ensureConnected()
        let files: [MountedVolumeBoundary.FileEntry]
        do {
            files = try boundary.listRegularFiles(
                in: ["documents"],
                recursively: true
            )
        } catch DeviceError.fileMissing {
            throw DeviceError.listFailed
        }
        return files.compactMap { file in
            let fileExtension = (file.name as NSString).pathExtension.lowercased()
            guard deviceBookExtensions.contains(fileExtension) else { return nil }
            return DeviceBook(
                mtpItemID: nil,
                path: file.relativePath,
                fileName: file.name,
                sizeBytes: file.sizeBytes,
                modifiedDate: file.modificationDate
            )
        }
        .sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
    }

    func send(fileURL: URL, fileName: String, progress: @escaping @Sendable (Double) -> Void) throws {
        try ensureConnected()
        guard let leaf = ManagedLeafName(rawValue: fileName) else {
            throw DeviceError.invalidFileName
        }
        try boundary.ensureDirectory(["documents"])
        suppressSpotlight()
        Log.device.info("Copying \(fileName, privacy: .public) to the mounted volume")
        progress(0)
        try boundary.writeFile(
            from: fileURL,
            to: ["documents", leaf.rawValue],
            progress: progress,
            chunkHook: copyChunkHook,
            operationCheck: { [self] in try ensureExplicitConnection() }
        )
        progress(1)
    }

    private func suppressSpotlight() {
        try? boundary.createEmptyFileIfMissing(at: [".metadata_never_index"])
    }

    func removeStaleVariants(baseName: String, keeping fileName: String) throws {
        try ensureConnected()
        let keepLower = fileName.lowercased()
        let baseLower = baseName.lowercased()
        let entries = try boundary.listRegularFiles(
            in: ["documents"],
            recursively: false
        )
        for entry in entries {
            guard deviceBookExtensions.contains((entry.name as NSString).pathExtension.lowercased()),
                  entry.name.lowercased() != keepLower,
                  (entry.name as NSString).deletingPathExtension.lowercased() == baseLower else {
                continue
            }
            try boundary.deleteFile(at: entry.relativeComponents)
            Log.device.info("Removed stale variant \(entry.name, privacy: .public)")
        }
    }

    func removeAppleDoubleSidecars() async throws -> Int {
        try ensureConnected()
        let sidecars = try boundary.listRegularFiles(
            in: ["documents"],
            recursively: true,
            includingHidden: true
        ).filter { $0.name.hasPrefix("._") }
        var removed = 0
        for (index, sidecar) in sidecars.enumerated() {
            try Task.checkCancellation()
            if index > 0, index.isMultiple(of: 128) {
                await Task.yield()
            }
            try ensureConnected()
            try boundary.deleteFile(at: sidecar.relativeComponents)
            removed += 1
        }
        Log.device.info("Removed \(removed) AppleDouble sidecar file(s)")
        return removed
    }

    func eject() async {
        defer { markDisconnected() }
        guard (try? ensureConnected()) != nil else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
            Log.device.info("Ejected mass-storage volume \(self.volumeURL.lastPathComponent, privacy: .public)")
        } catch {
            Log.device.error("Eject failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func copyBook(_ book: DeviceBook, to destination: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        try ensureConnected()
        guard let path = book.path else { throw DeviceError.fileMissing }
        let components = try boundary.relativeComponents(
            from: path,
            requiredRoot: "documents"
        )
        try boundary.copyFile(
            at: components,
            to: destination,
            progress: progress,
            chunkHook: copyChunkHook,
            operationCheck: { [self] in try ensureExplicitConnection() }
        )
    }

    func delete(_ book: DeviceBook) throws {
        try ensureConnected()
        guard let path = book.path else { throw DeviceError.fileMissing }
        try boundary.deleteFile(at: boundary.relativeComponents(
            from: path,
            requiredRoot: "documents"
        ))
    }

    func readClippingsText() throws -> String? {
        try ensureConnected()
        for name in ["My Clippings.txt", "My clippings.txt"] {
            if let data = try boundary.readData(at: ["documents", name]) {
                return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            }
        }
        return nil
    }

    func pushCoverThumbnail(_ fileURL: URL, named name: String) throws {
        try ensureConnected()
        guard let leaf = ManagedLeafName(rawValue: name) else { throw DeviceError.invalidFileName }
        Log.device.info("Writing cover thumbnail \(leaf.rawValue, privacy: .public)")
        try boundary.writeFile(
            from: fileURL,
            to: ["system", "thumbnails", leaf.rawValue],
            chunkHook: copyChunkHook,
            operationCheck: { [self] in try ensureExplicitConnection() }
        )
    }

    func isAlive() -> Bool {
        connectionState.withLock { $0 } && boundary.isConnected()
    }

    nonisolated func disconnect() async {
        markDisconnected()
    }

    private func ensureConnected() throws {
        try ensureExplicitConnection()
        guard boundary.isConnected() else { throw DeviceError.notConnected }
    }

    private nonisolated func ensureExplicitConnection() throws {
        guard connectionState.withLock({ $0 }) else {
            throw DeviceError.notConnected
        }
    }

    private nonisolated func markDisconnected() {
        connectionState.withLock { $0 = false }
    }
}
