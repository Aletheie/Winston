import Foundation
import SwiftData
import AppKit

@MainActor
@Observable
final class CoverService {
    private let modelContext: ModelContext
    private let covers: CoverRepository
    private var operationTokens: [UUID: UUID] = [:]

    init(modelContext: ModelContext, covers: CoverRepository = .shared) {
        self.modelContext = modelContext
        self.covers = covers
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
            let repositoryToken = await covers.beginUserMutation(for: uuid)
            guard operationIsCurrent(token, for: book) else { return }
            let prepared = await Task.detached(priority: .userInitiated) {
                guard let image = loadImage(),
                      let data = ImageTranscoder.jpegData(from: image) else { return nil }
                return (image, data)
            }.value
            guard let (image, data) = prepared,
                  operationIsCurrent(token, for: book),
                  let rollback = await covers.install(data, using: repositoryToken),
                  operationIsCurrent(token, for: book),
                  await covers.isCurrent(repositoryToken) else { return }
            book.coverVersion += 1
            guard modelContext.saveQuietly(rollbackOnFailure: true) else {
                _ = await covers.rollback(rollback)
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
            let repositoryToken = await covers.beginUserMutation(for: uuid)
            guard operationIsCurrent(token, for: book),
                  let rollback = await covers.remove(using: repositoryToken),
                  operationIsCurrent(token, for: book),
                  await covers.isCurrent(repositoryToken) else { return }
            book.coverVersion += 1
            guard modelContext.saveQuietly(rollbackOnFailure: true) else {
                _ = await covers.rollback(rollback)
                return
            }
            guard operationIsCurrent(token, for: book) else { return }
            await CoverCache.shared.replace(nil, for: fileURL)
            let prepared = await Task.detached(priority: .userInitiated) {
                guard let image = CoverExtractor.extractCover(from: fileURL),
                      let data = ImageTranscoder.jpegData(from: image) else { return nil }
                return (image, data)
            }.value
            guard operationIsCurrent(token, for: book), book.fileURL == fileURL else { return }
            guard let (image, data) = prepared,
                  let extractionRollback = await covers.install(data, using: repositoryToken),
                  operationIsCurrent(token, for: book),
                  book.fileURL == fileURL,
                  await covers.isCurrent(repositoryToken) else { return }
            book.coverVersion += 1
            guard modelContext.saveQuietly(rollbackOnFailure: true) else {
                _ = await covers.rollback(extractionRollback)
                return
            }
            await CoverCache.shared.replace(image, for: fileURL)
        }
    }

    func cancelPending(for uuid: UUID) {
        operationTokens.removeValue(forKey: uuid)
        Task { await covers.invalidate(for: uuid) }
    }

    func deletePermanently(for uuid: UUID) {
        operationTokens.removeValue(forKey: uuid)
        Task { await covers.deletePermanently(for: uuid) }
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
