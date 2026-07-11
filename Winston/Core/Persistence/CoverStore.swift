import AppKit

enum CoverStore {
    nonisolated private static func coverURL(for uuid: UUID) -> URL {
        AppPaths.coversDirectory.appending(path: "\(uuid.uuidString).jpg")
    }

    nonisolated static func save(_ image: NSImage, for uuid: UUID) {
        guard let jpeg = ImageTranscoder.jpegData(from: image) else { return }
        try? AppPaths.ensureDirectory(AppPaths.coversDirectory)
        try? jpeg.write(to: coverURL(for: uuid))
    }

    nonisolated static func load(for uuid: UUID) -> NSImage? {
        NSImage(contentsOf: coverURL(for: uuid))
    }

    nonisolated static func exists(for uuid: UUID) -> Bool {
        FileManager.default.fileExists(atPath: coverURL(for: uuid).path(percentEncoded: false))
    }

    nonisolated static func loadData(for uuid: UUID) -> Data? {
        try? Data(contentsOf: coverURL(for: uuid))
    }

    nonisolated static func delete(for uuid: UUID) {
        try? FileManager.default.removeItem(at: coverURL(for: uuid))
    }

    nonisolated static func makeThumbnailFile(from image: NSImage,
                                              maxSize: CGSize = CGSize(width: 330, height: 470)) -> URL? {
        guard let cg = ImageTranscoder.cgImage(from: image) else { return nil }
        let fitted = ImageTranscoder.scaledToFit(cg, maxWidth: Int(maxSize.width), maxHeight: Int(maxSize.height))
        guard let jpeg = ImageTranscoder.jpegData(from: fitted, quality: 0.8) else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appending(path: "WinstonThumbs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appending(path: "\(UUID().uuidString).jpg")
        do {
            try jpeg.write(to: file)
            return file
        } catch {
            return nil
        }
    }
}
