import Foundation
import SwiftData
import AppKit

@MainActor
@Observable
final class CoverService {
    private let modelContext: ModelContext
    private let mutations: CatalogMutationService
    private let managedFiles: ManagedFileCoordinator
    private var operationTokens: [UUID: UUID] = [:]

    init(
        modelContext: ModelContext,
        mutations: CatalogMutationService? = nil,
        managedFiles: ManagedFileCoordinator = .shared
    ) {
        self.modelContext = modelContext
        self.mutations = mutations ?? CatalogMutationService(
            modelContext: modelContext,
            managedFiles: managedFiles
        )
        self.managedFiles = managedFiles
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
        let bookID = book.uuid
        let originalVersion = book.coverVersion
        let cacheURL = book.coverCacheURL
        let token = beginOperation(for: bookID)
        Task {
            defer { finishOperation(token, for: bookID) }
            let prepared = await Task.detached(priority: .userInitiated) { () -> (NSImage, Data)? in
                guard let image = loadImage(),
                      let data = ImageTranscoder.jpegData(from: image) else { return nil }
                return (image, data)
            }.value
            guard let (image, data) = prepared,
                  operationIsCurrent(token, for: book),
                  book.coverVersion == originalVersion else { return }
            let expectedVersion = originalVersion + 1
            let transaction: ManagedFileTransaction
            do {
                transaction = try await managedFiles.stage(
                    intent: .coverUpdate,
                    sources: [.cover(data: data, bookID: bookID)],
                    requirement: ManagedFileRequirement(
                        presentBookIDs: [bookID],
                        coverVersions: [bookID: expectedVersion]
                    )
                )
            } catch {
                return
            }
            guard operationIsCurrent(token, for: book),
                  book.coverVersion == originalVersion else {
                await managedFiles.abort(transaction)
                return
            }
            do {
                let result = try await mutations.commitFileMutation(
                    .updateCover(bookID: bookID, version: expectedVersion),
                    transaction: transaction,
                    affectedBookIDs: [bookID],
                    revertingOnFailure: {
                        book.coverVersion = originalVersion
                    }
                ) {
                    let liveBook = try mutations.book(id: bookID)
                    guard liveBook.coverVersion == originalVersion else {
                        throw CatalogMutationError.modelNotFound
                    }
                    liveBook.coverVersion = expectedVersion
                }
                guard result.isFullyPublished else { return }
                await CoverCache.shared.replace(image, for: cacheURL)
            } catch {
                return
            }
        }
    }

    func resetCover(for book: Book) {
        let bookID = book.uuid
        let originalVersion = book.coverVersion
        let fileURL = book.coverCacheURL
        let token = beginOperation(for: bookID)
        Task {
            defer { finishOperation(token, for: bookID) }
            let prepared = await Task.detached(priority: .userInitiated) { () -> (NSImage, Data)? in
                guard let image = CoverExtractor.extractCover(from: fileURL),
                      let data = ImageTranscoder.jpegData(from: image) else { return nil }
                return (image, data)
            }.value
            guard operationIsCurrent(token, for: book),
                  book.coverVersion == originalVersion,
                  book.coverCacheURL == fileURL else { return }

            let expectedVersion = originalVersion + 1
            let requirement = ManagedFileRequirement(
                presentBookIDs: [bookID],
                coverVersions: [bookID: expectedVersion]
            )
            let transaction: ManagedFileTransaction
            do {
                if let data = prepared?.1 {
                    transaction = try await managedFiles.stage(
                        intent: .coverUpdate,
                        sources: [.cover(data: data, bookID: bookID)],
                        requirement: requirement
                    )
                } else {
                    transaction = try await managedFiles.prepareCleanup(
                        intent: .coverUpdate,
                        requirement: requirement,
                        cleanups: [.cover(bookID: bookID)]
                    )
                }
            } catch {
                return
            }
            guard operationIsCurrent(token, for: book),
                  book.coverVersion == originalVersion,
                  book.coverCacheURL == fileURL else {
                await managedFiles.abort(transaction)
                return
            }
            do {
                let result = try await mutations.commitFileMutation(
                    .updateCover(bookID: bookID, version: expectedVersion),
                    transaction: transaction,
                    affectedBookIDs: [bookID],
                    revertingOnFailure: {
                        book.coverVersion = originalVersion
                    }
                ) {
                    let liveBook = try mutations.book(id: bookID)
                    guard liveBook.coverVersion == originalVersion,
                          liveBook.coverCacheURL == fileURL else {
                        throw CatalogMutationError.modelNotFound
                    }
                    liveBook.coverVersion = expectedVersion
                }
                guard result.isFullyPublished else { return }
                await CoverCache.shared.replace(prepared?.0, for: fileURL)
            } catch {
                return
            }
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
