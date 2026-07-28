import Foundation
import SwiftData
import AppKit

nonisolated struct CoverAnalysisProposal: @unchecked Sendable {
    let image: NSImage
    let jpegData: Data
}

nonisolated enum CoverAnalysisWorker {
    @concurrent
    static func prepare(
        _ loadImage: @escaping @Sendable () -> NSImage?
    ) async -> CoverAnalysisProposal? {
        guard !Task.isCancelled,
              let image = loadImage(),
              !Task.isCancelled,
              let data = ImageTranscoder.jpegData(from: image),
              !Task.isCancelled else { return nil }
        return CoverAnalysisProposal(image: image, jpegData: data)
    }

    @concurrent
    static func extract(from url: URL) async -> CoverAnalysisProposal? {
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
        let originalScopeRaw = book.coverScopeRaw
        let originalCoverAssetUUID = book.coverAssetUUID
        let originalReference = book.coverReference
        guard let snapshot = BookAnalysisSnapshot(book: book) else { return }
        let token = beginOperation(for: bookID)
        let job = analysisCoordinator.start(
            snapshot: snapshot,
            kind: .coverExtraction,
            requestGeneration: "custom:\(originalVersion):\(token.uuidString)"
        ) { _ in
            await CoverAnalysisWorker.prepare(loadImage)
        }
        Task { [weak self] in
            guard let self else { return }
            defer {
                analysisCoordinator.finish(job.ticket)
                finishOperation(token, for: bookID)
            }
            guard let prepared = await analysisCoordinator.value(for: job),
                  analysisCoordinator.isCurrent(job.ticket),
                  operationIsCurrent(token, for: bookID),
                  let currentBook = try? mutations.book(id: bookID),
                  snapshot.matches(currentBook),
                  currentBook.coverScopeRaw == originalScopeRaw,
                  currentBook.coverAssetUUID == originalCoverAssetUUID,
                  currentBook.coverVersion == originalVersion else { return }
            let preparedMutation: PreparedCoverMutation
            do {
                preparedMutation = try await coverMutations.prepare(
                    payload: prepared.jpegData,
                    targetReference: CoverReference(
                        owner: .edition(bookID),
                        version: originalReference.version
                    ),
                    selectedBookIDs: [bookID],
                    expectedBookReferences: [bookID: originalReference],
                    priority: .user
                )
            } catch {
                return
            }
            guard analysisCoordinator.isCurrent(job.ticket),
                  operationIsCurrent(token, for: bookID),
                  let stagedBook = try? mutations.book(id: bookID),
                  snapshot.matches(stagedBook),
                  stagedBook.coverScopeRaw == originalScopeRaw,
                  stagedBook.coverAssetUUID == originalCoverAssetUUID,
                  stagedBook.coverVersion == originalVersion else {
                await coverMutations.abort(preparedMutation)
                return
            }
            do {
                _ = try await coverMutations.commit(
                    preparedMutation,
                    command: .updateCover(
                        bookID: bookID,
                        version: preparedMutation.targetReference.version
                    ),
                    affectedBookIDs: [bookID]
                ) {
                    let liveBook = try mutations.book(id: bookID)
                    guard analysisCoordinator.isCurrent(job.ticket),
                          operationIsCurrent(token, for: bookID),
                          snapshot.matches(liveBook),
                          liveBook.coverScopeRaw == originalScopeRaw,
                          liveBook.coverAssetUUID == originalCoverAssetUUID,
                          liveBook.coverVersion == originalVersion else {
                        throw CatalogMutationError.staleAnalysis
                    }
                }
            } catch {
                return
            }
        }
    }

    func resetCover(for book: Book) {
        let bookID = book.uuid
        let originalVersion = book.coverVersion
        let originalScopeRaw = book.coverScopeRaw
        let originalCoverAssetUUID = book.coverAssetUUID
        let originalReference = book.coverReference
        guard let snapshot = BookAnalysisSnapshot(book: book),
              snapshot.fileURL != nil else { return }
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
        Task { [weak self] in
            guard let self else { return }
            defer {
                analysisCoordinator.finish(job.ticket)
                finishOperation(token, for: bookID)
            }
            let inspected = await analysisCoordinator.value(for: job)
            guard analysisCoordinator.isCurrent(job.ticket),
                  operationIsCurrent(token, for: bookID),
                  let currentBook = try? mutations.book(id: bookID),
                  snapshot.matches(currentBook),
                  currentBook.coverScopeRaw == originalScopeRaw,
                  currentBook.coverAssetUUID == originalCoverAssetUUID,
                  currentBook.coverVersion == originalVersion,
                  inspected?.sourceIsCurrent(for: snapshot) != false else { return }
            let prepared = inspected?.value

            let preparedMutation: PreparedCoverMutation
            do {
                preparedMutation = try await coverMutations.prepare(
                    payload: prepared?.jpegData,
                    targetReference: CoverReference(
                        owner: .edition(bookID),
                        version: originalReference.version
                    ),
                    selectedBookIDs: [bookID],
                    expectedBookReferences: [bookID: originalReference],
                    priority: .user
                )
            } catch {
                return
            }
            guard analysisCoordinator.isCurrent(job.ticket),
                  operationIsCurrent(token, for: bookID),
                  let stagedBook = try? mutations.book(id: bookID),
                  snapshot.matches(stagedBook),
                  stagedBook.coverScopeRaw == originalScopeRaw,
                  stagedBook.coverAssetUUID == originalCoverAssetUUID,
                  stagedBook.coverVersion == originalVersion,
                  inspected?.sourceIsCurrent(for: snapshot) != false else {
                await coverMutations.abort(preparedMutation)
                return
            }
            do {
                _ = try await coverMutations.commit(
                    preparedMutation,
                    command: .updateCover(
                        bookID: bookID,
                        version: preparedMutation.targetReference.version
                    ),
                    affectedBookIDs: [bookID]
                ) {
                    let liveBook = try mutations.book(id: bookID)
                    guard analysisCoordinator.isCurrent(job.ticket),
                          operationIsCurrent(token, for: bookID),
                          snapshot.matches(liveBook),
                          liveBook.coverScopeRaw == originalScopeRaw,
                          liveBook.coverAssetUUID == originalCoverAssetUUID,
                          liveBook.coverVersion == originalVersion,
                          inspected?.sourceIsCurrent(for: snapshot) != false else {
                        throw CatalogMutationError.staleAnalysis
                    }
                }
            } catch {
                return
            }
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
