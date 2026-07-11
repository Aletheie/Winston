import Foundation
import SwiftData
import Observation
import OSLog

@MainActor
@Observable
final class PluginService {
    enum Status: Equatable {
        case disabled
        case active
        case invalid(String)
        case failed(String)
        case quarantined
    }

    struct PluginState: Identifiable {
        let id: String
        var name: String
        var version: String
        var manifest: PluginManifest?
        var folderURL: URL
        var status: Status
        var faultCount: Int = 0
        var logBuffer: PluginLogBuffer?

        var permissions: [PluginPermission] {
            manifest.map { $0.permissions.sorted { $0.rawValue < $1.rawValue } } ?? []
        }
    }

    private(set) var plugins: [PluginState] = []
    private var runtimes: [String: PluginRuntime] = [:]

    private let settings: AppSettings
    private let hostAPI: PluginHostAPI

    var loadDeadline: TimeInterval = 10
    private let maxFaults = 5

    init(modelContext: ModelContext, settings: AppSettings, toasts: ToastCenter,
         online: any OnlineMetadataFetching = OnlineMetadataService()) {
        self.settings = settings
        self.hostAPI = PluginHostAPI(modelContext: modelContext, settings: settings,
                                     toasts: toasts, online: online)
    }

    // MARK: - Discovery

    func refresh() async {
        let discovered = await PluginDiscovery.scan(directory: AppPaths.pluginsDirectory)

        var next: [PluginState] = []
        for item in discovered {
            let existing = plugins.first(where: { $0.id == item.id })
            if let manifest = item.manifest {
                if let existing,
                   existing.manifest == manifest,
                   existing.folderURL == item.folderURL {
                    next.append(existing)
                    continue
                }

                if existing != nil {
                    await shutdownRuntimeAndWait(for: item.id)
                    settings.pluginGrants.removeValue(forKey: manifest.grantKey)
                }
                next.append(PluginState(id: item.id, name: manifest.name, version: manifest.version,
                                        manifest: manifest, folderURL: item.folderURL, status: .disabled))
            } else {
                if existing?.manifest != nil { await shutdownRuntimeAndWait(for: item.id) }
                next.append(PluginState(id: item.id, name: item.id, version: "", manifest: nil,
                                        folderURL: item.folderURL,
                                        status: .invalid(item.invalidReason ?? "invalid plugin")))
            }
        }
        for state in plugins where !next.contains(where: { $0.id == state.id }) {
            await shutdownRuntimeAndWait(for: state.id)
        }
        plugins = next

        for state in plugins
        where state.status == .disabled && settings.enabledPluginIDs.contains(state.id) && !needsConsent(state.id) {
            await activate(state.id)
        }
    }

    // MARK: - Enable / disable

    func needsConsent(_ id: String) -> Bool {
        guard let manifest = state(of: id)?.manifest else { return false }
        guard let stored = settings.pluginGrants[manifest.grantKey] else { return true }
        return !manifest.permissions.allSatisfy { stored.contains($0.rawValue) }
    }

    func enable(_ id: String, grantingPermissions: Bool = false) async {
        guard let manifest = state(of: id)?.manifest else { return }
        if grantingPermissions {
            settings.pluginGrants[manifest.grantKey] = manifest.permissions.map(\.rawValue).sorted()
        }
        guard !needsConsent(id) else { return }
        settings.enabledPluginIDs.insert(id)
        await activate(id)
    }

    func disable(_ id: String) {
        settings.enabledPluginIDs.remove(id)
        shutdownRuntime(for: id)
        update(id) { state in
            state.status = .disabled
            state.faultCount = 0
        }
    }

    // MARK: - Loading

    private func activate(_ id: String) async {
        guard let current = state(of: id), let manifest = current.manifest,
              runtimes[id] == nil else { return }
        let granted = grantedPermissions(for: manifest)

        let runtime = PluginRuntime(manifest: manifest, folderURL: current.folderURL) { [weak self] message in
            Task { @MainActor in self?.recordFault(id: id, message: message) }
        }
        runtimes[id] = runtime
        update(id) { $0.logBuffer = runtime.logBuffer }

        let handler = hostAPI.makeHandler(for: manifest, granted: granted)
        let deadline = loadDeadline
        do {
            try await withPluginDeadline(seconds: deadline) {
                try await runtime.load(granted: granted, handler: handler)
            }
            update(id) { $0.status = .active }
        } catch PluginError.timeout {
            runtimes[id] = nil
            settings.enabledPluginIDs.remove(id)
            update(id) { $0.status = .quarantined }
            runtime.logBuffer.append(.error, "did not finish loading within \(Int(deadline)) s — quarantined")
            Log.plugins.error("[\(id, privacy: .public)] load timed out — quarantined")
        } catch {
            runtimes[id] = nil
            let reason = (error as? PluginError)?.message ?? error.localizedDescription
            update(id) { $0.status = .failed(reason) }
        }
    }

    private func recordFault(id: String, message: String) {
        update(id) { $0.faultCount += 1 }
        guard let current = state(of: id), current.faultCount >= maxFaults,
              current.status == .active else { return }
        shutdownRuntime(for: id)
        settings.enabledPluginIDs.remove(id)
        update(id) { $0.status = .quarantined }
        current.logBuffer?.append(.error, "quarantined after \(maxFaults) errors")
        Log.plugins.error("[\(id, privacy: .public)] quarantined after \(self.maxFaults) faults (last: \(message, privacy: .public))")
    }

    private func shutdownRuntime(for id: String) {
        guard let runtime = runtimes.removeValue(forKey: id) else { return }
        Task { try? await withPluginDeadline(seconds: 5) { await runtime.shutdown() } }
    }

    private func shutdownRuntimeAndWait(for id: String) async {
        guard let runtime = runtimes.removeValue(forKey: id) else { return }
        try? await withPluginDeadline(seconds: 5) { await runtime.shutdown() }
    }

    private func grantedPermissions(for manifest: PluginManifest) -> Set<PluginPermission> {
        let stored = settings.pluginGrants[manifest.grantKey] ?? []
        return manifest.permissions.filter { stored.contains($0.rawValue) }
    }

    // MARK: - State helpers

    private func state(of id: String) -> PluginState? {
        plugins.first { $0.id == id }
    }

    private func update(_ id: String, _ mutate: (inout PluginState) -> Void) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        mutate(&plugins[index])
    }
}
