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
        beginCustomCoverOperation(for: book) {
            NSImage(contentsOf: url)
        }
    }

    func setCustomCover(for book: Book, from data: Data) {
        beginCustomCoverOperation(for: book) {
            NSImage(data: data)
        }
    }

    private func beginCustomCoverOperation(
        for book: Book,
        loadImage: @escaping @Sendable () -> NSImage?
    ) {
        let uuid = book.uuid
        let token = beginOperation(for: uuid)
        Task {
            defer { finishOperation(token, for: uuid) }
            let image = await Task.detached(priority: .userInitiated, operation: loadImage).value
            guard let image, operationIsCurrent(token, for: book) else { return }
            let diskWrite = await Task.detached(priority: .userInitiated) {
                let previous = CoverStore.loadData(for: uuid)
                return (previous: previous, saved: CoverStore.save(image, for: uuid))
            }.value
            guard diskWrite.saved, operationIsCurrent(token, for: book) else { return }
            book.coverVersion += 1
            guard modelContext.saveQuietly(rollbackOnFailure: true) else {
                _ = await Task.detached(priority: .utility) {
                    CoverStore.restore(diskWrite.previous, for: uuid)
                }.value
                return
            }
            await CoverCache.shared.replace(image, for: book.fileURL)
        }
    }

    func resetCover(for book: Book) {
        let uuid = book.uuid
        let fileURL = book.fileURL
        let token = beginOperation(for: uuid)
        Task {
            defer { finishOperation(token, for: uuid) }
            let diskReset = await Task.detached(priority: .userInitiated) {
                let previous = CoverStore.loadData(for: uuid)
                return (previous: previous, deleted: CoverStore.delete(for: uuid))
            }.value
            guard diskReset.deleted, operationIsCurrent(token, for: book) else { return }
            book.coverVersion += 1
            guard modelContext.saveQuietly(rollbackOnFailure: true) else {
                _ = await Task.detached(priority: .utility) {
                    CoverStore.restore(diskReset.previous, for: uuid)
                }.value
                return
            }
            guard operationIsCurrent(token, for: book) else { return }
            await CoverCache.shared.replace(nil, for: fileURL)
            let image: NSImage? = await Task.detached(priority: .userInitiated) {
                CoverExtractor.extractCover(from: fileURL)
            }.value
            guard operationIsCurrent(token, for: book), book.fileURL == fileURL else { return }
            guard let image else { return }
            let saved = await Task.detached(priority: .userInitiated) {
                CoverStore.save(image, for: uuid)
            }.value
            guard saved, operationIsCurrent(token, for: book), book.fileURL == fileURL else { return }
            book.coverVersion += 1
            guard modelContext.saveQuietly(rollbackOnFailure: true) else {
                _ = await Task.detached(priority: .utility) {
                    CoverStore.delete(for: uuid)
                }.value
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
