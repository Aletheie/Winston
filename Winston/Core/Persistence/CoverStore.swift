import AppKit

nonisolated struct CoverMutationToken: Sendable, Equatable {
    fileprivate let owner: CoverOwner
    fileprivate let userGeneration: UInt64
}

nonisolated struct CoverRollbackTicket: Sendable {
    let owner: CoverOwner
    let previousData: Data?
    fileprivate let userGeneration: UInt64
}

actor CoverRepository {
    static let shared = CoverRepository()

    private var userGenerations: [CoverOwner: UInt64] = [:]
    private let coversDirectory: URL?

    init(coversDirectory: URL? = nil) {
        self.coversDirectory = coversDirectory
    }

    func beginUserMutation(for owner: CoverOwner) -> CoverMutationToken {
        let generation = userGenerations[owner, default: 0] &+ 1
        userGenerations[owner] = generation
        return CoverMutationToken(owner: owner, userGeneration: generation)
    }

    func beginUserMutation(for bookID: UUID) -> CoverMutationToken {
        beginUserMutation(for: .edition(bookID))
    }

    func beginBackgroundMutation(for owner: CoverOwner) -> CoverMutationToken {
        CoverMutationToken(
            owner: owner,
            userGeneration: userGenerations[owner, default: 0]
        )
    }

    func beginBackgroundMutation(for bookID: UUID) -> CoverMutationToken {
        beginBackgroundMutation(for: .edition(bookID))
    }

    func isCurrent(_ token: CoverMutationToken) -> Bool {
        userGenerations[token.owner, default: 0] == token.userGeneration
    }

    func install(
        _ data: Data,
        using token: CoverMutationToken,
        onlyIfMissing: Bool = false
    ) -> CoverRollbackTicket? {
        guard isCurrent(token) else { return nil }
        let directory = coversDirectory ?? AppPaths.coversDirectory
        if onlyIfMissing, CoverStore.exists(for: token.owner, in: directory) { return nil }
        let previous = CoverStore.loadData(for: token.owner, in: directory)
        guard CoverStore.restore(data, for: token.owner, in: directory) else { return nil }
        return CoverRollbackTicket(
            owner: token.owner,
            previousData: previous,
            userGeneration: token.userGeneration
        )
    }

    func remove(using token: CoverMutationToken) -> CoverRollbackTicket? {
        guard isCurrent(token) else { return nil }
        let directory = coversDirectory ?? AppPaths.coversDirectory
        let previous = CoverStore.loadData(for: token.owner, in: directory)
        guard CoverStore.delete(for: token.owner, in: directory) else { return nil }
        return CoverRollbackTicket(
            owner: token.owner,
            previousData: previous,
            userGeneration: token.userGeneration
        )
    }

    func copy(
        from sourceOwner: CoverOwner,
        using token: CoverMutationToken,
        onlyIfMissing: Bool = false
    ) -> CoverRollbackTicket? {
        let directory = coversDirectory ?? AppPaths.coversDirectory
        guard let data = CoverStore.loadData(for: sourceOwner, in: directory) else { return nil }
        return install(data, using: token, onlyIfMissing: onlyIfMissing)
    }

    func copy(
        from sourceID: UUID,
        using token: CoverMutationToken,
        onlyIfMissing: Bool = false
    ) -> CoverRollbackTicket? {
        copy(from: .edition(sourceID), using: token, onlyIfMissing: onlyIfMissing)
    }

    func rollback(_ ticket: CoverRollbackTicket) -> Bool {
        guard userGenerations[ticket.owner, default: 0] == ticket.userGeneration,
              CoverStore.restore(
                  ticket.previousData,
                  for: ticket.owner,
                  in: coversDirectory ?? AppPaths.coversDirectory
              ) else { return false }
        userGenerations[ticket.owner] = ticket.userGeneration &+ 1
        return true
    }

    func deletePermanently(for owner: CoverOwner) -> Bool {
        userGenerations[owner] = userGenerations[owner, default: 0] &+ 1
        return CoverStore.delete(for: owner, in: coversDirectory ?? AppPaths.coversDirectory)
    }

    func deletePermanently(for bookID: UUID) -> Bool {
        deletePermanently(for: .edition(bookID))
    }

    func invalidate(for owner: CoverOwner) {
        userGenerations[owner] = userGenerations[owner, default: 0] &+ 1
    }

    func invalidate(for bookID: UUID) {
        invalidate(for: .edition(bookID))
    }
}

enum CoverStore {
    nonisolated static func url(
        for owner: CoverOwner,
        in directory: URL = AppPaths.coversDirectory
    ) -> URL {
        directory.appending(path: owner.storageFileName)
    }

    @discardableResult
    nonisolated static func save(_ image: NSImage, for owner: CoverOwner) -> Bool {
        guard let jpeg = ImageTranscoder.jpegData(from: image) else { return false }
        return write(jpeg, for: owner, in: AppPaths.coversDirectory)
    }

    @discardableResult
    nonisolated static func save(_ image: NSImage, for uuid: UUID) -> Bool {
        save(image, for: .edition(uuid))
    }

    nonisolated static func load(for owner: CoverOwner) -> NSImage? {
        NSImage(contentsOf: url(for: owner))
    }

    nonisolated static func load(for uuid: UUID) -> NSImage? {
        load(for: .edition(uuid))
    }

    nonisolated static func exists(
        for owner: CoverOwner,
        in directory: URL = AppPaths.coversDirectory
    ) -> Bool {
        FileManager.default.fileExists(
            atPath: url(for: owner, in: directory).path(percentEncoded: false)
        )
    }

    nonisolated static func exists(for uuid: UUID, in directory: URL = AppPaths.coversDirectory) -> Bool {
        exists(for: .edition(uuid), in: directory)
    }

    nonisolated static func loadData(
        for owner: CoverOwner,
        in directory: URL = AppPaths.coversDirectory
    ) -> Data? {
        try? Data(contentsOf: url(for: owner, in: directory))
    }

    nonisolated static func loadData(for uuid: UUID, in directory: URL = AppPaths.coversDirectory) -> Data? {
        loadData(for: .edition(uuid), in: directory)
    }

    @discardableResult
    nonisolated static func copy(from source: CoverOwner, to destination: CoverOwner) -> Bool {
        guard let data = loadData(for: source) else { return false }
        return write(data, for: destination, in: AppPaths.coversDirectory)
    }

    @discardableResult
    nonisolated static func copy(from sourceUUID: UUID, to destinationUUID: UUID) -> Bool {
        copy(from: .edition(sourceUUID), to: .edition(destinationUUID))
    }

    @discardableResult
    nonisolated static func delete(
        for owner: CoverOwner,
        in directory: URL = AppPaths.coversDirectory
    ) -> Bool {
        let url = url(for: owner, in: directory)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    nonisolated static func delete(for uuid: UUID, in directory: URL = AppPaths.coversDirectory) -> Bool {
        delete(for: .edition(uuid), in: directory)
    }

    @discardableResult
    nonisolated static func restore(
        _ data: Data?,
        for owner: CoverOwner,
        in directory: URL = AppPaths.coversDirectory
    ) -> Bool {
        if let data {
            return write(data, for: owner, in: directory)
        }
        return delete(for: owner, in: directory)
    }

    @discardableResult
    nonisolated static func restore(
        _ data: Data?,
        for uuid: UUID,
        in directory: URL = AppPaths.coversDirectory
    ) -> Bool {
        restore(data, for: .edition(uuid), in: directory)
    }

    private nonisolated static func write(
        _ data: Data,
        for owner: CoverOwner,
        in directory: URL
    ) -> Bool {
        do {
            try AppPaths.ensureDirectory(directory)
            try data.write(to: url(for: owner, in: directory), options: .atomic)
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
