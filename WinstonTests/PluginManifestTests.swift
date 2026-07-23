import Testing
import Foundation
@testable import Winston

struct PluginManifestTests {
    @Test func decodesAValidManifest() throws {
        let json = """
        {"id": "cz.example.tool", "name": "Tool", "version": "1.2.0", "api": "1",
         "entry": "index.js", "permissions": ["library.read", "ui.toast"],
         "description": "d", "author": "a"}
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(manifest.id == "cz.example.tool")
        #expect(manifest.permissions == [.libraryRead, .uiToast])
        #expect(manifest.apiMajor == 1)
        #expect(
            manifest.grantKey(contentDigest: "abc")
                == "cz.example.tool@1.2.0#sha256:abc"
        )
    }

    @Test func unknownPermissionFailsTheWholeManifest() {
        let json = """
        {"id": "cz.example.tool", "name": "Tool", "version": "1.0", "api": "1",
         "entry": "index.js", "permissions": ["network.raw"]}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        }
    }

    // MARK: - Folder examination

    private func makeFolder(named name: String, manifestJSON: String?, entry: String? = "// empty") throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "WinstonManifestTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let manifestJSON {
            try Data(manifestJSON.utf8).write(to: folder.appending(path: "manifest.json"))
        }
        if let entry {
            try Data(entry.utf8).write(to: folder.appending(path: "index.js"))
        }
        return folder
    }

    private func manifestJSON(id: String, api: String = "1", entry: String = "index.js") -> String {
        """
        {"id": "\(id)", "name": "Tool", "version": "1.0.0", "api": "\(api)",
         "entry": "\(entry)", "permissions": []}
        """
    }

    @Test func acceptsAWellFormedFolder() throws {
        let folder = try makeFolder(named: "cz.example.tool", manifestJSON: manifestJSON(id: "cz.example.tool"))
        let discovered = PluginDiscovery.examine(folder: folder)
        #expect(discovered.manifest != nil)
        #expect(discovered.invalidReason == nil)
    }

    @Test func missingManifestIsInvalid() throws {
        let folder = try makeFolder(named: "cz.example.tool", manifestJSON: nil)
        #expect(PluginDiscovery.examine(folder: folder).invalidReason?.contains("missing") == true)
    }

    @Test func idMustMatchFolderName() throws {
        let folder = try makeFolder(named: "wrong-folder", manifestJSON: manifestJSON(id: "cz.example.tool"))
        #expect(PluginDiscovery.examine(folder: folder).invalidReason?.contains("does not match") == true)
    }

    @Test func missingEntryFileIsInvalid() throws {
        let folder = try makeFolder(named: "cz.example.tool",
                                    manifestJSON: manifestJSON(id: "cz.example.tool"), entry: nil)
        #expect(PluginDiscovery.examine(folder: folder).invalidReason?.contains("missing") == true)
    }

    @Test func entryMayNotEscapeTheFolder() throws {
        let folder = try makeFolder(named: "cz.example.tool",
                                    manifestJSON: manifestJSON(id: "cz.example.tool", entry: "../outside.js"))
        #expect(PluginDiscovery.examine(folder: folder).invalidReason?.contains("plain file name") == true)
    }

    @Test func symbolicLinkEntryIsRejected() throws {
        let folder = try makeFolder(
            named: "cz.example.tool",
            manifestJSON: manifestJSON(id: "cz.example.tool"),
            entry: nil
        )
        let outside = folder.deletingLastPathComponent().appending(path: "outside-\(UUID()).js")
        try Data("console.log('outside')".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: folder.appending(path: "index.js"),
            withDestinationURL: outside
        )

        let discovered = PluginDiscovery.examine(folder: folder)

        #expect(discovered.manifest == nil)
        #expect(discovered.invalidReason?.contains("symbolic") == true)
    }

    @Test func symbolicLinkPluginFolderIsRejected() throws {
        let target = try makeFolder(
            named: "cz.example.target",
            manifestJSON: manifestJSON(id: "cz.example.target")
        )
        let link = target.deletingLastPathComponent().appending(path: "cz.example.link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let discovered = PluginDiscovery.examine(folder: link)

        #expect(discovered.manifest == nil)
        #expect(discovered.invalidReason?.contains("symbolic") == true)
    }

    @Test func bundleDigestChangesWhenEntryChangesWithoutAManifestBump() throws {
        let folder = try makeFolder(
            named: "cz.example.tool",
            manifestJSON: manifestJSON(id: "cz.example.tool"),
            entry: "console.log('first')"
        )
        let first = try PluginDiscovery.bundleSnapshot(in: folder)

        try Data("console.log('second')".utf8).write(to: folder.appending(path: "index.js"))
        let second = try PluginDiscovery.bundleSnapshot(in: folder)

        #expect(first.manifest == second.manifest)
        #expect(first.contentDigest != second.contentDigest)
    }

    @Test func bundleDigestCoversFilesBeyondTheEntryPoint() throws {
        let folder = try makeFolder(
            named: "cz.example.tool",
            manifestJSON: manifestJSON(id: "cz.example.tool")
        )
        let auxiliary = folder.appending(path: "rules.json")
        try Data(#"{"mode":"first"}"#.utf8).write(to: auxiliary)
        let first = try PluginDiscovery.bundleSnapshot(in: folder)

        try Data(#"{"mode":"second"}"#.utf8).write(to: auxiliary)
        let second = try PluginDiscovery.bundleSnapshot(in: folder)

        #expect(first.contentDigest != second.contentDigest)
        #expect(throws: (any Error).self) {
            try PluginDiscovery.bundleSnapshot(in: folder, expectedDigest: first.contentDigest)
        }
    }

    @Test func unsupportedAPIMajorIsRefused() throws {
        let folder = try makeFolder(named: "cz.example.tool",
                                    manifestJSON: manifestJSON(id: "cz.example.tool", api: "2"))
        #expect(PluginDiscovery.examine(folder: folder).invalidReason?.contains("requires plugin API") == true)
    }

    @Test func scanReportsEveryFolderOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WinstonManifestScan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root.appending(path: "cz.a.valid", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try Data(manifestJSON(id: "cz.a.valid").utf8)
            .write(to: root.appending(path: "cz.a.valid/manifest.json"))
        try Data("// ok".utf8).write(to: root.appending(path: "cz.a.valid/index.js"))
        try FileManager.default.createDirectory(
            at: root.appending(path: "cz.b.broken", directoryHint: .isDirectory), withIntermediateDirectories: true)

        let discovered = await PluginDiscovery.scan(directory: root)
        #expect(discovered.count == 2)
        #expect(discovered.first { $0.id == "cz.a.valid" }?.manifest != nil)
        #expect(discovered.first { $0.id == "cz.b.broken" }?.invalidReason != nil)
    }
}
