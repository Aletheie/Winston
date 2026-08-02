import Foundation
import SwiftData
@testable import Winston

extension ModelContext {
    /// Test-only convenience. Production code must use a targeted repository
    /// query or the explicitly named global-analysis fetch.
    func allBooks() -> [Book] {
        (try? fetch(FetchDescriptor<Book>())) ?? []
    }

    /// Explicit fixture behavior mirroring mutation-log publication. Production
    /// writes must use CatalogMutationService or a specialized coordinator.
    @MainActor
    func fixtureSaveAndPublish(
        catalogChanged: Bool = true,
        affectedBookIDs: Set<UUID>? = nil,
        affectedWorkIDs: Set<UUID> = [],
        affectedAssetIDs: Set<UUID> = [],
        affectedCollectionIDs: Set<UUID> = [],
        fields: CatalogChangeFields = .all,
        changesBookMembership: Bool = false,
        fullTextAffectedBookIDs: Set<UUID>? = []
    ) throws {
        try save()
        LibraryMutationLog.shared.bump(
            catalogChanged: catalogChanged,
            affectedBookIDs: affectedBookIDs,
            affectedWorkIDs: affectedWorkIDs,
            affectedAssetIDs: affectedAssetIDs,
            affectedCollectionIDs: affectedCollectionIDs,
            fields: fields,
            changesBookMembership: changesBookMembership,
            fullTextAffectedBookIDs: fullTextAffectedBookIDs
        )
    }

    @discardableResult
    @MainActor
    func fixtureSaveBestEffort(
        catalogChanged: Bool = true,
        affectedBookIDs: Set<UUID>? = nil,
        affectedWorkIDs: Set<UUID> = [],
        affectedAssetIDs: Set<UUID> = [],
        affectedCollectionIDs: Set<UUID> = [],
        fields: CatalogChangeFields = .all,
        changesBookMembership: Bool = false,
        fullTextAffectedBookIDs: Set<UUID>? = []
    ) -> Bool {
        do {
            try fixtureSaveAndPublish(
                catalogChanged: catalogChanged,
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs,
                affectedAssetIDs: affectedAssetIDs,
                affectedCollectionIDs: affectedCollectionIDs,
                fields: fields,
                changesBookMembership: changesBookMembership,
                fullTextAffectedBookIDs: fullTextAffectedBookIDs
            )
            return true
        } catch {
            return false
        }
    }
}

enum TestManagedFileFixtureStore {
    static func importCopy(of source: URL, uuid: UUID) throws -> String {
        try AppPaths.ensureDirectory(AppPaths.booksDirectory)
        let ext = source.pathExtension.lowercased()
        let fileName = ext.isEmpty ? uuid.uuidString : "\(uuid.uuidString).\(ext)"
        guard let destination = BookFileStore.validatedURL(for: fileName) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if source.standardizedFileURL == destination.standardizedFileURL {
            return fileName
        }

        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(fileName).\(UUID().uuidString).fixture-importing")
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: temporary) }
        if let portableHTML = try HTMLAssetInliner.portableData(for: source) {
            try portableHTML.write(to: temporary)
        } else {
            try fileManager.copyItem(at: source, to: temporary)
        }
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

    static func delete(fileName: String) {
        guard let url = BookFileStore.validatedURL(for: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

private actor TestLibraryAccess {
    static let shared = TestLibraryAccess()

    private var isAvailable = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if isAvailable {
            isAvailable = false
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isAvailable = true
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
// Swaps the process-global AppPaths.rootDirectory — every suite using this must be @Suite(.serialized).
final class TestLibrary {
    let container: ModelContainer
    let context: ModelContext
    let root: URL
    private let previousRoot: URL
    lazy var managedFiles = ManagedFileCoordinator(
        trashBook: { fileManager, url in
            try fileManager.removeItem(at: url)
        }
    )

    init() async throws {
        await TestLibraryAccess.shared.acquire()
        previousRoot = AppPaths.rootDirectory
        root = FileManager.default.temporaryDirectory
            .appending(path: "WinstonTestLibrary-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            await TestLibraryAccess.shared.release()
            throw error
        }
        AppPaths.rootDirectory = root
        do {
            try AppPaths.ensureRequiredDirectories()
        } catch {
            AppPaths.rootDirectory = previousRoot
            try? FileManager.default.removeItem(at: root)
            await TestLibraryAccess.shared.release()
            throw error
        }
        container = PersistenceController.inMemory()
        context = container.mainContext
    }

    func installBookFile(from source: URL, fileName: String) throws {
        let destination = BookFileStore.url(for: fileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    deinit {
        AppPaths.rootDirectory = previousRoot
        try? FileManager.default.removeItem(at: root)
        Task { await TestLibraryAccess.shared.release() }
    }
}
