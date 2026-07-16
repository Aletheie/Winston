import Foundation
import SwiftData
import AppKit

@MainActor
@Observable
final class CoverService {
    private let modelContext: ModelContext
    private var operationTokens: [UUID: UUID] = [:]

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Custom covers

    func setCustomCover(for book: Book, from url: URL) {
        let uuid = book.uuid
        let token = beginOperation(for: uuid)
        Task {
            defer { finishOperation(token, for: uuid) }
            let image: NSImage? = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
            guard let image, operationIsCurrent(token, for: book) else { return }
            let previousCover = CoverStore.loadData(for: uuid)
            guard CoverStore.save(image, for: uuid) else { return }
            book.coverVersion += 1
            guard modelContext.saveQuietly(rollbackOnFailure: true) else {
                CoverStore.restore(previousCover, for: uuid)
                return
            }
            await CoverCache.shared.replace(image, for: book.fileURL)
        }
    }

    func resetCover(for book: Book) {
        let uuid = book.uuid
        let fileURL = book.fileURL
        let token = beginOperation(for: uuid)
        let previousCover = CoverStore.loadData(for: uuid)
        guard CoverStore.delete(for: uuid) else {
            finishOperation(token, for: uuid)
            return
        }
        book.coverVersion += 1
        guard modelContext.saveQuietly(rollbackOnFailure: true) else {
            CoverStore.restore(previousCover, for: uuid)
            finishOperation(token, for: uuid)
            return
        }
        Task {
            defer { finishOperation(token, for: uuid) }
            guard operationIsCurrent(token, for: book) else { return }
            await CoverCache.shared.replace(nil, for: fileURL)
            let image: NSImage? = await Task.detached(priority: .userInitiated) {
                CoverExtractor.extractCover(from: fileURL)
            }.value
            guard operationIsCurrent(token, for: book), book.fileURL == fileURL else { return }
            guard let image, CoverStore.save(image, for: uuid) else { return }
            book.coverVersion += 1
            guard modelContext.saveQuietly(rollbackOnFailure: true) else {
                CoverStore.delete(for: uuid)
                return
            }
            await CoverCache.shared.replace(image, for: fileURL)
        }
    }

    func cancelPending(for uuid: UUID) {
        operationTokens.removeValue(forKey: uuid)
    }

    private func beginOperation(for uuid: UUID) -> UUID {
        let token = UUID()
        operationTokens[uuid] = token
        return token
    }

    private func operationIsCurrent(_ token: UUID, for book: Book) -> Bool {
        operationTokens[book.uuid] == token && book.modelContext != nil
    }

    private func finishOperation(_ token: UUID, for uuid: UUID) {
        if operationTokens[uuid] == token { operationTokens.removeValue(forKey: uuid) }
    }
}
