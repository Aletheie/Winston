import AppKit

nonisolated struct CoverMutationToken: Sendable, Equatable {
    fileprivate let bookID: UUID
    fileprivate let userGeneration: UInt64
}

nonisolated struct CoverRollbackTicket: Sendable {
    let bookID: UUID
    let previousData: Data?
    fileprivate let userGeneration: UInt64
}

actor CoverRepository {
    static let shared = CoverRepository()

    private var userGenerations: [UUID: UInt64] = [:]
    private let coversDirectory: URL?

    init(coversDirectory: URL? = nil) {
        self.coversDirectory = coversDirectory
    }

    func beginUserMutation(for bookID: UUID) -> CoverMutationToken {
        let generation = userGenerations[bookID, default: 0] &+ 1
        userGenerations[bookID] = generation
        return CoverMutationToken(bookID: bookID, userGeneration: generation)
    }

    func beginBackgroundMutation(for bookID: UUID) -> CoverMutationToken {
        CoverMutationToken(bookID: bookID, userGeneration: userGenerations[bookID, default: 0])
    }

    func isCurrent(_ token: CoverMutationToken) -> Bool {
        userGenerations[token.bookID, default: 0] == token.userGeneration
    }

    func install(
        _ data: Data,
        using token: CoverMutationToken,
        onlyIfMissing: Bool = false
    ) -> CoverRollbackTicket? {
        guard isCurrent(token) else { return nil }
        let directory = coversDirectory ?? AppPaths.coversDirectory
        if onlyIfMissing, CoverStore.exists(for: token.bookID, in: directory) { return nil }
        let previous = CoverStore.loadData(for: token.bookID, in: directory)
        guard CoverStore.restore(data, for: token.bookID, in: directory) else { return nil }
        return CoverRollbackTicket(
            bookID: token.bookID,
            previousData: previous,
            userGeneration: token.userGeneration
        )
    }

    func remove(using token: CoverMutationToken) -> CoverRollbackTicket? {
        guard isCurrent(token) else { return nil }
        let directory = coversDirectory ?? AppPaths.coversDirectory
        let previous = CoverStore.loadData(for: token.bookID, in: directory)
        guard CoverStore.delete(for: token.bookID, in: directory) else { return nil }
        return CoverRollbackTicket(
            bookID: token.bookID,
            previousData: previous,
            userGeneration: token.userGeneration
        )
    }

    func copy(
        from sourceID: UUID,
        using token: CoverMutationToken,
        onlyIfMissing: Bool = false
    ) -> CoverRollbackTicket? {
        let directory = coversDirectory ?? AppPaths.coversDirectory
        guard let data = CoverStore.loadData(for: sourceID, in: directory) else { return nil }
        return install(data, using: token, onlyIfMissing: onlyIfMissing)
    }

    func rollback(_ ticket: CoverRollbackTicket) -> Bool {
        guard userGenerations[ticket.bookID, default: 0] == ticket.userGeneration,
              CoverStore.restore(
                  ticket.previousData,
                  for: ticket.bookID,
                  in: coversDirectory ?? AppPaths.coversDirectory
              ) else { return false }
        userGenerations[ticket.bookID] = ticket.userGeneration &+ 1
        return true
    }

    func deletePermanently(for bookID: UUID) -> Bool {
        userGenerations[bookID] = userGenerations[bookID, default: 0] &+ 1
        return CoverStore.delete(for: bookID, in: coversDirectory ?? AppPaths.coversDirectory)
    }

    func invalidate(for bookID: UUID) {
        userGenerations[bookID] = userGenerations[bookID, default: 0] &+ 1
    }
}

enum CoverStore {
    nonisolated private static func coverURL(for uuid: UUID, in directory: URL) -> URL {
        directory.appending(path: "\(uuid.uuidString).jpg")
    }

    @discardableResult
    nonisolated static func save(_ image: NSImage, for uuid: UUID) -> Bool {
        guard let jpeg = ImageTranscoder.jpegData(from: image) else { return false }
        return write(jpeg, for: uuid, in: AppPaths.coversDirectory)
    }

    nonisolated static func load(for uuid: UUID) -> NSImage? {
        NSImage(contentsOf: coverURL(for: uuid, in: AppPaths.coversDirectory))
    }

    nonisolated static func exists(for uuid: UUID, in directory: URL = AppPaths.coversDirectory) -> Bool {
        FileManager.default.fileExists(atPath: coverURL(for: uuid, in: directory).path(percentEncoded: false))
    }

    nonisolated static func loadData(for uuid: UUID, in directory: URL = AppPaths.coversDirectory) -> Data? {
        try? Data(contentsOf: coverURL(for: uuid, in: directory))
    }

    @discardableResult
    nonisolated static func copy(from sourceUUID: UUID, to destinationUUID: UUID) -> Bool {
        guard let data = loadData(for: sourceUUID) else { return false }
        return write(data, for: destinationUUID, in: AppPaths.coversDirectory)
    }

    @discardableResult
    nonisolated static func delete(for uuid: UUID, in directory: URL = AppPaths.coversDirectory) -> Bool {
        let url = coverURL(for: uuid, in: directory)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    nonisolated static func restore(
        _ data: Data?,
        for uuid: UUID,
        in directory: URL = AppPaths.coversDirectory
    ) -> Bool {
        if let data {
            return write(data, for: uuid, in: directory)
        }
        return delete(for: uuid, in: directory)
    }

    private nonisolated static func write(_ data: Data, for uuid: UUID, in directory: URL) -> Bool {
        do {
            try AppPaths.ensureDirectory(directory)
            try data.write(to: coverURL(for: uuid, in: directory), options: .atomic)
            return true
        } catch {
            return false
        }
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
