import Darwin
import Foundation

/// Descriptor-based security boundary for an attached filesystem.
///
/// Every device path is represented as validated relative components and traversed from the
/// pinned mount descriptor with `openat(2)` plus `O_NOFOLLOW`. Directory and file descriptors
/// are checked against the mount's device identity and their live path before commit points.
nonisolated final class MountedVolumeBoundary: @unchecked Sendable {
    struct FileEntry: Sendable {
        let relativeComponents: [String]
        let name: String
        let sizeBytes: UInt64
        let modificationDate: Date?

        var relativePath: String {
            relativeComponents.joined(separator: "/")
        }
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
        }
    }

    private struct VolumeIdentity: Equatable {
        let device: UInt64
        let filesystemIDHigh: Int32
        let filesystemIDLow: Int32

        init(status: stat, filesystem: statfs) {
            device = UInt64(status.st_dev)
            filesystemIDHigh = filesystem.f_fsid.val.0
            filesystemIDLow = filesystem.f_fsid.val.1
        }
    }

    private enum Lookup {
        case missing
        case descriptor(Int32)
    }

    let rootURL: URL

    private let rootPath: String
    private var rootDescriptor: Int32
    private let rootIdentity: FileIdentity
    private let volumeIdentity: VolumeIdentity

    init(mountURL: URL) throws {
        guard mountURL.isFileURL else { throw DeviceError.unsafePath }
        let proposedPath = mountURL.path(percentEncoded: false)
        guard proposedPath.hasPrefix("/") else { throw DeviceError.unsafePath }
        var proposedStatus = stat()
        guard Darwin.lstat(proposedPath, &proposedStatus) == 0 else {
            throw Self.connectionError(errno)
        }
        guard proposedStatus.st_mode & S_IFMT == S_IFDIR else {
            throw DeviceError.unsafePath
        }

        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard proposedPath.withCString({ realpath($0, &resolved) }) != nil else {
            throw Self.connectionError(errno)
        }
        let canonicalPath = String(
            decoding: resolved
                .prefix(while: { $0 != 0 })
                .map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let descriptor = Darwin.open(
            canonicalPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw Self.connectionError(errno) }

        var status = stat()
        var filesystem = statfs()
        guard fstat(descriptor, &status) == 0,
              fstatfs(descriptor, &filesystem) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            let code = errno
            Darwin.close(descriptor)
            throw Self.pathError(code)
        }

        rootPath = canonicalPath
        rootURL = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        rootDescriptor = descriptor
        rootIdentity = FileIdentity(status)
        volumeIdentity = VolumeIdentity(status: status, filesystem: filesystem)

        do {
            try validateConnection()
            try validateOptionalDirectory(["documents"])
            try validateOptionalDirectory(["system"])
            try validateOptionalDirectory(["system", "thumbnails"])
        } catch {
            Darwin.close(descriptor)
            rootDescriptor = -1
            throw error
        }
    }

    deinit {
        if rootDescriptor >= 0 {
            Darwin.close(rootDescriptor)
        }
    }

    func isConnected() -> Bool {
        (try? validateConnection()) != nil
    }

    func directoryExists(_ components: [String]) throws -> Bool {
        switch try openDirectory(components, createIntermediates: false) {
        case .missing:
            return false
        case .descriptor(let descriptor):
            Darwin.close(descriptor)
            return true
        }
    }

    func ensureDirectory(_ components: [String]) throws {
        guard case .descriptor(let descriptor) = try openDirectory(
            components,
            createIntermediates: true
        ) else {
            throw DeviceError.fileMissing
        }
        Darwin.close(descriptor)
    }

    func relativeComponents(from path: String, requiredRoot: String) throws -> [String] {
        guard !path.hasPrefix("/") else { throw DeviceError.unsafePath }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        try Self.validate(components)
        guard components.first == requiredRoot else { throw DeviceError.unsafePath }
        return components
    }

    func listRegularFiles(
        in components: [String],
        recursively: Bool,
        includingHidden: Bool = false
    ) throws -> [FileEntry] {
        guard case .descriptor(let descriptor) = try openDirectory(
            components,
            createIntermediates: false
        ) else {
            throw DeviceError.fileMissing
        }
        defer { Darwin.close(descriptor) }

        var files: [FileEntry] = []
        try collectRegularFiles(
            directoryDescriptor: descriptor,
            components: components,
            recursively: recursively,
            includingHidden: includingHidden,
            files: &files
        )
        try validateDirectoryBinding(descriptor, components: components)
        return files
    }

    func readData(at components: [String]) throws -> Data? {
        guard let descriptor = try openRegularFile(components) else { return nil }
        defer { Darwin.close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        try validateFileBinding(descriptor, components: components)
        return data
    }

    func writeFile(
        from sourceURL: URL,
        to components: [String],
        progress: (@Sendable (Double) -> Void)? = nil,
        chunkHook: (@Sendable (Int64) throws -> Void)? = nil,
        operationCheck: (@Sendable () throws -> Void)? = nil
    ) throws {
        try operationCheck?()
        let (parentComponents, leaf) = try splitLeaf(components)
        guard case .descriptor(let parentDescriptor) = try openDirectory(
            parentComponents,
            createIntermediates: true
        ) else {
            throw DeviceError.fileMissing
        }
        defer { Darwin.close(parentDescriptor) }
        try validateDirectoryBinding(parentDescriptor, components: parentComponents)

        let sourceDescriptor = Darwin.open(
            sourceURL.path(percentEncoded: false),
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard sourceDescriptor >= 0 else { throw Self.pathError(errno) }
        defer { Darwin.close(sourceDescriptor) }
        let sourceStatus = try checkedStatus(
            of: sourceDescriptor,
            expectedKind: S_IFREG,
            requiresMountedVolume: false
        )

        let temporaryLeaf = ".winston-transfer-\(UUID().uuidString).tmp"
        let temporaryDescriptor = temporaryLeaf.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o644)
            )
        }
        guard temporaryDescriptor >= 0 else { throw Self.pathError(errno) }
        var temporaryIsOpen = true
        var temporaryWasRenamed = false
        defer {
            if temporaryIsOpen { Darwin.close(temporaryDescriptor) }
            if !temporaryWasRenamed {
                temporaryLeaf.withCString {
                    _ = Darwin.unlinkat(parentDescriptor, $0, 0)
                }
            }
        }

        try copyBytes(
            from: sourceDescriptor,
            to: temporaryDescriptor,
            totalBytes: max(0, Int64(sourceStatus.st_size)),
            progress: progress,
            chunkHook: chunkHook,
            validate: {
                try operationCheck?()
                try self.validateDirectoryBinding(
                    parentDescriptor,
                    components: parentComponents
                )
            }
        )
        guard Darwin.fsync(temporaryDescriptor) == 0 else {
            throw Self.pathError(errno)
        }
        guard Darwin.close(temporaryDescriptor) == 0 else {
            temporaryIsOpen = false
            throw Self.pathError(errno)
        }
        temporaryIsOpen = false

        try operationCheck?()
        try validateReplaceableLeaf(leaf, in: parentDescriptor)
        try validateDirectoryBinding(parentDescriptor, components: parentComponents)
        let renameResult = temporaryLeaf.withCString { temporaryPointer in
            leaf.withCString { leafPointer in
                Darwin.renameat(
                    parentDescriptor,
                    temporaryPointer,
                    parentDescriptor,
                    leafPointer
                )
            }
        }
        guard renameResult == 0 else { throw Self.pathError(errno) }
        temporaryWasRenamed = true

        try validateDirectoryBinding(parentDescriptor, components: parentComponents)
        removeRegularFileIfPresent("._" + leaf, in: parentDescriptor)
    }

    func copyFile(
        at components: [String],
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void,
        chunkHook: (@Sendable (Int64) throws -> Void)? = nil,
        operationCheck: (@Sendable () throws -> Void)? = nil
    ) throws {
        try operationCheck?()
        guard let sourceDescriptor = try openRegularFile(components) else {
            throw DeviceError.fileMissing
        }
        defer { Darwin.close(sourceDescriptor) }
        let sourceStatus = try checkedStatus(
            of: sourceDescriptor,
            expectedKind: S_IFREG,
            requiresMountedVolume: true
        )

        let destinationPath = destination.path(percentEncoded: false)
        let temporary = destination.deletingLastPathComponent().appending(
            path: ".winston-transfer-\(UUID().uuidString).tmp"
        )
        let temporaryPath = temporary.path(percentEncoded: false)
        let outputDescriptor = Darwin.open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o644)
        )
        guard outputDescriptor >= 0 else { throw Self.pathError(errno) }
        var outputIsOpen = true
        var temporaryWasRenamed = false
        defer {
            if outputIsOpen { Darwin.close(outputDescriptor) }
            if !temporaryWasRenamed { _ = Darwin.unlink(temporaryPath) }
        }

        progress(0)
        try copyBytes(
            from: sourceDescriptor,
            to: outputDescriptor,
            totalBytes: max(0, Int64(sourceStatus.st_size)),
            progress: progress,
            chunkHook: chunkHook,
            validate: {
                try operationCheck?()
                try self.validateFileBinding(
                    sourceDescriptor,
                    components: components
                )
            }
        )
        guard Darwin.fsync(outputDescriptor) == 0 else {
            throw Self.pathError(errno)
        }
        guard Darwin.close(outputDescriptor) == 0 else {
            outputIsOpen = false
            throw Self.pathError(errno)
        }
        outputIsOpen = false

        var destinationStatus = stat()
        if Darwin.lstat(destinationPath, &destinationStatus) == 0 {
            guard destinationStatus.st_mode & S_IFMT == S_IFREG else {
                throw DeviceError.unsafePath
            }
        } else if errno != ENOENT {
            throw Self.pathError(errno)
        }
        try operationCheck?()
        try validateFileBinding(sourceDescriptor, components: components)
        guard Darwin.rename(temporaryPath, destinationPath) == 0 else {
            throw Self.pathError(errno)
        }
        temporaryWasRenamed = true
        progress(1)
    }

    func deleteFile(at components: [String]) throws {
        let (parentComponents, leaf) = try splitLeaf(components)
        guard let descriptor = try openRegularFile(components) else {
            throw DeviceError.fileMissing
        }
        defer { Darwin.close(descriptor) }
        let identity = try fileIdentity(
            descriptor,
            expectedKind: S_IFREG,
            requiresMountedVolume: true
        )
        guard case .descriptor(let parentDescriptor) = try openDirectory(
            parentComponents,
            createIntermediates: false
        ) else {
            throw DeviceError.fileMissing
        }
        defer { Darwin.close(parentDescriptor) }

        try validateFileBinding(descriptor, components: components)
        var currentStatus = stat()
        let statusResult = leaf.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &currentStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard statusResult == 0,
              currentStatus.st_mode & S_IFMT == S_IFREG,
              FileIdentity(currentStatus) == identity else {
            throw DeviceError.unsafePath
        }
        let unlinkResult = leaf.withCString {
            Darwin.unlinkat(parentDescriptor, $0, 0)
        }
        guard unlinkResult == 0 else { throw Self.pathError(errno) }
        try validateDirectoryBinding(parentDescriptor, components: parentComponents)
    }

    func createEmptyFileIfMissing(at components: [String]) throws {
        let (parentComponents, leaf) = try splitLeaf(components)
        guard case .descriptor(let parentDescriptor) = try openDirectory(
            parentComponents,
            createIntermediates: true
        ) else {
            throw DeviceError.fileMissing
        }
        defer { Darwin.close(parentDescriptor) }

        var status = stat()
        let result = leaf.withCString {
            Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 {
            guard status.st_mode & S_IFMT == S_IFREG,
                  FileIdentity(status).device == rootIdentity.device else {
                throw DeviceError.unsafePath
            }
            return
        }
        guard errno == ENOENT else { throw Self.pathError(errno) }

        let descriptor = leaf.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o644)
            )
        }
        guard descriptor >= 0 else { throw Self.pathError(errno) }
        Darwin.close(descriptor)
        try validateDirectoryBinding(parentDescriptor, components: parentComponents)
    }

    private func validateOptionalDirectory(_ components: [String]) throws {
        if case .descriptor(let descriptor) = try openDirectory(
            components,
            createIntermediates: false
        ) {
            Darwin.close(descriptor)
        }
    }

    private func openDirectory(
        _ components: [String],
        createIntermediates: Bool
    ) throws -> Lookup {
        try Self.validate(components)
        try validateConnection()

        var current = Darwin.dup(rootDescriptor)
        guard current >= 0 else { throw Self.connectionError(errno) }
        do {
            for component in components {
                var next = component.withCString {
                    Darwin.openat(
                        current,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                if next < 0, errno == ENOENT, createIntermediates {
                    let mkdirResult = component.withCString {
                        Darwin.mkdirat(current, $0, mode_t(0o755))
                    }
                    if mkdirResult != 0, errno != EEXIST {
                        throw Self.pathError(errno)
                    }
                    next = component.withCString {
                        Darwin.openat(
                            current,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                        )
                    }
                }
                if next < 0 {
                    if errno == ENOENT, !createIntermediates {
                        Darwin.close(current)
                        return .missing
                    }
                    throw Self.pathError(errno)
                }
                do {
                    _ = try checkedStatus(
                        of: next,
                        expectedKind: S_IFDIR,
                        requiresMountedVolume: true
                    )
                } catch {
                    Darwin.close(next)
                    throw error
                }
                Darwin.close(current)
                current = next
            }
            return .descriptor(current)
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private func openRegularFile(_ components: [String]) throws -> Int32? {
        let (parentComponents, leaf) = try splitLeaf(components)
        guard case .descriptor(let parentDescriptor) = try openDirectory(
            parentComponents,
            createIntermediates: false
        ) else {
            return nil
        }
        defer { Darwin.close(parentDescriptor) }

        let descriptor = leaf.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw Self.pathError(errno)
        }
        do {
            _ = try checkedStatus(
                of: descriptor,
                expectedKind: S_IFREG,
                requiresMountedVolume: true
            )
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func collectRegularFiles(
        directoryDescriptor: Int32,
        components: [String],
        recursively: Bool,
        includingHidden: Bool,
        files: inout [FileEntry]
    ) throws {
        let iterationDescriptor = Darwin.dup(directoryDescriptor)
        guard iterationDescriptor >= 0,
              let directory = fdopendir(iterationDescriptor) else {
            if iterationDescriptor >= 0 { Darwin.close(iterationDescriptor) }
            throw Self.pathError(errno)
        }
        defer { closedir(directory) }

        while let entry = readdir(directory) {
            try Task.checkCancellation()
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard name != ".", name != "..",
                  includingHidden || !name.hasPrefix(".") else { continue }
            try Self.validateComponent(name)

            var status = stat()
            let statusResult = name.withCString {
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &status,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard statusResult == 0 else {
                if errno == ENOENT { continue }
                throw Self.pathError(errno)
            }
            let kind = status.st_mode & S_IFMT
            if kind == S_IFLNK {
                continue
            }
            guard FileIdentity(status).device == rootIdentity.device else {
                throw DeviceError.unsafePath
            }
            let childComponents = components + [name]
            if kind == S_IFDIR, recursively {
                guard case .descriptor(let childDescriptor) = try openDirectory(
                    childComponents,
                    createIntermediates: false
                ) else {
                    continue
                }
                defer { Darwin.close(childDescriptor) }
                try collectRegularFiles(
                    directoryDescriptor: childDescriptor,
                    components: childComponents,
                    recursively: true,
                    includingHidden: includingHidden,
                    files: &files
                )
            } else if kind == S_IFREG {
                files.append(FileEntry(
                    relativeComponents: childComponents,
                    name: name,
                    sizeBytes: UInt64(max(0, Int64(status.st_size))),
                    modificationDate: Self.modificationDate(status)
                ))
            }
        }
    }

    private func copyBytes(
        from sourceDescriptor: Int32,
        to destinationDescriptor: Int32,
        totalBytes: Int64,
        progress: (@Sendable (Double) -> Void)?,
        chunkHook: (@Sendable (Int64) throws -> Void)?,
        validate: () throws -> Void
    ) throws {
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var written: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.pathError(errno)
            }
            var offset = 0
            while offset < count {
                let writeCount = buffer.withUnsafeBytes {
                    Darwin.write(
                        destinationDescriptor,
                        $0.baseAddress?.advanced(by: offset),
                        count - offset
                    )
                }
                if writeCount < 0 {
                    if errno == EINTR { continue }
                    throw Self.pathError(errno)
                }
                offset += writeCount
            }
            written += Int64(count)
            try chunkHook?(written)
            try validate()
            if totalBytes > 0 {
                progress?(min(1, Double(written) / Double(totalBytes)))
            }
        }
        try Task.checkCancellation()
        try validate()
    }

    private func validateReplaceableLeaf(
        _ leaf: String,
        in parentDescriptor: Int32
    ) throws {
        var status = stat()
        let result = leaf.withCString {
            Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 {
            guard status.st_mode & S_IFMT == S_IFREG,
                  FileIdentity(status).device == rootIdentity.device else {
                throw DeviceError.unsafePath
            }
        } else if errno != ENOENT {
            throw Self.pathError(errno)
        }
    }

    private func removeRegularFileIfPresent(
        _ leaf: String,
        in parentDescriptor: Int32
    ) {
        var status = stat()
        let result = leaf.withCString {
            Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              status.st_mode & S_IFMT == S_IFREG,
              FileIdentity(status).device == rootIdentity.device else { return }
        leaf.withCString {
            _ = Darwin.unlinkat(parentDescriptor, $0, 0)
        }
    }

    private func validateConnection() throws {
        var pinnedStatus = stat()
        var pinnedFilesystem = statfs()
        guard fstat(rootDescriptor, &pinnedStatus) == 0,
              fstatfs(rootDescriptor, &pinnedFilesystem) == 0,
              FileIdentity(pinnedStatus) == rootIdentity,
              VolumeIdentity(
                status: pinnedStatus,
                filesystem: pinnedFilesystem
              ) == volumeIdentity,
              pinnedStatus.st_mode & S_IFMT == S_IFDIR else {
            throw DeviceError.notConnected
        }

        let currentDescriptor = Darwin.open(
            rootPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard currentDescriptor >= 0 else {
            throw Self.connectionError(errno)
        }
        defer { Darwin.close(currentDescriptor) }
        var currentStatus = stat()
        var currentFilesystem = statfs()
        guard fstat(currentDescriptor, &currentStatus) == 0,
              fstatfs(currentDescriptor, &currentFilesystem) == 0,
              FileIdentity(currentStatus) == rootIdentity,
              VolumeIdentity(
                status: currentStatus,
                filesystem: currentFilesystem
              ) == volumeIdentity else {
            throw DeviceError.notConnected
        }
    }

    private func validateDirectoryBinding(
        _ descriptor: Int32,
        components: [String]
    ) throws {
        let expected = try fileIdentity(
            descriptor,
            expectedKind: S_IFDIR,
            requiresMountedVolume: true
        )
        guard case .descriptor(let currentDescriptor) = try openDirectory(
            components,
            createIntermediates: false
        ) else {
            throw DeviceError.unsafePath
        }
        defer { Darwin.close(currentDescriptor) }
        let current = try fileIdentity(
            currentDescriptor,
            expectedKind: S_IFDIR,
            requiresMountedVolume: true
        )
        guard current == expected else { throw DeviceError.unsafePath }
    }

    private func validateFileBinding(
        _ descriptor: Int32,
        components: [String]
    ) throws {
        let expected = try fileIdentity(
            descriptor,
            expectedKind: S_IFREG,
            requiresMountedVolume: true
        )
        guard let currentDescriptor = try openRegularFile(components) else {
            throw DeviceError.unsafePath
        }
        defer { Darwin.close(currentDescriptor) }
        let current = try fileIdentity(
            currentDescriptor,
            expectedKind: S_IFREG,
            requiresMountedVolume: true
        )
        guard current == expected else { throw DeviceError.unsafePath }
    }

    private func checkedStatus(
        of descriptor: Int32,
        expectedKind: mode_t,
        requiresMountedVolume: Bool
    ) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw Self.pathError(errno)
        }
        guard status.st_mode & S_IFMT == expectedKind else {
            throw DeviceError.unsafePath
        }
        if requiresMountedVolume {
            var filesystem = statfs()
            guard fstatfs(descriptor, &filesystem) == 0,
                  VolumeIdentity(
                    status: status,
                    filesystem: filesystem
                  ) == volumeIdentity else {
                throw DeviceError.unsafePath
            }
        }
        return status
    }

    private func fileIdentity(
        _ descriptor: Int32,
        expectedKind: mode_t,
        requiresMountedVolume: Bool
    ) throws -> FileIdentity {
        FileIdentity(try checkedStatus(
            of: descriptor,
            expectedKind: expectedKind,
            requiresMountedVolume: requiresMountedVolume
        ))
    }

    private func splitLeaf(_ components: [String]) throws -> ([String], String) {
        try Self.validate(components)
        guard let leaf = components.last else { throw DeviceError.invalidFileName }
        return (Array(components.dropLast()), leaf)
    }

    private static func validate(_ components: [String]) throws {
        guard !components.isEmpty else { return }
        for component in components {
            try validateComponent(component)
        }
    }

    private static func validateComponent(_ component: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.contains("\0"),
              component.utf8.count <= Int(NAME_MAX) else {
            throw DeviceError.unsafePath
        }
    }

    private static func modificationDate(_ status: stat) -> Date {
        Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    private static func pathError(_ code: Int32) -> Error {
        switch code {
        case ELOOP, ENOTDIR, EXDEV:
            DeviceError.unsafePath
        case ENODEV, ESTALE:
            DeviceError.notConnected
        default:
            NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    private static func connectionError(_ code: Int32) -> Error {
        switch code {
        case ELOOP, ENOTDIR:
            DeviceError.unsafePath
        default:
            DeviceError.notConnected
        }
    }
}
