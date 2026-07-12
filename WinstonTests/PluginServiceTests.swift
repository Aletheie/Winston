import Testing
import Foundation
@testable import Winston

@Suite(.serialized)
@MainActor
struct PluginServiceTests {
    @MainActor
    private final class Harness {
        let library: TestLibrary
        let settings: AppSettings
        let toasts: ToastCenter
        let service: PluginService

        init() async throws {
            Self.resetPluginDefaults()
            library = try await TestLibrary()
            settings = AppSettings()
            toasts = ToastCenter()
            service = PluginService(modelContext: library.context, settings: settings, toasts: toasts)
        }

        deinit { Self.resetPluginDefaults() }

        private nonisolated static func resetPluginDefaults() {
            UserDefaults.standard.removeObject(forKey: "enabledPluginIDs")
            UserDefaults.standard.removeObject(forKey: "pluginGrants")
        }

        func installPlugin(id: String = "cz.test.sample",
                           name: String = "Sample",
                           version: String = "1.0.0",
                           permissions: [String] = ["library.read"],
                           source: String) throws {
            let folder = AppPaths.pluginsDirectory.appending(path: id, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "id": id, "name": name, "version": version, "api": "1",
                "entry": "index.js", "permissions": permissions,
            ]
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: folder.appending(path: "manifest.json"))
            try Data(source.utf8).write(to: folder.appending(path: "index.js"))
        }

        @discardableResult
        func seedBook(title: String, publisher: String? = nil) -> Book {
            let book = Book(fileName: "\(UUID().uuidString).epub", originalFileName: "\(title).epub")
            book.title = title
            book.publisher = publisher
            library.context.insert(book)
            library.context.saveQuietly()
            return book
        }

        func state(_ id: String) -> PluginService.PluginState? {
            service.plugins.first { $0.id == id }
        }

        func loggedEventually(_ needle: String, in id: String, timeout: TimeInterval = 3) async -> Bool {
            let start = Date()
            while Date().timeIntervalSince(start) < timeout {
                if state(id)?.logBuffer?.snapshot.contains(where: { $0.message.contains(needle) }) == true {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
    }

    @Test func discoveryListsValidAndInvalidPlugins() async throws {
        let harness = try await Harness()
        try harness.installPlugin(source: "// noop")
        let broken = AppPaths.pluginsDirectory.appending(path: "cz.test.broken", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appending(path: "manifest.json"))

        await harness.service.refresh()

        #expect(harness.service.plugins.count == 2)
        #expect(harness.state("cz.test.sample")?.status == .disabled)
        if case .invalid = harness.state("cz.test.broken")?.status {} else {
            Issue.record("expected cz.test.broken to be invalid")
        }
    }

    @Test func enablingNeedsConsentThenRunsAgainstTheLibrary() async throws {
        let harness = try await Harness()
        harness.seedBook(title: "Alpha")
        harness.seedBook(title: "Beta")
        try harness.installPlugin(source: """
            exports.activate = async () => {
                const books = await Winston.library.list();
                console.log("count:" + books.length + " first:" + books[0].displayTitle);
            };
            """)
        await harness.service.refresh()

        #expect(harness.service.needsConsent("cz.test.sample"))
        await harness.service.enable("cz.test.sample")
        #expect(harness.state("cz.test.sample")?.status == .disabled)

        await harness.service.enable("cz.test.sample", grantingPermissions: true)
        #expect(harness.state("cz.test.sample")?.status == .active)
        #expect(harness.settings.enabledPluginIDs.contains("cz.test.sample"))
        #expect(await harness.loggedEventually("count:2 first:Alpha", in: "cz.test.sample"))
    }

    @Test func libraryUpdateFillsOnlyEmptyFields() async throws {
        let harness = try await Harness()
        let book = harness.seedBook(title: "Kept", publisher: nil)
        try harness.installPlugin(permissions: ["library.read", "library.write"], source: """
            exports.activate = async () => {
                const books = await Winston.library.list();
                const result = await Winston.library.update(books[0].uuid,
                    { title: "Clobbered", publisher: "Argo" });
                console.log("applied:" + result.applied.join(","));
            };
            """)
        await harness.service.refresh()
        await harness.service.enable("cz.test.sample", grantingPermissions: true)

        #expect(await harness.loggedEventually("applied:publisher", in: "cz.test.sample"))
        #expect(book.title == "Kept")
        #expect(book.publisher == "Argo")
    }

    @Test func storageRoundTripsAndPersistsPerPlugin() async throws {
        let harness = try await Harness()
        try harness.installPlugin(permissions: [], source: """
            exports.activate = async () => {
                await Winston.storage.set("k", { a: 1 });
                const v = await Winston.storage.get("k");
                console.log("v:" + v.a);
            };
            """)
        await harness.service.refresh()
        await harness.service.enable("cz.test.sample", grantingPermissions: true)

        #expect(await harness.loggedEventually("v:1", in: "cz.test.sample"))
        let file = AppPaths.pluginDataDirectory(for: "cz.test.sample").appending(path: "storage.json")
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func toastsAreAttributedToThePlugin() async throws {
        let harness = try await Harness()
        try harness.installPlugin(permissions: ["ui.toast"], source: """
            exports.activate = async () => { await Winston.ui.toast("ahoj", "success"); };
            """)
        await harness.service.refresh()
        await harness.service.enable("cz.test.sample", grantingPermissions: true)

        let start = Date()
        while Date().timeIntervalSince(start) < 3, harness.toasts.messages.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(harness.toasts.messages.first?.text == "Sample: ahoj")
        #expect(harness.toasts.messages.first?.style == .success)
    }

    @Test func hungActivateIsQuarantinedWithoutStallingTheCaller() async throws {
        let harness = try await Harness()
        harness.service.loadDeadline = 0.3
        try harness.installPlugin(permissions: [], source: """
            exports.activate = () => {
                const end = Date.now() + 1500;
                while (Date.now() < end) {}
            };
            """)
        await harness.service.refresh()
        await harness.service.enable("cz.test.sample", grantingPermissions: true)

        #expect(harness.state("cz.test.sample")?.status == .quarantined)
        #expect(!harness.settings.enabledPluginIDs.contains("cz.test.sample"))
        try? await Task.sleep(for: .seconds(1.6))
    }

    @Test func refreshReplacesChangedManifestAndRequiresFreshConsent() async throws {
        let harness = try await Harness()
        try harness.installPlugin(permissions: [], source: "console.log('old-version');")
        await harness.service.refresh()
        await harness.service.enable("cz.test.sample", grantingPermissions: true)
        #expect(harness.state("cz.test.sample")?.status == .active)

        try harness.installPlugin(
            name: "Updated Sample",
            version: "2.0.0",
            permissions: ["ui.toast"],
            source: "console.log('new-version');"
        )
        await harness.service.refresh()

        let refreshed = try #require(harness.state("cz.test.sample"))
        #expect(refreshed.name == "Updated Sample")
        #expect(refreshed.version == "2.0.0")
        #expect(refreshed.permissions == [.uiToast])
        #expect(refreshed.status == .disabled)
        #expect(harness.service.needsConsent("cz.test.sample"))

        await harness.service.enable("cz.test.sample")
        #expect(harness.state("cz.test.sample")?.status == .disabled)
        await harness.service.enable("cz.test.sample", grantingPermissions: true)
        #expect(harness.state("cz.test.sample")?.status == .active)
        #expect(await harness.loggedEventually("new-version", in: "cz.test.sample"))
    }
}
