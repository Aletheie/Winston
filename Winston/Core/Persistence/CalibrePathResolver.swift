import Foundation

nonisolated enum CalibrePathError: String, Error, Equatable, Sendable {
    case invalidLibraryRoot
    case absoluteBookPath
    case traversalComponent
    case invalidPathComponent
    case invalidFileName
    case unsupportedFormat
    case pathOutsideLibrary
    case symbolicLink
    case missingFile
    case parentNotDirectory
    case notRegularFile
    case extensionMismatch
    case unreadablePath
    case sourceChanged

    var isSecurityViolation: Bool {
        switch self {
        case .absoluteBookPath, .traversalComponent, .invalidPathComponent,
             .invalidFileName, .unsupportedFormat, .pathOutsideLibrary,
             .symbolicLink, .parentNotDirectory, .notRegularFile,
             .extensionMismatch, .sourceChanged:
            true
        case .invalidLibraryRoot, .missingFile, .unreadablePath:
            false
        }
    }
}

nonisolated struct CalibreSourceFile: Sendable, Equatable {
    let url: URL
    let declaredFormat: String

    fileprivate let canonicalLibraryRoot: URL
    fileprivate let rawRelativeBookPath: String
    fileprivate let rawFileName: String
    fileprivate let identity: Identity

    fileprivate struct Identity: Sendable, Equatable {
        let resourceIdentifier: String?
        let fileSize: Int?
        let contentModificationDate: Date?
    }

    /// Resolves the untrusted database values again immediately before import.
    /// This rejects a file or directory that became a symlink after the initial scan.
    func revalidatedURL() throws -> URL {
        let resolver = try CalibrePathResolver(
            canonicalLibraryRoot: canonicalLibraryRoot,
            supportedFormats: [declaredFormat]
        )
        let current = try resolver.resolve(
            rawRelativeBookPath: rawRelativeBookPath,
            rawFileName: rawFileName,
            declaredFormat: declaredFormat
        )
        guard current.identity == identity else { throw CalibrePathError.sourceChanged }
        return current.url
    }
}

/// The only boundary that turns path-like values from Calibre's metadata.db into
/// a file URL that Winston may read. Internal symlinks are deliberately rejected,
/// even when their current destination happens to remain inside the library.
nonisolated struct CalibrePathResolver: Sendable {
    let canonicalLibraryRoot: URL
    private let supportedFormats: Set<String>

    init(libraryRoot: URL, supportedFormats: [String]) throws {
        guard libraryRoot.isFileURL else { throw CalibrePathError.invalidLibraryRoot }
        let root = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try root.resourceValues(forKeys: [.isDirectoryKey])
        } catch {
            throw CalibrePathError.invalidLibraryRoot
        }
        guard values.isDirectory == true else { throw CalibrePathError.invalidLibraryRoot }
        try self.init(canonicalLibraryRoot: root, supportedFormats: supportedFormats)
    }

    fileprivate init(canonicalLibraryRoot: URL, supportedFormats: [String]) throws {
        guard canonicalLibraryRoot.isFileURL else { throw CalibrePathError.invalidLibraryRoot }
        let root = canonicalLibraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try root.resourceValues(forKeys: [.isDirectoryKey])
        } catch {
            throw CalibrePathError.invalidLibraryRoot
        }
        guard values.isDirectory == true else { throw CalibrePathError.invalidLibraryRoot }
        self.canonicalLibraryRoot = root
        self.supportedFormats = Set(supportedFormats.map { $0.lowercased() })
    }

    func resolve(
        rawRelativeBookPath: String,
        rawFileName: String,
        declaredFormat: String
    ) throws -> CalibreSourceFile {
        let format = declaredFormat.lowercased()
        guard supportedFormats.contains(format), Self.isSafeFormat(format) else {
            throw CalibrePathError.unsupportedFormat
        }
        guard Self.isSafeLeaf(rawFileName) else { throw CalibrePathError.invalidFileName }

        let pathComponents = try Self.relativeComponents(of: rawRelativeBookPath)
        var parent = canonicalLibraryRoot
        for component in pathComponents {
            parent = parent.appending(path: component, directoryHint: .isDirectory).standardizedFileURL
            try ensureContained(parent)
            let values = try resourceValues(
                at: parent,
                keys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else { throw CalibrePathError.symbolicLink }
            guard values.isDirectory == true else { throw CalibrePathError.parentNotDirectory }
            try ensureContained(parent.resolvingSymlinksInPath())
        }

        let leafName = "\(rawFileName).\(format)"
        guard Self.isSafeLeaf(leafName) else { throw CalibrePathError.invalidFileName }
        let candidate = parent.appending(path: leafName).standardizedFileURL
        try ensureContained(candidate)

        let values = try resourceValues(
            at: candidate,
            keys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileResourceIdentifierKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]
        )
        guard values.isSymbolicLink != true else { throw CalibrePathError.symbolicLink }

        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        try ensureContained(resolved)
        guard values.isRegularFile == true else { throw CalibrePathError.notRegularFile }
        guard resolved.pathExtension.caseInsensitiveCompare(format) == .orderedSame else {
            throw CalibrePathError.extensionMismatch
        }

        return CalibreSourceFile(
            url: resolved,
            declaredFormat: format,
            canonicalLibraryRoot: canonicalLibraryRoot,
            rawRelativeBookPath: rawRelativeBookPath,
            rawFileName: rawFileName,
            identity: CalibreSourceFile.Identity(
                resourceIdentifier: values.fileResourceIdentifier.map { String(reflecting: $0) },
                fileSize: values.fileSize,
                contentModificationDate: values.contentModificationDate
            )
        )
    }

    private func ensureContained(_ candidate: URL) throws {
        let rootPath = canonicalLibraryRoot.path(percentEncoded: false)
        let candidatePath = candidate.standardizedFileURL.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath == rootPath || candidatePath.hasPrefix(prefix) else {
            throw CalibrePathError.pathOutsideLibrary
        }
    }

    private func resourceValues(at url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
        do {
            return try url.resourceValues(forKeys: keys)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            throw CalibrePathError.missingFile
        } catch {
            throw CalibrePathError.unreadablePath
        }
    }

    private static func relativeComponents(of rawPath: String) throws -> [String] {
        if rawPath.isEmpty { return [] }
        guard !rawPath.hasPrefix("/"), !(rawPath as NSString).isAbsolutePath else {
            throw CalibrePathError.absoluteBookPath
        }

        let components = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for component in components {
            if component == "." || component == ".." {
                throw CalibrePathError.traversalComponent
            }
            guard Self.isSafeLeaf(component) else { throw CalibrePathError.invalidPathComponent }
        }
        return components
    }

    private static func isSafeLeaf(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isSafeFormat(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
    }
}
