import SwiftUI
import AppKit

struct PluginsSettingsPane: View {
    @Environment(PluginService.self) private var pluginService

    @State private var consentCandidate: PluginService.PluginState?

    var body: some View {
        Form {
            if pluginService.plugins.isEmpty {
                Section("Plugins") {
                    Text("No plugins installed.")
                        .foregroundStyle(.secondary)
                    Text("To install one, put its folder (manifest.json and a script) into the Plugins folder, then click Refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(pluginService.plugins) { plugin in
                    Section { row(for: plugin) }
                }
            }

            Section {
                HStack {
                    Button("Open Plugins Folder") {
                        NSWorkspace.shared.open(AppPaths.pluginsDirectory)
                    }
                    Spacer()
                    Button("Refresh") {
                        Task { await pluginService.refresh() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await pluginService.refresh() }
        .alert(
            Text("Enable “\(consentCandidate?.name ?? "")”?"),
            isPresented: Binding(
                get: { consentCandidate != nil },
                set: { if !$0 { consentCandidate = nil } }
            ),
            presenting: consentCandidate
        ) { plugin in
            Button("Enable") {
                Task { await pluginService.enable(plugin.id, grantingPermissions: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { plugin in
            Text(verbatim: consentMessage(for: plugin))
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for plugin: PluginService.PluginState) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: plugin.name)
                    .fontWeight(.medium)
                if !plugin.version.isEmpty {
                    Text("Version \(plugin.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: toggleBinding(for: plugin))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(plugin.manifest == nil)
        }

        statusText(for: plugin)
            .font(.caption)

        if !plugin.permissions.isEmpty {
            Text(verbatim: plugin.permissions.map(\.displayName).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let entries = plugin.logBuffer?.snapshot.suffix(8), !entries.isEmpty {
            DisclosureGroup("Log") {
                ForEach(entries) { entry in
                    Text(verbatim: entry.message)
                        .font(.caption.monospaced())
                        .foregroundStyle(entry.level == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.callout)
        }

        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([plugin.folderURL])
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    private func statusText(for plugin: PluginService.PluginState) -> Text {
        switch plugin.status {
        case .disabled:
            Text("Disabled").foregroundStyle(.secondary)
        case .active:
            Text("Active").foregroundStyle(.green)
        case .invalid(let reason):
            Text("Invalid: \(reason)").foregroundStyle(.orange)
        case .failed(let reason):
            Text("Failed: \(reason)").foregroundStyle(.red)
        case .quarantined:
            Text("Quarantined after repeated errors").foregroundStyle(.red)
        }
    }

    private func toggleBinding(for plugin: PluginService.PluginState) -> Binding<Bool> {
        Binding(
            get: { plugin.status == .active },
            set: { enabled in
                if enabled {
                    if pluginService.needsConsent(plugin.id) {
                        consentCandidate = plugin
                    } else {
                        Task { await pluginService.enable(plugin.id) }
                    }
                } else {
                    pluginService.disable(plugin.id)
                }
            }
        )
    }

    private func consentMessage(for plugin: PluginService.PluginState) -> String {
        guard !plugin.permissions.isEmpty else {
            return String(localized: "This plugin requests no permissions.")
        }
        let list = plugin.permissions.map { "• \($0.displayName)" }.joined(separator: "\n")
        return String(localized: "This plugin requests:") + "\n" + list
    }
}

extension PluginPermission {
    var displayName: String {
        switch self {
        case .libraryRead: String(localized: "Read library metadata")
        case .libraryWrite: String(localized: "Fill in missing book metadata")
        case .metadataFetch: String(localized: "Fetch metadata from online catalogs")
        case .uiToast: String(localized: "Show notifications")
        }
    }
}
