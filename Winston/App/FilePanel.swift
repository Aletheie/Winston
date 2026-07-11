import AppKit
import UniformTypeIdentifiers

@MainActor
enum FilePanel {
    static func chooseFolder(message: String, prompt: String? = nil, directory: URL? = nil) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        if let prompt { panel.prompt = prompt }
        if let directory { panel.directoryURL = directory }
        return await begin(panel)
    }

    static func chooseFile(message: String, allowedContentTypes: [UTType] = []) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = message
        if !allowedContentTypes.isEmpty { panel.allowedContentTypes = allowedContentTypes }
        return await begin(panel)
    }

    private static func begin(_ panel: NSOpenPanel) async -> URL? {
        await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
