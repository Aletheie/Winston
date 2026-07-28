import AppKit
import Foundation
import SwiftData

nonisolated enum CoverMutationPriority: Equatable, Sendable {
    case background
    case user
    case system
}

nonisolated struct CoverMutationLease: Sendable, Equatable {
    fileprivate let operationID: UUID
    fileprivate let generationsByBookID: [UUID: UInt64]
    fileprivate let priority: CoverMutationPriority
}

nonisolated struct PreparedCoverMutation: Sendable {
    let transaction: ManagedFileTransaction
    let targetReference: CoverReference
    let selectedBookIDs: Set<UUID>
    let expectedBookReferences: [UUID: CoverReference]

    fileprivate let lease: CoverMutationLease
    fileprivate let targetMayBeCreated: Bool
    fileprivate let payload: Data?
}

@MainActor
final class CoverMutationCoordinator {
    private struct BookCoverPreimage {
        let book: Book
        let version: Int
        let scopeRaw: String?
        let assetID: UUID?

        init(_ book: Book) {
            self.book = book
            version = book.coverVersion
            scopeRaw = book.coverScopeRaw
            assetID = book.coverAssetUUID
        }

        func restore() {
            guard book.modelContext != nil else { return }
            book.coverVersion = version
            book.coverScopeRaw = scopeRaw
            book.coverAssetUUID = assetID
        }
    }

    private struct CatalogPreimage {
        let books: [BookCoverPreimage]
        let work: (model: Work, version: Int)?
        let asset: (model: BookAsset, version: Int)?

        func restore() {
            books.forEach { $0.restore() }
            if let work, work.model.modelContext != nil {
                work.model.coverVersion = work.version
            }
            if let asset, asset.model.modelContext != nil {
                asset.model.coverVersion = asset.version
            }
        }
    }

    private let mutations: CatalogMutationService
    private let managedFiles: ManagedFileCoordinator
    private var generationsByBookID: [UUID: UInt64] = [:]
    private var activeUserOperationByBookID: [UUID: UUID] = [:]
    /// Process-local high-water mark. Durable journals are folded into the
    /// allocation below so a restart cannot reuse a still-recoverable epoch.
    private var allocatedVersionsByOwner: [CoverOwner: Int] = [:]

    init(
        mutations: CatalogMutationService,
        managedFiles: ManagedFileCoordinator
    ) {
        self.mutations = mutations
        self.managedFiles = managedFiles
    }

    static func resolve(
        modelContext: ModelContext,
        mutations: CatalogMutationService,
        managedFiles: ManagedFileCoordinator
    ) -> CoverMutationCoordinator {
        CoverMutationCoordinatorRegistry.resolve(
            modelContext: modelContext,
            mutations: mutations,
            managedFiles: managedFiles
        )
    }

    func prepare(
        payload: Data?,
        targetReference: CoverReference,
        selectedBookIDs: Set<UUID>,
        expectedBookReferences: [UUID: CoverReference],
        priority: CoverMutationPriority,
        intent: ManagedFileIntent = .coverUpdate,
        operationID: UUID = UUID(),
        targetMayBeCreated: Bool = false
    ) async throws -> PreparedCoverMutation {
        guard targetReference.version >= 0,
              targetReference.version < Int.max,
              !selectedBookIDs.isEmpty,
              Set(expectedBookReferences.keys).isSubset(of: selectedBookIDs) else {
            throw CatalogMutationError.invalidRequest
        }
        let lease = try beginLease(
            operationID: operationID,
            bookIDs: selectedBookIDs,
            priority: priority
        )
        do {
            try validateExpectedReferences(
                expectedBookReferences,
                selectedBookIDs: selectedBookIDs,
                allowingMissingBooks: targetMayBeCreated
            )
            try validateTargetOwner(
                targetReference.owner,
                selectedBookIDs: selectedBookIDs,
                allowingMissingOwner: targetMayBeCreated
            )
            let pendingTransactions = await managedFiles.pendingTransactions()
            try validateLeaseAndExpectedReferences(
                lease,
                expectedBookReferences: expectedBookReferences,
                selectedBookIDs: selectedBookIDs,
                allowingMissingBooks: targetMayBeCreated
            )
            let allocatedReference = try allocateReference(
                requested: targetReference,
                pendingTransactions: pendingTransactions,
                allowingMissingOwner: targetMayBeCreated
            )
            let identity = try await managedFiles.captureIdentity(
                of: .cover(owner: allocatedReference.owner)
            )
            try validateLeaseAndExpectedReferences(
                lease,
                expectedBookReferences: expectedBookReferences,
                selectedBookIDs: selectedBookIDs,
                allowingMissingBooks: targetMayBeCreated
            )
            let requirement = ManagedFileRequirement(
                presentBookIDs: selectedBookIDs,
                coverRequirements: [
                    ManagedCoverRequirement(
                        owner: allocatedReference.owner,
                        version: allocatedReference.version,
                        selectedBookIDs: selectedBookIDs
                    ),
                ]
            )
            let transaction: ManagedFileTransaction
            if let payload {
                transaction = try await managedFiles.stage(
                    intent: intent,
                    sources: [
                        .cover(
                            data: payload,
                            owner: allocatedReference.owner,
                            replacing: identity
                        ),
                    ],
                    requirement: requirement,
                    operationID: operationID
                )
            } else {
                transaction = try await managedFiles.prepareCleanup(
                    intent: intent,
                    requirement: requirement,
                    cleanups: [.file(identity)],
                    operationID: operationID
                )
            }
            do {
                try validateLeaseAndExpectedReferences(
                    lease,
                    expectedBookReferences: expectedBookReferences,
                    selectedBookIDs: selectedBookIDs,
                    allowingMissingBooks: targetMayBeCreated
                )
            } catch {
                await managedFiles.abort(transaction)
                throw error
            }
            return PreparedCoverMutation(
                transaction: transaction,
                targetReference: allocatedReference,
                selectedBookIDs: selectedBookIDs,
                expectedBookReferences: expectedBookReferences,
                lease: lease,
                targetMayBeCreated: targetMayBeCreated,
                payload: payload
            )
        } catch {
            finish(lease)
            throw error
        }
    }

    private func allocateReference(
        requested: CoverReference,
        pendingTransactions: [ManagedFileTransaction],
        allowingMissingOwner: Bool
    ) throws -> CoverReference {
        let currentVersion: Int
        do {
            currentVersion = try catalogVersion(for: requested.owner)
        } catch CatalogMutationError.modelNotFound where allowingMissingOwner {
            currentVersion = -1
        }
        let pendingVersion = pendingTransactions.lazy
            .flatMap { $0.requirement.coverRequirements ?? [] }
            .filter { $0.owner == requested.owner }
            .map(\.version)
            .max() ?? -1
        let allocatedVersion = allocatedVersionsByOwner[requested.owner] ?? -1
        let highWater = max(currentVersion, max(pendingVersion, allocatedVersion))
        guard highWater < Int.max else {
            throw CatalogMutationError.invalidRequest
        }
        let version = max(requested.version, highWater + 1)
        allocatedVersionsByOwner[requested.owner] = version
        return CoverReference(owner: requested.owner, version: version)
    }

    private func catalogVersion(for owner: CoverOwner) throws -> Int {
        switch owner {
        case .edition(let bookID):
            return try mutations.book(id: bookID).coverVersion
        case .work(let workID):
            return try mutations.work(id: workID).coverVersion
        case .generatedAsset(let assetID):
            guard let asset = try mutations.assets(ids: [assetID]).first else {
                throw CatalogMutationError.modelNotFound
            }
            return asset.coverVersion
        }
    }

    func abort(_ prepared: PreparedCoverMutation) async {
        await managedFiles.abort(prepared.transaction)
        finish(prepared.lease)
    }

    func invalidate(_ owners: Set<CoverOwner>) async {
        for owner in owners {
            await CoverCache.shared.invalidate(for: CoverStore.url(for: owner))
        }
    }

    func commit(
        _ prepared: PreparedCoverMutation,
        command: CatalogMutationCommand,
        additionalTransactions: [ManagedFileTransaction] = [],
        affectedBookIDs: Set<UUID> = [],
        affectedWorkIDs: Set<UUID> = [],
        affectedAssetIDs: Set<UUID>? = nil,
        affectedCollectionIDs: Set<UUID> = [],
        catalogChanged: Bool = true,
        revertingOnFailure rollbackMutation: () -> Void = {},
        applying mutation: () throws -> Void
    ) async throws -> CatalogFileCommitResult {
        return try await commit(
            [prepared],
            command: command,
            additionalTransactions: additionalTransactions,
            affectedBookIDs: affectedBookIDs,
            affectedWorkIDs: affectedWorkIDs,
            affectedAssetIDs: affectedAssetIDs,
            affectedCollectionIDs: affectedCollectionIDs,
            catalogChanged: catalogChanged,
            revertingOnFailure: rollbackMutation,
            applying: mutation
        )
    }

    /// Commits disjoint cover operations with one catalog save. Bulk imports
    /// use this to preserve their all-or-nothing catalog boundary without
    /// bypassing cover leases, epochs, or durable owner requirements.
    func commit(
        _ preparedMutations: [PreparedCoverMutation],
        command: CatalogMutationCommand,
        additionalTransactions: [ManagedFileTransaction] = [],
        affectedBookIDs: Set<UUID> = [],
        affectedWorkIDs: Set<UUID> = [],
        affectedAssetIDs: Set<UUID>? = nil,
        affectedCollectionIDs: Set<UUID> = [],
        catalogChanged: Bool = true,
        revertingOnFailure rollbackMutation: () -> Void = {},
        applying mutation: () throws -> Void
    ) async throws -> CatalogFileCommitResult {
        if preparedMutations.isEmpty {
            return try await mutations.commitStagedFiles(
                command,
                transactions: additionalTransactions,
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs,
                affectedAssetIDs: affectedAssetIDs ?? [],
                affectedCollectionIDs: affectedCollectionIDs,
                catalogChanged: catalogChanged,
                revertingOnFailure: rollbackMutation,
                applying: mutation
            )
        }
        var claimedBookIDs: Set<UUID> = []
        for prepared in preparedMutations {
            guard claimedBookIDs.isDisjoint(with: prepared.selectedBookIDs) else {
                for mutation in preparedMutations {
                    await managedFiles.abort(mutation.transaction)
                    finish(mutation.lease)
                }
                throw CatalogMutationError.invalidRequest
            }
            claimedBookIDs.formUnion(prepared.selectedBookIDs)
        }
        defer { preparedMutations.forEach { finish($0.lease) } }

        var coverPreimages: [CatalogPreimage] = []
        var resolvedWorkIDs = affectedWorkIDs
        var resolvedAssetIDs = affectedAssetIDs ?? []
        for prepared in preparedMutations {
            switch prepared.targetReference.owner {
            case .work(let id):
                resolvedWorkIDs.insert(id)
            case .generatedAsset(let id):
                resolvedAssetIDs.insert(id)
            case .edition:
                break
            }
        }
        let allAffectedBookIDs = affectedBookIDs.union(claimedBookIDs)
        let result = try await mutations.commitStagedFiles(
            command,
            transactions: preparedMutations.map(\.transaction) + additionalTransactions,
            affectedBookIDs: allAffectedBookIDs,
            affectedWorkIDs: resolvedWorkIDs,
            affectedAssetIDs: resolvedAssetIDs,
            affectedCollectionIDs: affectedCollectionIDs,
            catalogChanged: catalogChanged,
            revertingOnFailure: {
                rollbackMutation()
                coverPreimages.reversed().forEach { $0.restore() }
            }
        ) {
            for prepared in preparedMutations {
                try self.validateLeaseAndExpectedReferences(
                    prepared.lease,
                    expectedBookReferences: prepared.expectedBookReferences,
                    selectedBookIDs: prepared.selectedBookIDs,
                    allowingMissingBooks: prepared.targetMayBeCreated
                )
                coverPreimages.append(
                    try self.captureCatalogPreimage(for: prepared)
                )
            }
            try mutation()
            for prepared in preparedMutations {
                try self.applyTargetReference(
                    prepared.targetReference,
                    to: prepared.selectedBookIDs
                )
            }
        }

        let targetOwners = Set(preparedMutations.map(\.targetReference.owner))
        let priorOwners = Set(
            preparedMutations.flatMap {
                $0.expectedBookReferences.values.map(\.owner)
            }
        ).subtracting(targetOwners)
        await invalidate(priorOwners)
        for prepared in preparedMutations {
            let targetURL = CoverStore.url(for: prepared.targetReference.owner)
            if result.isFullyPublished {
                await CoverCache.shared.replace(
                    prepared.payload.flatMap(NSImage.init(data:)),
                    for: targetURL
                )
            } else {
                await CoverCache.shared.invalidate(for: targetURL)
            }
        }
        return result
    }

    private func beginLease(
        operationID: UUID,
        bookIDs: Set<UUID>,
        priority: CoverMutationPriority
    ) throws -> CoverMutationLease {
        if priority == .background,
           bookIDs.contains(where: { activeUserOperationByBookID[$0] != nil }) {
            throw CatalogMutationError.staleGeneration
        }

        var generations: [UUID: UInt64] = [:]
        for bookID in bookIDs {
            if priority != .background {
                generationsByBookID[bookID, default: 0] &+= 1
                activeUserOperationByBookID[bookID] = operationID
            }
            generations[bookID] = generationsByBookID[bookID, default: 0]
        }
        return CoverMutationLease(
            operationID: operationID,
            generationsByBookID: generations,
            priority: priority
        )
    }

    private func finish(_ lease: CoverMutationLease) {
        guard lease.priority != .background else { return }
        for bookID in lease.generationsByBookID.keys
        where activeUserOperationByBookID[bookID] == lease.operationID {
            activeUserOperationByBookID.removeValue(forKey: bookID)
        }
    }

    private func validateLeaseAndExpectedReferences(
        _ lease: CoverMutationLease,
        expectedBookReferences: [UUID: CoverReference],
        selectedBookIDs: Set<UUID>,
        allowingMissingBooks: Bool
    ) throws {
        guard lease.generationsByBookID.allSatisfy({
            generationsByBookID[$0.key, default: 0] == $0.value
        }) else {
            throw CatalogMutationError.staleGeneration
        }
        if lease.priority != .background {
            guard lease.generationsByBookID.keys.allSatisfy({
                activeUserOperationByBookID[$0] == lease.operationID
            }) else {
                throw CatalogMutationError.staleGeneration
            }
        }
        try validateExpectedReferences(
            expectedBookReferences,
            selectedBookIDs: selectedBookIDs,
            allowingMissingBooks: allowingMissingBooks
        )
    }

    private func validateExpectedReferences(
        _ expected: [UUID: CoverReference],
        selectedBookIDs: Set<UUID>,
        allowingMissingBooks: Bool
    ) throws {
        for bookID in selectedBookIDs {
            do {
                let book = try mutations.book(id: bookID)
                guard expected[bookID] == book.coverReference else {
                    throw CatalogMutationError.staleGeneration
                }
            } catch CatalogMutationError.modelNotFound where allowingMissingBooks
                        && expected[bookID] == nil {
                continue
            }
        }
    }

    private func validateTargetOwner(
        _ owner: CoverOwner,
        selectedBookIDs: Set<UUID>,
        allowingMissingOwner: Bool
    ) throws {
        do {
            switch owner {
            case .edition(let bookID):
                guard selectedBookIDs == Set([bookID]) else {
                    throw CatalogMutationError.invalidRequest
                }
                _ = try mutations.book(id: bookID)
            case .work(let workID):
                _ = try mutations.work(id: workID)
            case .generatedAsset(let assetID):
                guard let asset = try mutations.assets(ids: [assetID]).first else {
                    throw CatalogMutationError.modelNotFound
                }
                guard let bookID = asset.book?.uuid,
                      selectedBookIDs == Set([bookID]) else {
                    throw CatalogMutationError.invalidRequest
                }
            }
        } catch CatalogMutationError.modelNotFound where allowingMissingOwner {
            return
        }
    }

    private func captureCatalogPreimage(
        for prepared: PreparedCoverMutation
    ) throws -> CatalogPreimage {
        var books: [BookCoverPreimage] = []
        for bookID in prepared.selectedBookIDs {
            do {
                books.append(BookCoverPreimage(try mutations.book(id: bookID)))
            } catch CatalogMutationError.modelNotFound where prepared.targetMayBeCreated {
                continue
            }
        }
        let work: (model: Work, version: Int)?
        let asset: (model: BookAsset, version: Int)?
        switch prepared.targetReference.owner {
        case .work(let id):
            do {
                let model = try mutations.work(id: id)
                work = (model, model.coverVersion)
            } catch CatalogMutationError.modelNotFound where prepared.targetMayBeCreated {
                work = nil
            }
            asset = nil
        case .generatedAsset(let id):
            do {
                guard let model = try mutations.assets(ids: [id]).first else {
                    throw CatalogMutationError.modelNotFound
                }
                asset = (model, model.coverVersion)
            } catch CatalogMutationError.modelNotFound where prepared.targetMayBeCreated {
                asset = nil
            }
            work = nil
        case .edition:
            work = nil
            asset = nil
        }
        if !prepared.targetMayBeCreated {
            guard books.count == prepared.selectedBookIDs.count else {
                throw CatalogMutationError.modelNotFound
            }
            switch prepared.targetReference.owner {
            case .work where work == nil, .generatedAsset where asset == nil:
                throw CatalogMutationError.modelNotFound
            case .edition, .work, .generatedAsset:
                break
            }
        }
        return CatalogPreimage(books: books, work: work, asset: asset)
    }

    private func applyTargetReference(
        _ reference: CoverReference,
        to selectedBookIDs: Set<UUID>
    ) throws {
        let books = try mutations.books(ids: selectedBookIDs)
        switch reference.owner {
        case .edition(let bookID):
            guard selectedBookIDs == Set([bookID]),
                  let book = books.first else {
                throw CatalogMutationError.invalidRequest
            }
            book.coverVersion = reference.version
            guard book.selectCoverOwner(reference.owner) else {
                throw CatalogMutationError.invalidRequest
            }
        case .work(let workID):
            let work = try mutations.work(id: workID)
            work.coverVersion = reference.version
            for book in books {
                guard book.selectCoverOwner(reference.owner) else {
                    throw CatalogMutationError.invalidRequest
                }
            }
        case .generatedAsset(let assetID):
            guard let asset = try mutations.assets(ids: [assetID]).first else {
                throw CatalogMutationError.modelNotFound
            }
            asset.coverVersion = reference.version
            for book in books {
                guard book.selectCoverOwner(reference.owner) else {
                    throw CatalogMutationError.invalidRequest
                }
            }
        }
        guard books.allSatisfy({ $0.coverReference == reference }) else {
            throw CatalogMutationError.invalidRequest
        }
    }
}

@MainActor
private final class CoverMutationCoordinatorRegistryEntry {
    weak var container: ModelContainer?
    weak var coordinator: CoverMutationCoordinator?

    init(container: ModelContainer, coordinator: CoverMutationCoordinator) {
        self.container = container
        self.coordinator = coordinator
    }
}

@MainActor
private enum CoverMutationCoordinatorRegistry {
    private struct Key: Hashable {
        let container: ObjectIdentifier
        let writeOwner: ObjectIdentifier
        let managedFiles: ObjectIdentifier
    }

    private static var entries: [Key: CoverMutationCoordinatorRegistryEntry] = [:]

    static func resolve(
        modelContext: ModelContext,
        mutations: CatalogMutationService,
        managedFiles: ManagedFileCoordinator
    ) -> CoverMutationCoordinator {
        let container = modelContext.container
        let key = Key(
            container: ObjectIdentifier(container),
            writeOwner: mutations.storeWriteOwnerIdentifier,
            managedFiles: ObjectIdentifier(managedFiles)
        )
        if let entry = entries[key],
           entry.container === container,
           let coordinator = entry.coordinator {
            return coordinator
        }

        entries = entries.filter {
            $0.value.container != nil && $0.value.coordinator != nil
        }
        let coordinator = CoverMutationCoordinator(
            mutations: mutations,
            managedFiles: managedFiles
        )
        entries[key] = CoverMutationCoordinatorRegistryEntry(
            container: container,
            coordinator: coordinator
        )
        return coordinator
    }
}
