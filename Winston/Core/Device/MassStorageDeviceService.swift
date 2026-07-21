import Foundation
import AppKit
import OSLog

actor MassStorageDeviceConnection: KindleDeviceConnection {
    private let volumeURL: URL
    private let copyChunkHook: (@Sendable (Int64) throws -> Void)?

    init(
        volumeURL: URL,
        copyChunkHook: (@Sendable (Int64) throws -> Void)? = nil
    ) {
        self.volumeURL = volumeURL
        self.copyChunkHook = copyChunkHook
    }

    private var documentsURL: URL {
        volumeURL.appending(path: "documents", directoryHint: .isDirectory)
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

            let name = values?.volumeName ?? ""
            let hasDocuments = FileManager.default.fileExists(
                atPath: volume.appending(path: "documents").path(percentEncoded: false))
            let hasSystem = FileManager.default.fileExists(
                atPath: volume.appending(path: "system").path(percentEncoded: false))

            if name.localizedCaseInsensitiveContains("kindle") || (hasDocuments && hasSystem) {
                return volume
            }
        }
        return nil
    }

    // MARK: - KindleDeviceConnection

    func info() throws -> DeviceInfo {
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
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: documentsURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw DeviceError.listFailed
        }

        var books: [DeviceBook] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard deviceBookExtensions.contains(ext) else { continue }
            let values = try? fileURL.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            books.append(DeviceBook(
                mtpItemID: nil,
                path: fileURL.path(percentEncoded: false),
                fileName: fileURL.lastPathComponent,
                sizeBytes: UInt64(values?.fileSize ?? 0),
                modifiedDate: values?.contentModificationDate
            ))
        }
        return books.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
    }

    func send(fileURL: URL, fileName: String, progress: @escaping @Sendable (Double) -> Void) throws {
        guard let leaf = ManagedLeafName(rawValue: fileName),
              let destination = leaf.appending(to: documentsURL) else {
            throw DeviceError.invalidFileName
        }
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        suppressSpotlight()
        Log.device.info("Copying \(fileName, privacy: .public) → \(destination.path(percentEncoded: false), privacy: .public)")
        progress(0)
        try writeClean(from: fileURL, to: destination, progress: progress)
        progress(1)
    }

    // AppleDouble ._ sidecars confuse the Kindle indexer — write raw bytes and strip them.
    private func writeClean(
        from source: URL,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent().appending(
            path: ".winston-transfer-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }

        guard fileManager.createFile(atPath: temporary.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: temporary)
        defer {
            try? input.close()
            try? output.close()
        }

        let total = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var written: Int64 = 0
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
            written += Int64(chunk.count)
            try copyChunkHook?(written)
            if total > 0 { progress?(min(1, Double(written) / Double(total))) }
        }
        try output.synchronize()
        try Task.checkCancellation()
        try output.close()

        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw DeviceError.unsafePath }
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }

        let sidecar = destination.deletingLastPathComponent()
            .appending(path: "._" + destination.lastPathComponent)
        try? fileManager.removeItem(at: sidecar)
    }

    private func suppressSpotlight() {
        let marker = volumeURL.appending(path: ".metadata_never_index")
        if !FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) {
            try? Data().write(to: marker)
        }
    }

    func removeStaleVariants(baseName: String, keeping fileName: String) {
        let keepLower = fileName.lowercased()
        let baseLower = baseName.lowercased()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: documentsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for url in entries {
            guard deviceBookExtensions.contains(url.pathExtension.lowercased()),
                  url.lastPathComponent.lowercased() != keepLower,
                  url.deletingPathExtension().lastPathComponent.lowercased() == baseLower else { continue }
            try? FileManager.default.removeItem(at: url)
            Log.device.info("Removed stale variant \(url.lastPathComponent, privacy: .public)")
        }
    }

    func removeAppleDoubleSidecars() async throws -> Int {
        let root = documentsURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: root) else {
            throw DeviceError.notConnected
        }
        let removed = try await Self.removeSidecars(inDirectory: root)
        Log.device.info("Removed \(removed) AppleDouble sidecar file(s)")
        return removed
    }

    private static func removeSidecars(inDirectory path: String) async throws -> Int {
        try Task.checkCancellation()
        let entries = entryNames(inDirectory: path)
        var removed = 0
        for (index, name) in entries.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
                await Task.yield()
            }
            let full = path + "/" + name

            var status = stat()
            guard lstat(full, &status) == 0 else { continue }
            let kind = status.st_mode & S_IFMT

            if kind == S_IFDIR {
                removed += try await removeSidecars(inDirectory: full)
            } else if kind == S_IFREG && name.hasPrefix("._") {
                if unlink(full) == 0 {
                    removed += 1
                } else {
                    Log.device.error("Could not remove \(name, privacy: .public): errno \(errno)")
                }
            }
        }
        try Task.checkCancellation()
        return removed
    }

    private static func entryNames(inDirectory path: String) -> [String] {
        guard let directory = opendir(path) else { return [] }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            if Task.isCancelled { break }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        return names
    }

    func eject() async {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
            Log.device.info("Ejected mass-storage volume \(self.volumeURL.lastPathComponent, privacy: .public)")
        } catch {
            Log.device.error("Eject failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func copyBook(_ book: DeviceBook, to destination: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        guard let path = book.path else { throw DeviceError.fileMissing }
        let source = try containedDeviceURL(forPath: path)
        progress(0)
        try writeClean(from: source, to: destination, progress: progress)
        progress(1)
    }

    func delete(_ book: DeviceBook) throws {
        guard let path = book.path else { throw DeviceError.fileMissing }
        try FileManager.default.removeItem(at: containedDeviceURL(forPath: path))
    }

    func readClippingsText() throws -> String? {
        for name in ["documents/My Clippings.txt", "documents/My clippings.txt"] {
            let url = volumeURL.appending(path: name)
            if let data = try? Data(contentsOf: url) {
                return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            }
        }
        return nil
    }

    func pushCoverThumbnail(_ fileURL: URL, named name: String) throws {
        guard let leaf = ManagedLeafName(rawValue: name) else { throw DeviceError.invalidFileName }
        let thumbsDir = volumeURL.appending(path: "system/thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        guard let dest = leaf.appending(to: thumbsDir) else { throw DeviceError.invalidFileName }
        Log.device.info("Cover thumbnail → \(dest.path(percentEncoded: false), privacy: .public)")
        try writeClean(from: fileURL, to: dest)
    }

    private func containedDeviceURL(forPath path: String) throws -> URL {
        let root = documentsURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path(percentEncoded: false) + "/"
        guard candidate.path(percentEncoded: false).hasPrefix(rootPath) else {
            throw DeviceError.unsafePath
        }
        return candidate
    }

    func isAlive() -> Bool {
        FileManager.default.fileExists(atPath: volumeURL.path(percentEncoded: false))
    }

    func disconnect() { }
}
