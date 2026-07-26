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
    private let managedFiles: ManagedFileCoordinator
    private let analysisCoordinator: CatalogAnalysisCoordinator
    private var operationTokens: [UUID: UUID] = [:]

    init(
        modelContext: ModelContext,
        mutations: CatalogMutationService? = nil,
        managedFiles: ManagedFileCoordinator = .shared
    ) {
        let resolvedMutations = mutations ?? CatalogMutationService(
            modelContext: modelContext,
            managedFiles: managedFiles
        )
        self.mutations = resolvedMutations
        self.managedFiles = managedFiles
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
        let cacheURL = CoverStore.url(for: .edition(bookID))
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
            let previousIdentity: ManagedFileIdentitySnapshot
            do {
                previousIdentity = try await managedFiles.captureIdentity(
                    of: .cover(bookID: bookID)
                )
            } catch {
                return
            }
            let expectedVersion = originalVersion + 1
            let transaction: ManagedFileTransaction
            do {
                transaction = try await managedFiles.stage(
                    intent: .coverUpdate,
                    sources: [
                        .cover(
                            data: prepared.jpegData,
                            bookID: bookID,
                            replacing: previousIdentity
                        ),
                    ],
                    requirement: ManagedFileRequirement(
                        presentBookIDs: [bookID],
                        coverVersions: [bookID: expectedVersion]
                    )
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
                await managedFiles.abort(transaction)
                return
            }
            do {
                let result = try await mutations.commitFileMutation(
                    .updateCover(bookID: bookID, version: expectedVersion),
                    transaction: transaction,
                    affectedBookIDs: [bookID],
                    revertingOnFailure: {
                        if let rollbackBook = try? self.mutations.book(id: bookID) {
                            rollbackBook.coverVersion = originalVersion
                            rollbackBook.coverScopeRaw = originalScopeRaw
                            rollbackBook.coverAssetUUID = originalCoverAssetUUID
                        }
                    }
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
                    liveBook.coverVersion = expectedVersion
                    guard liveBook.selectCoverOwner(.edition(bookID)) else {
                        throw CatalogMutationError.invalidRequest
                    }
                }
                guard result.isFullyPublished else { return }
                await CoverCache.shared.replace(prepared.image, for: cacheURL)
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
        let cacheURL = CoverStore.url(for: .edition(bookID))
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

            let expectedVersion = originalVersion + 1
            let requirement = ManagedFileRequirement(
                presentBookIDs: [bookID],
                coverVersions: [bookID: expectedVersion]
            )
            let previousIdentity: ManagedFileIdentitySnapshot
            do {
                previousIdentity = try await managedFiles.captureIdentity(
                    of: .cover(bookID: bookID)
                )
            } catch {
                return
            }
            let transaction: ManagedFileTransaction
            do {
                if let data = prepared?.jpegData {
                    transaction = try await managedFiles.stage(
                        intent: .coverUpdate,
                        sources: [
                            .cover(
                                data: data,
                                bookID: bookID,
                                replacing: previousIdentity
                            ),
                        ],
                        requirement: requirement
                    )
                } else {
                    transaction = try await managedFiles.prepareCleanup(
                        intent: .coverUpdate,
                        requirement: requirement,
                        cleanups: [.file(previousIdentity)]
                    )
                }
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
                await managedFiles.abort(transaction)
                return
            }
            do {
                let result = try await mutations.commitFileMutation(
                    .updateCover(bookID: bookID, version: expectedVersion),
                    transaction: transaction,
                    affectedBookIDs: [bookID],
                    revertingOnFailure: {
                        if let rollbackBook = try? self.mutations.book(id: bookID) {
                            rollbackBook.coverVersion = originalVersion
                            rollbackBook.coverScopeRaw = originalScopeRaw
                            rollbackBook.coverAssetUUID = originalCoverAssetUUID
                        }
                    }
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
                    liveBook.coverVersion = expectedVersion
                    guard liveBook.selectCoverOwner(.edition(bookID)) else {
                        throw CatalogMutationError.invalidRequest
                    }
                }
                guard result.isFullyPublished else { return }
                await CoverCache.shared.replace(prepared?.image, for: cacheURL)
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
