import Foundation

nonisolated enum CalibreImportSessionPhase: String, Codable, Sendable, Equatable {
    case prepared
    case running
    case cancelling
    case cancelled
    case failed
    case completed
}

nonisolated enum CalibreImportItemState: String, Codable, Sendable, Equatable {
    case pending
    case prepared
    case failed
    case completed
}

nonisolated enum CalibreImportDecision: Codable, Sendable, Equatable {
    case skipExact(existingBookID: UUID)
    case merge(existingBookID: UUID, workID: UUID?)
    case addEdition(workID: UUID)
    case newWork
    case needsReview(candidateWorkIDs: [UUID])
}

nonisolated enum CalibreImportOutcomeCategory: String, Codable, Sendable, Equatable {
    case imported
    case merged
    case skippedExact
    case needsReview
    case failed
}

nonisolated struct CalibreImportOutcome: Codable, Sendable, Equatable {
    let calibreID: Int64
    let category: CalibreImportOutcomeCategory
    let bookID: UUID?
    var message: String?
}

nonisolated struct CalibreImportSummary: Codable, Sendable, Equatable {
    let sessionID: UUID
    let phase: CalibreImportSessionPhase
    let total: Int
    let imported: Int
    let merged: Int
    let skippedExact: Int
    let needsReview: Int
    let failed: Int
    let pending: Int
    let unsafeRejectedSources: Int

    var completed: Int { imported + merged + skippedExact + needsReview }
    var isComplete: Bool { phase == .completed }
}

nonisolated struct CalibreImportProgress: Sendable, Equatable {
    let sessionID: UUID
    let phase: CalibreImportSessionPhase
    let completed: Int
    let total: Int
}

nonisolated struct CalibreImportManifest: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    struct Item: Codable, Sendable, Equatable {
        let calibreID: Int64
        let book: CalibreBook
        let bookID: UUID
        let workID: UUID
        let assetIDs: [UUID]
        var state: CalibreImportItemState
        var decision: CalibreImportDecision?
        var transactionIDs: [UUID]
        var outcome: CalibreImportOutcome?
        var lastError: String?
        var unsafeRejectedSources: Int
    }

    let schemaVersion: Int
    let id: UUID
    let sourceRoot: URL
    let createdAt: Date
    let collectionID: UUID
    let collectionName: String
    var updatedAt: Date
    var phase: CalibreImportSessionPhase
    var unsafeRejectedSources: Int
    var items: [Item]
}

nonisolated struct CalibreImportPreparedItem: Sendable, Equatable {
    let calibreID: Int64
    let decision: CalibreImportDecision
    let transactionIDs: [UUID]
}

nonisolated struct CalibreImportChunkFailure: Sendable, Equatable {
    let calibreID: Int64?
    let message: String
    let isCancellation: Bool
    let preservePreparedItems: Bool
}

nonisolated struct CalibreImportChunkResult: Sendable, Equatable {
    var outcomes: [CalibreImportOutcome] = []
    var resetItemIDs: Set<Int64> = []
    var unsafeRejectedSourcesByItem: [Int64: Int] = [:]
    var failure: CalibreImportChunkFailure?
}

/// Durable orchestration and cancellation boundary for one Calibre import.
///
/// The actor owns the manifest state machine. File staging and catalog commits
/// are supplied by the main-actor service, but a chunk cannot reach the catalog
/// until its decision and managed-file transaction IDs are durably journaled.
actor CalibreImportSession {
    typealias ChunkProcessor = @Sendable ([CalibreImportManifest.Item]) async -> CalibreImportChunkResult
    typealias ProgressHandler = @Sendable (CalibreImportProgress) async -> Void

    private var manifest: CalibreImportManifest
    private let manifestURL: URL
    private var cancellationRequested = false

    private init(
        manifest: CalibreImportManifest,
        directory: URL
    ) {
        self.manifest = manifest
        self.manifestURL = directory.appending(path: "\(manifest.id.uuidString).json")
    }

    nonisolated static func create(
        libraryRoot: URL,
        books: [CalibreBook],
        unsafeRejectedSources: Int,
        collectionName: String,
        directory: URL = AppPaths.calibreImportSessionsDirectory,
        id: UUID = UUID(),
        now: Date = .now
    ) async throws -> CalibreImportSession {
        let items = books.sorted { lhs, rhs in
            if lhs.calibreID == rhs.calibreID { return lhs.title < rhs.title }
            return lhs.calibreID < rhs.calibreID
        }.map { book in
            CalibreImportManifest.Item(
                calibreID: book.calibreID,
                book: book,
                bookID: UUID(),
                workID: UUID(),
                assetIDs: (0..<(1 + book.additionalSourceFiles.count)).map { _ in UUID() },
                state: .pending,
                decision: nil,
                transactionIDs: [],
                outcome: nil,
                lastError: nil,
                unsafeRejectedSources: 0
            )
        }
        let manifest = CalibreImportManifest(
            schemaVersion: CalibreImportManifest.currentSchemaVersion,
            id: id,
            sourceRoot: libraryRoot.standardizedFileURL.resolvingSymlinksInPath(),
            createdAt: now,
            collectionID: UUID(),
            collectionName: collectionName,
            updatedAt: now,
            phase: .prepared,
            unsafeRejectedSources: unsafeRejectedSources,
            items: items
        )
        let session = CalibreImportSession(
            manifest: manifest,
            directory: directory
        )
        try await session.persist()
        return session
    }

    nonisolated static func resumable(
        for libraryRoot: URL,
        directory: URL = AppPaths.calibreImportSessionsDirectory
    ) async throws -> CalibreImportSession? {
        let canonicalRoot = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        return try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else {
                return nil
            }
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
            let decoder = JSONDecoder()
            let candidates = urls.compactMap { url -> CalibreImportManifest? in
                guard let data = try? Data(contentsOf: url),
                      let decoded = try? decoder.decode(CalibreImportManifest.self, from: data),
                      decoded.schemaVersion == CalibreImportManifest.currentSchemaVersion,
                      decoded.phase != .completed,
                      decoded.sourceRoot.standardizedFileURL == canonicalRoot
                else { return nil }
                return decoded
            }
            guard let manifest = candidates.max(by: { $0.updatedAt < $1.updatedAt }) else {
                return nil
            }
            return CalibreImportSession(
                manifest: manifest,
                directory: directory
            )
        }.value
    }

    func snapshot() -> CalibreImportManifest { manifest }

    func summary() -> CalibreImportSummary { makeSummary() }

    func progress() -> CalibreImportProgress {
        CalibreImportProgress(
            sessionID: manifest.id,
            phase: manifest.phase,
            completed: manifest.items.count(where: { $0.state == .completed }),
            total: manifest.items.count
        )
    }

    func shouldCancel() -> Bool {
        cancellationRequested || Task.isCancelled
    }

    func requestCancellation() {
        cancellationRequested = true
        guard manifest.phase == .running else { return }
        manifest.phase = .cancelling
        manifest.updatedAt = .now
        try? persist()
    }

    /// Records the exact catalog plan before the corresponding save can start.
    func prepare(_ preparedItems: [CalibreImportPreparedItem]) throws {
        guard !preparedItems.isEmpty else { return }
        let previous = manifest
        for prepared in preparedItems {
            guard let index = manifest.items.firstIndex(where: { $0.calibreID == prepared.calibreID }),
                  manifest.items[index].state != .completed else { continue }
            manifest.items[index].state = .prepared
            manifest.items[index].decision = prepared.decision
            manifest.items[index].transactionIDs = prepared.transactionIDs
            manifest.items[index].outcome = nil
            manifest.items[index].lastError = nil
        }
        manifest.updatedAt = .now
        do {
            try persist()
        } catch {
            manifest = previous
            throw error
        }
    }

    /// Reconciles crash-interrupted prepared rows against the durable catalog.
    /// Rows proven durable become completed; every other prepared/failed row is
    /// reset so the next run can safely restage it.
    func reconcileForResume(
        durableOutcomes: [CalibreImportOutcome],
        preservingPreparedItemIDs: Set<Int64> = []
    ) throws {
        let durableByID = Dictionary(
            durableOutcomes.map { ($0.calibreID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for index in manifest.items.indices {
            let id = manifest.items[index].calibreID
            if let outcome = durableByID[id] {
                manifest.items[index].state = .completed
                manifest.items[index].outcome = outcome
                manifest.items[index].lastError = nil
            } else if preservingPreparedItemIDs.contains(id) {
                let message = "Managed files are still waiting for recovery."
                manifest.items[index].state = .prepared
                manifest.items[index].lastError = message
                manifest.items[index].outcome = CalibreImportOutcome(
                    calibreID: id,
                    category: .failed,
                    bookID: nil,
                    message: message
                )
            } else if manifest.items[index].state == .prepared
                        || manifest.items[index].state == .failed {
                resetItem(at: index)
            }
        }
        cancellationRequested = false
        manifest.phase = preservingPreparedItemIDs.isEmpty ? .prepared : .failed
        manifest.updatedAt = .now
        try persist()
    }

    func run(
        chunkSize: Int,
        progressHandler: @escaping ProgressHandler,
        processor: @escaping ChunkProcessor
    ) async -> CalibreImportSummary {
        cancellationRequested = false
        manifest.phase = .running
        manifest.updatedAt = .now
        do {
            try persist()
        } catch {
            markPersistenceFailure(error)
            return makeSummary()
        }
        await progressHandler(progress())

        let boundedChunkSize = max(1, chunkSize)
        while true {
            if cancellationRequested || Task.isCancelled {
                manifest.phase = .cancelled
                manifest.updatedAt = .now
                try? persist()
                await progressHandler(progress())
                return makeSummary()
            }

            let pending = manifest.items.filter { $0.state == .pending }
            guard !pending.isEmpty else {
                if manifest.items.allSatisfy({ $0.state == .completed }) {
                    manifest.phase = .completed
                } else {
                    manifest.phase = .failed
                }
                manifest.updatedAt = .now
                try? persist()
                await progressHandler(progress())
                return makeSummary()
            }

            let result = await processor(Array(pending.prefix(boundedChunkSize)))
            for (calibreID, count) in result.unsafeRejectedSourcesByItem {
                guard let index = manifest.items.firstIndex(where: {
                    $0.calibreID == calibreID
                }) else { continue }
                manifest.items[index].unsafeRejectedSources = max(
                    manifest.items[index].unsafeRejectedSources,
                    count
                )
            }
            apply(result.outcomes)
            for id in result.resetItemIDs {
                guard let index = manifest.items.firstIndex(where: { $0.calibreID == id }),
                      manifest.items[index].state != .completed else { continue }
                resetItem(at: index)
            }

            if let failure = result.failure {
                if let id = failure.calibreID,
                   let index = manifest.items.firstIndex(where: { $0.calibreID == id }),
                   manifest.items[index].state != .completed {
                    if !failure.preservePreparedItems {
                        manifest.items[index].state = .failed
                    }
                    manifest.items[index].lastError = failure.message
                    manifest.items[index].outcome = CalibreImportOutcome(
                        calibreID: id,
                        category: .failed,
                        bookID: nil,
                        message: failure.message
                    )
                }
                manifest.phase = failure.isCancellation ? .cancelled : .failed
                manifest.updatedAt = .now
                try? persist()
                await progressHandler(progress())
                return makeSummary()
            }

            manifest.updatedAt = .now
            do {
                try persist()
            } catch {
                markPersistenceFailure(error)
                await progressHandler(progress())
                return makeSummary()
            }
            await progressHandler(progress())
        }
    }

    private func apply(_ outcomes: [CalibreImportOutcome]) {
        for outcome in outcomes {
            guard let index = manifest.items.firstIndex(where: { $0.calibreID == outcome.calibreID }) else {
                continue
            }
            manifest.items[index].state = .completed
            manifest.items[index].outcome = outcome
            manifest.items[index].lastError = nil
        }
    }

    private func resetItem(at index: Int) {
        manifest.items[index].state = .pending
        manifest.items[index].decision = nil
        manifest.items[index].transactionIDs = []
        manifest.items[index].outcome = nil
        manifest.items[index].lastError = nil
    }

    private func markPersistenceFailure(_ error: Error) {
        manifest.phase = .failed
        if let index = manifest.items.firstIndex(where: { $0.state != .completed }) {
            let message = error.localizedDescription
            manifest.items[index].state = .failed
            manifest.items[index].lastError = message
            manifest.items[index].outcome = CalibreImportOutcome(
                calibreID: manifest.items[index].calibreID,
                category: .failed,
                bookID: nil,
                message: message
            )
        }
    }

    private func makeSummary() -> CalibreImportSummary {
        let outcomes = manifest.items.compactMap(\.outcome)
        let completed = manifest.items.count(where: { $0.state == .completed })
        return CalibreImportSummary(
            sessionID: manifest.id,
            phase: manifest.phase,
            total: manifest.items.count,
            imported: outcomes.count(where: { $0.category == .imported }),
            merged: outcomes.count(where: { $0.category == .merged }),
            skippedExact: outcomes.count(where: { $0.category == .skippedExact }),
            needsReview: outcomes.count(where: { $0.category == .needsReview }),
            failed: outcomes.count(where: { $0.category == .failed }),
            pending: manifest.items.count - completed,
            unsafeRejectedSources: manifest.unsafeRejectedSources
                + manifest.items.reduce(0) { $0 + $1.unsafeRejectedSources }
        )
    }

    private func persist() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }
}
