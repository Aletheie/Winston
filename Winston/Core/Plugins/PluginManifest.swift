import CryptoKit
import Foundation

nonisolated enum PluginPermission: String, Codable, Sendable, CaseIterable {
    case libraryRead = "library.read"
    case libraryWrite = "library.write"
    case metadataFetch = "metadata.fetch"
    case uiToast = "ui.toast"
}

nonisolated struct PluginManifest: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let version: String
    let api: String
    let entry: String
    let permissions: Set<PluginPermission>
    let description: String?
    let author: String?

    static let supportedAPIMajor = 1
    static let hostAPIVersion = "1.2.0"

    var apiMajor: Int? { api.split(separator: ".").first.flatMap { Int($0) } }

    func grantKey(contentDigest: String) -> String {
        "\(id)@\(version)#sha256:\(contentDigest)"
    }
}

nonisolated struct DiscoveredPlugin: Sendable, Identifiable {
    let folderURL: URL
    let manifest: PluginManifest?
    let contentDigest: String?
    let invalidReason: String?

    var id: String { manifest?.id ?? folderURL.lastPathComponent }
}

nonisolated struct PluginBundleSnapshot: Sendable {
    let manifest: PluginManifest
    let contentDigest: String
    let entrySource: String
}

private nonisolated enum PluginBundleError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

nonisolated enum PluginDiscovery {
    static let maxEntryBytes = 5 * 1024 * 1024
    static let maxManifestBytes = 256 * 1024
    static let maxBundleBytes = 20 * 1024 * 1024
    static let maxBundleFiles = 256
    static let maxBundleEntries = 512

    @concurrent
    static func scan(directory: URL) async -> [DiscoveredPlugin] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(examine(folder:))
            .sorted { $0.id < $1.id }
    }

    static func examine(folder: URL) -> DiscoveredPlugin {
        func invalid(_ reason: String) -> DiscoveredPlugin {
            DiscoveredPlugin(
                folderURL: folder,
                manifest: nil,
                contentDigest: nil,
                invalidReason: reason
            )
        }

        do {
            let snapshot = try bundleSnapshot(in: folder)
            return DiscoveredPlugin(
                folderURL: folder,
                manifest: snapshot.manifest,
                contentDigest: snapshot.contentDigest,
                invalidReason: nil
            )
        } catch {
            return invalid(error.localizedDescription)
        }
    }

    static func validationFailure(of manifest: PluginManifest, folder: URL) -> String? {
        if let reason = manifestValidationFailure(of: manifest, folder: folder) { return reason }
        let entryURL = folder.appending(path: manifest.entry)
        guard let values = try? entryURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]), values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize else {
            return "entry file \"\(manifest.entry)\" is missing or is not a regular file"
        }
        guard size <= maxEntryBytes else {
            return "entry file is \(size) bytes; the limit is \(maxEntryBytes)"
        }
        return nil
    }

    static func bundleSnapshot(
        in folder: URL,
        expectedManifest: PluginManifest? = nil,
        expectedDigest: String? = nil
    ) throws -> PluginBundleSnapshot {
        let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true else {
            throw PluginBundleError.invalid("plugin folder must be a real directory, not a symbolic link")
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            throw PluginBundleError.invalid("plugin folder could not be read")
        }

        // FileManager can report descendants through the canonical `/private/var`
        // spelling even when the caller used the system `/var` alias. Resolve only
        // after rejecting bundle-local symlinks so both sides of the containment
        // check use the same spelling without allowing a plugin to escape its root.
        let canonicalRootPath = folder.resolvingSymlinksInPath()
            .standardizedFileURL.path(percentEncoded: false)
        let rootPath = canonicalRootPath.hasSuffix("/")
            ? String(canonicalRootPath.dropLast())
            : canonicalRootPath
        var files: [(path: String, data: Data)] = []
        var totalBytes = 0
        var entryCount = 0
        for case let url as URL in enumerator {
            entryCount += 1
            guard entryCount <= maxBundleEntries else {
                throw PluginBundleError.invalid(
                    "plugin bundle contains more than \(maxBundleEntries) entries"
                )
            }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                throw PluginBundleError.invalid("plugin bundle must not contain symbolic links")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw PluginBundleError.invalid("plugin bundle may contain only directories and regular files")
            }
            guard files.count < maxBundleFiles else {
                throw PluginBundleError.invalid("plugin bundle contains more than \(maxBundleFiles) files")
            }

            let path = url.resolvingSymlinksInPath()
                .standardizedFileURL.path(percentEncoded: false)
            guard path.hasPrefix(rootPath + "/") else {
                throw PluginBundleError.invalid("plugin bundle contains an unsafe path")
            }
            let relativePath = String(path.dropFirst(rootPath.count + 1))
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            totalBytes += data.count
            guard totalBytes <= maxBundleBytes else {
                throw PluginBundleError.invalid("plugin bundle exceeds its \(maxBundleBytes)-byte limit")
            }
            files.append((relativePath, data))
        }
        guard !enumerationFailed else {
            throw PluginBundleError.invalid("plugin bundle could not be read completely")
        }
        files.sort { $0.path < $1.path }

        guard let manifestData = files.first(where: { $0.path == "manifest.json" })?.data else {
            throw PluginBundleError.invalid("manifest.json is missing")
        }
        guard manifestData.count <= maxManifestBytes else {
            throw PluginBundleError.invalid("manifest.json exceeds its size limit")
        }

        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        } catch {
            throw PluginBundleError.invalid("manifest.json does not decode: \(error.localizedDescription)")
        }
        if let reason = manifestValidationFailure(of: manifest, folder: folder) {
            throw PluginBundleError.invalid(reason)
        }
        if let expectedManifest, manifest != expectedManifest {
            throw PluginBundleError.invalid("plugin manifest changed; refresh plugins before enabling it")
        }
        guard let entryData = files.first(where: { $0.path == manifest.entry })?.data else {
            throw PluginBundleError.invalid("entry file \"\(manifest.entry)\" is missing")
        }
        guard entryData.count <= maxEntryBytes else {
            throw PluginBundleError.invalid(
                "entry file is \(entryData.count) bytes; the limit is \(maxEntryBytes)"
            )
        }
        guard let entrySource = String(data: entryData, encoding: .utf8) else {
            throw PluginBundleError.invalid("entry script must be valid UTF-8")
        }

        var hasher = SHA256()
        for file in files {
            hasher.update(data: Data("\(file.path.utf8.count):\(file.path):\(file.data.count):".utf8))
            hasher.update(data: file.data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expectedDigest, digest != expectedDigest {
            throw PluginBundleError.invalid("plugin contents changed; refresh and grant permissions again")
        }
        return PluginBundleSnapshot(
            manifest: manifest,
            contentDigest: digest,
            entrySource: entrySource
        )
    }

    private static func manifestValidationFailure(
        of manifest: PluginManifest,
        folder: URL
    ) -> String? {
        guard manifest.id == folder.lastPathComponent else {
            return "id \"\(manifest.id)\" does not match the folder name \"\(folder.lastPathComponent)\""
        }
        guard manifest.id.range(of: "^[a-z0-9][a-z0-9.-]{2,99}$", options: .regularExpression) != nil else {
            return "id must be lowercase letters, digits, dots and hyphens (3–100 characters)"
        }
        guard !manifest.name.isEmpty, !manifest.version.isEmpty else {
            return "name and version must not be empty"
        }
        guard !manifest.entry.isEmpty, !manifest.entry.contains("/"), !manifest.entry.contains("..") else {
            return "entry must be a plain file name inside the plugin folder"
        }
        guard manifest.apiMajor == PluginManifest.supportedAPIMajor else {
            return "requires plugin API \(manifest.api); this Winston provides \(PluginManifest.hostAPIVersion)"
        }
        return nil
    }
}
