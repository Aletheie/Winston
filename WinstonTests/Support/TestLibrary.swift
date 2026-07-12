import Foundation
import SwiftData
@testable import Winston

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
