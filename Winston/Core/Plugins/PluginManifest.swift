import Foundation

nonisolated enum PluginPermission: String, Codable, Sendable, CaseIterable {
    case libraryRead = "library.read"
    case libraryWrite = "library.write"
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
    static let hostAPIVersion = "1.0.0"

    var apiMajor: Int? { api.split(separator: ".").first.flatMap { Int($0) } }

    var grantKey: String { "\(id)@\(version)" }
}

nonisolated struct DiscoveredPlugin: Sendable, Identifiable {
    let folderURL: URL
    let manifest: PluginManifest?
    let invalidReason: String?

    var id: String { manifest?.id ?? folderURL.lastPathComponent }
}

nonisolated enum PluginDiscovery {
    static let maxEntryBytes = 5 * 1024 * 1024

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
            DiscoveredPlugin(folderURL: folder, manifest: nil, invalidReason: reason)
        }

        let manifestURL = folder.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return invalid("manifest.json is missing")
        }
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            return invalid("manifest.json does not decode: \(error.localizedDescription)")
        }
        if let reason = validationFailure(of: manifest, folder: folder) { return invalid(reason) }
        return DiscoveredPlugin(folderURL: folder, manifest: manifest, invalidReason: nil)
    }

    static func validationFailure(of manifest: PluginManifest, folder: URL) -> String? {
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
        let entryURL = folder.appending(path: manifest.entry)
        guard let size = try? entryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return "entry file \"\(manifest.entry)\" is missing"
        }
        guard size <= maxEntryBytes else {
            return "entry file is \(size) bytes; the limit is \(maxEntryBytes)"
        }
        return nil
    }
}
