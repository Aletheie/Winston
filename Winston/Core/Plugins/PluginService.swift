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
        var contentDigest: String?
        var folderURL: URL
        var status: Status
        var faultCount: Int = 0
        var logBuffer: PluginLogBuffer?

        var permissions: [PluginPermission] {
            manifest.map { $0.permissions.sorted { $0.rawValue < $1.rawValue } } ?? []
        }
    }

    private struct ActiveRuntime {
        let runtime: PluginRuntime
        let session: PluginSessionLease
    }

    private(set) var plugins: [PluginState] = []
    private var runtimes: [String: ActiveRuntime] = [:]

    private let settings: AppSettings
    private let hostAPI: PluginHostAPI

    var loadDeadline: TimeInterval = 10
    private let maxFaults = 5

    init(modelContext: ModelContext, settings: AppSettings, toasts: ToastCenter,
         online: any OnlineMetadataFetching = OnlineMetadataService(),
         saveAdapter: CatalogSaveAdapter = .live) {
        self.settings = settings
        let mutations = CatalogMutationService(modelContext: modelContext, saveAdapter: saveAdapter)
        self.hostAPI = PluginHostAPI(modelContext: modelContext, settings: settings,
                                     toasts: toasts, online: online, mutations: mutations)
    }

    // MARK: - Discovery

    func refresh() async {
        let discovered = await PluginDiscovery.scan(directory: AppPaths.pluginsDirectory)

        var next: [PluginState] = []
        for item in discovered {
            let existing = plugins.first(where: { $0.id == item.id })
            if let manifest = item.manifest, let contentDigest = item.contentDigest {
                if let existing,
                   existing.manifest == manifest,
                   existing.contentDigest == contentDigest,
                   existing.folderURL == item.folderURL {
                    next.append(existing)
                    continue
                }

                if existing != nil {
                    await shutdownRuntimeAndWait(for: item.id)
                    if let oldManifest = existing?.manifest,
                       let oldDigest = existing?.contentDigest {
                        settings.pluginGrants.removeValue(
                            forKey: oldManifest.grantKey(contentDigest: oldDigest)
                        )
                    }
                }
                next.append(PluginState(id: item.id, name: manifest.name, version: manifest.version,
                                        manifest: manifest, contentDigest: contentDigest,
                                        folderURL: item.folderURL, status: .disabled))
            } else {
                if existing?.manifest != nil { await shutdownRuntimeAndWait(for: item.id) }
                next.append(PluginState(id: item.id, name: item.id, version: "", manifest: nil,
                                        contentDigest: nil, folderURL: item.folderURL,
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
        guard let state = state(of: id), let manifest = state.manifest,
              let contentDigest = state.contentDigest else { return false }
        guard let stored = settings.pluginGrants[
            manifest.grantKey(contentDigest: contentDigest)
        ] else { return true }
        return !manifest.permissions.allSatisfy { stored.contains($0.rawValue) }
    }

    func enable(_ id: String, grantingPermissions: Bool = false) async {
        guard let state = state(of: id), state.status != .quarantined,
              let manifest = state.manifest,
              let contentDigest = state.contentDigest else { return }
        if grantingPermissions {
            settings.pluginGrants[
                manifest.grantKey(contentDigest: contentDigest)
            ] = manifest.permissions.map(\.rawValue).sorted()
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
              let contentDigest = current.contentDigest,
              runtimes[id] == nil else { return }
        let granted = grantedPermissions(for: current)
        let session = hostAPI.openSession(for: manifest, contentDigest: contentDigest)

        let runtime = PluginRuntime(
            manifest: manifest,
            folderURL: current.folderURL,
            contentDigest: contentDigest,
            executionDeadline: loadDeadline
        ) { [weak self] fault in
            Task { @MainActor in
                self?.recordFault(id: id, session: session, fault: fault)
            }
        }
        runtimes[id] = ActiveRuntime(runtime: runtime, session: session)
        update(id) { $0.logBuffer = runtime.logBuffer }

        let handler = hostAPI.makeHandler(for: manifest, granted: granted, session: session)
        let deadline = loadDeadline
        do {
            try await runtime.load(granted: granted, handler: handler)
            guard runtimes[id]?.session == session, hostAPI.isActive(session) else {
                await runtime.terminate()
                return
            }
            update(id) { $0.status = .active }
        } catch PluginError.timeout {
            await discardRuntime(id: id, session: session, terminate: true)
            settings.enabledPluginIDs.remove(id)
            update(id) { $0.status = .quarantined }
            runtime.logBuffer.append(.error, "did not finish loading within \(deadline.formatted()) s — quarantined")
            Log.plugins.error("[\(id, privacy: .public)] load timed out — worker terminated and quarantined")
        } catch PluginError.workerTerminated(let reason) {
            await discardRuntime(id: id, session: session, terminate: true)
            settings.enabledPluginIDs.remove(id)
            update(id) { $0.status = .quarantined }
            runtime.logBuffer.append(.error, "\(reason) — quarantined")
            Log.plugins.error("[\(id, privacy: .public)] worker terminated — quarantined")
        } catch {
            await discardRuntime(id: id, session: session, terminate: true)
            let reason = (error as? PluginError)?.message ?? error.localizedDescription
            update(id) { $0.status = .failed(reason) }
        }
    }

    private func recordFault(
        id: String,
        session: PluginSessionLease,
        fault: PluginRuntimeFault
    ) {
        guard runtimes[id]?.session == session else { return }
        switch fault {
        case .terminated(let message):
            shutdownRuntime(for: id)
            runtimes[id] = nil
            settings.enabledPluginIDs.remove(id)
            update(id) { $0.status = .quarantined }
            state(of: id)?.logBuffer?.append(.error, "\(message) — quarantined")
            Log.plugins.error("[\(id, privacy: .public)] worker stopped — quarantined: \(message, privacy: .public)")
            return

        case .script(let message):
            update(id) { $0.faultCount += 1 }
            guard let current = state(of: id), current.faultCount >= maxFaults,
                  current.status == .active else { return }
            shutdownRuntime(for: id)
            settings.enabledPluginIDs.remove(id)
            update(id) { $0.status = .quarantined }
            current.logBuffer?.append(.error, "quarantined after \(maxFaults) errors")
            Log.plugins.error("[\(id, privacy: .public)] quarantined after \(self.maxFaults) faults (last: \(message, privacy: .public))")
        }
    }

    private func discardRuntime(
        id: String,
        session: PluginSessionLease,
        terminate: Bool
    ) async {
        guard let active = runtimes[id], active.session == session else { return }
        runtimes[id] = nil
        hostAPI.invalidate(session)
        if terminate { await active.runtime.terminate() }
    }

    private func shutdownRuntime(for id: String) {
        guard let active = runtimes.removeValue(forKey: id) else { return }
        hostAPI.invalidate(active.session)
        Task { await active.runtime.shutdown() }
    }

    private func shutdownRuntimeAndWait(for id: String) async {
        guard let active = runtimes.removeValue(forKey: id) else { return }
        hostAPI.invalidate(active.session)
        await active.runtime.shutdown()
    }

    private func grantedPermissions(for state: PluginState) -> Set<PluginPermission> {
        guard let manifest = state.manifest, let contentDigest = state.contentDigest else { return [] }
        let stored = settings.pluginGrants[
            manifest.grantKey(contentDigest: contentDigest)
        ] ?? []
        return manifest.permissions.filter { stored.contains($0.rawValue) }
    }

    func activeWorkerPIDForTesting(_ id: String) async -> Int32? {
        guard let runtime = runtimes[id]?.runtime else { return nil }
        return await runtime.workerProcessIdentifier()
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
