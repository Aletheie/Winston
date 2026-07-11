import Foundation

enum BookFileStore {
    nonisolated static func importCopy(of source: URL, uuid: UUID) throws -> String {
        try AppPaths.ensureDirectory(AppPaths.booksDirectory)
        let ext = source.pathExtension.lowercased()
        let fileName = ext.isEmpty ? uuid.uuidString : "\(uuid.uuidString).\(ext)"
        let destination = AppPaths.booksDirectory.appending(path: fileName)

        if source.standardizedFileURL == destination.standardizedFileURL {
            return fileName
        }

        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(fileName).\(UUID().uuidString).importing")
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: temporary) }

        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        return fileName
    }

    nonisolated static func url(for fileName: String) -> URL {
        AppPaths.booksDirectory.appending(path: fileName)
    }

    nonisolated static func size(of fileName: String) -> Int64 {
        let path = url(for: fileName).path(percentEncoded: false)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    nonisolated static func delete(fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }
}
