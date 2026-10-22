import Foundation
import SwiftData
import AppKit

nonisolated enum CoverAnalysisWorker {
    @concurrent
    static func prepare(
        _ loadImage: @escaping @Sendable () -> NSImage?
    ) async -> Data? {
        guard !Task.isCancelled,
              let image = loadImage(),
              !Task.isCancelled,
              let data = ImageTranscoder.jpegData(from: image),
              !Task.isCancelled else { return nil }
        return data
    }

    @concurrent
    static func extract(from url: URL) async -> Data? {
        await prepare { CoverExtractor.extractCover(from: url) }
    }
}

@MainActor
@Observable
final class CoverService {
    private let mutations: CatalogMutationService
    private let coverMutations: CoverMutationCoordinator
    private let analysisCoordinator: CatalogAnalysisCoordinator
    private var operationTokens: [UUID: UUID] = [:]

    init(
        modelContext: ModelContext,
        mutations: CatalogMutationService? = nil,
        managedFiles: ManagedFileCoordinator = .shared,
        coverMutations: CoverMutationCoordinator? = nil
    ) {
        let resolvedManagedFiles = mutations?.managedFiles ?? managedFiles
        let resolvedMutations = mutations ?? CatalogMutationService(
            modelContext: modelContext,
            managedFiles: resolvedManagedFiles
        )
        self.mutations = resolvedMutations
        self.coverMutations = coverMutations ?? CoverMutationCoordinator.resolve(
            modelContext: modelContext,
            mutations: resolvedMutations,
            managedFiles: resolvedManagedFiles
        )
        analysisCoordinator = resolvedMutations.analysisCoordinator
    }

    // MARK: - Custom covers

    @discardableResult
    func setCustomCover(for book: Book, from url: URL) -> Task<Void, Never>? {
        beginCustomCoverOperation(for: book) {
            NSImage(contentsOf: url)
        }
    }

    @discardableResult
    func setCustomCover(for book: Book, from data: Data) -> Task<Void, Never>? {
        beginCustomCoverOperation(for: book) {
            NSImage(data: data)
        }
    }

    private func beginCustomCoverOperation(
        for book: Book,
        loadImage: @escaping @Sendable () -> NSImage?
    ) -> Task<Void, Never>? {
        let bookID = book.uuid
        let originalVersion = book.coverVersion
        let originalScopeRaw = book.coverScopeRaw
        let originalCoverAssetUUID = book.coverAssetUUID
        let originalReference = book.coverReference
        guard let snapshot = BookAnalysisSnapshot(book: book) else { return nil }
        let token = beginOperation(for: bookID)
        let job = analysisCoordinator.start(
            snapshot: snapshot,
            kind: .coverExtraction,
            requestGeneration: "custom:\(originalVersion):\(token.uuidString)"
        ) { _ in
            await CoverAnalysisWorker.prepare(loadImage)
        }
        return Task { [weak self] in
            guard let self else { return }
            defer {
                analysisCoordinator.finish(job.ticket)
                finishOperation(token, for: bookID)
            }
            guard let payload = await analysisCoordinator.value(for: job) else { return }
            await applyCover(payload, replacing: originalReference, for: bookID) {
                guard analysisCoordinator.isCurrent(job.ticket),
                      operationIsCurrent(token, for: bookID),
                      let currentBook = try? mutations.book(id: bookID) else { return false }
                return snapshot.matches(currentBook)
                    && currentBook.coverScopeRaw == originalScopeRaw
                    && currentBook.coverAssetUUID == originalCoverAssetUUID
                    && currentBook.coverVersion == originalVersion
            }
        }
    }

    @discardableResult
    func resetCover(for book: Book) -> Task<Void, Never>? {
        let bookID = book.uuid
        let originalVersion = book.coverVersion
        let originalScopeRaw = book.coverScopeRaw
        let originalCoverAssetUUID = book.coverAssetUUID
        let originalReference = book.coverReference
        guard let snapshot = BookAnalysisSnapshot(book: book),
              snapshot.fileURL != nil else { return nil }
        let token = beginOperation(for: bookID)
        let job = analysisCoordinator.start(
            snapshot: snapshot,
            kind: .coverExtraction,
            requestGeneration: "reset:\(originalVersion):\(token.uuidString)"
        ) { snapshot in
            await CatalogAnalysisWorker.inspect(snapshot: snapshot) { url in
                await CoverAnalysisWorker.extract(from: url)
            }
        }
        return Task { [weak self] in
            guard let self else { return }
            defer {
                analysisCoordinator.finish(job.ticket)
                finishOperation(token, for: bookID)
            }
            let inspected = await analysisCoordinator.value(for: job)
            await applyCover(inspected?.value, replacing: originalReference, for: bookID) {
                guard analysisCoordinator.isCurrent(job.ticket),
                      operationIsCurrent(token, for: bookID),
                      let currentBook = try? mutations.book(id: bookID) else { return false }
                return snapshot.matches(currentBook)
                    && currentBook.coverScopeRaw == originalScopeRaw
                    && currentBook.coverAssetUUID == originalCoverAssetUUID
                    && currentBook.coverVersion == originalVersion
                    && inspected?.sourceIsCurrent(for: snapshot) != false
            }
        }
    }

    /// Revalidate before staging, after suspension, and inside the durable commit.
    /// A nil payload intentionally removes a custom cover when reset finds none.
    private func applyCover(
        _ payload: Data?,
        replacing originalReference: CoverReference,
        for bookID: UUID,
        validating isCurrent: () -> Bool
    ) async {
        guard isCurrent() else { return }
        do {
            let prepared = try await coverMutations.prepare(
                payload: payload,
                targetReference: CoverReference(
                    owner: .edition(bookID),
                    version: originalReference.version
                ),
                selectedBookIDs: [bookID],
                expectedBookReferences: [bookID: originalReference],
                priority: .user
            )
            guard isCurrent() else {
                await coverMutations.abort(prepared)
                return
            }
            _ = try await coverMutations.commit(
                prepared,
                command: .updateCover(
                    bookID: bookID,
                    version: prepared.targetReference.version
                ),
                affectedBookIDs: [bookID]
            ) {
                guard isCurrent() else { throw CatalogMutationError.staleAnalysis }
            }
        } catch {
            return
        }
    }

    func cancelPending(for uuid: UUID) {
        operationTokens.removeValue(forKey: uuid)
        analysisCoordinator.cancel(bookID: uuid, kind: .coverExtraction)
    }

    private func beginOperation(for uuid: UUID) -> UUID {
        let token = UUID()
        operationTokens[uuid] = token
        return token
    }

    private func operationIsCurrent(_ token: UUID, for bookID: UUID) -> Bool {
        operationTokens[bookID] == token
    }

    private func finishOperation(_ token: UUID, for uuid: UUID) {
        if operationTokens[uuid] == token { operationTokens.removeValue(forKey: uuid) }
    }
}
