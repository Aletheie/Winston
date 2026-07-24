import Foundation
import Observation

nonisolated struct CatalogChangeFields: OptionSet, Equatable, Sendable {
    let rawValue: UInt64

    static let identity = CatalogChangeFields(rawValue: 1 << 0)
    static let displayMetadata = CatalogChangeFields(rawValue: 1 << 1)
    static let assetAvailability = CatalogChangeFields(rawValue: 1 << 2)
    static let fullTextSource = CatalogChangeFields(rawValue: 1 << 3)
    static let collectionMembership = CatalogChangeFields(rawValue: 1 << 4)
    static let readingState = CatalogChangeFields(rawValue: 1 << 5)
    static let cover = CatalogChangeFields(rawValue: 1 << 6)
    static let workMembership = CatalogChangeFields(rawValue: 1 << 7)

    static let all: CatalogChangeFields = [
        .identity,
        .displayMetadata,
        .assetAvailability,
        .fullTextSource,
        .collectionMembership,
        .readingState,
        .cover,
        .workMembership,
    ]
}

nonisolated struct LibraryCatalogDelta: Equatable, Sendable {
    let fromRevision: Int
    let toRevision: Int
    let affectedBookIDs: Set<UUID>
    let affectedWorkIDs: Set<UUID>
    let affectedAssetIDs: Set<UUID>
    let affectedCollectionIDs: Set<UUID>
    let fields: CatalogChangeFields
    let requiresFullRebuild: Bool
    let changesBookMembership: Bool

    init(
        fromRevision: Int,
        toRevision: Int,
        affectedBookIDs: Set<UUID>,
        affectedWorkIDs: Set<UUID> = [],
        affectedAssetIDs: Set<UUID> = [],
        affectedCollectionIDs: Set<UUID>,
        fields: CatalogChangeFields = .all,
        requiresFullRebuild: Bool,
        changesBookMembership: Bool
    ) {
        self.fromRevision = fromRevision
        self.toRevision = toRevision
        self.affectedBookIDs = affectedBookIDs
        self.affectedWorkIDs = affectedWorkIDs
        self.affectedAssetIDs = affectedAssetIDs
        self.affectedCollectionIDs = affectedCollectionIDs
        self.fields = fields
        self.requiresFullRebuild = requiresFullRebuild
        self.changesBookMembership = changesBookMembership
    }

    var isEmpty: Bool {
        fromRevision == toRevision
            && affectedBookIDs.isEmpty
            && affectedWorkIDs.isEmpty
            && affectedAssetIDs.isEmpty
            && affectedCollectionIDs.isEmpty
            && fields.isEmpty
            && !requiresFullRebuild
            && !changesBookMembership
    }
}

nonisolated struct FullTextCatalogDelta: Equatable, Sendable {
    let fromRevision: Int
    let toRevision: Int
    let affectedBookIDs: Set<UUID>
    let requiresFullRebuild: Bool

    var isEmpty: Bool {
        fromRevision == toRevision
            && affectedBookIDs.isEmpty
            && !requiresFullRebuild
    }
}

private nonisolated struct LibraryCatalogChange: Sendable {
    let revision: Int
    let affectedBookIDs: Set<UUID>?
    let affectedWorkIDs: Set<UUID>
    let affectedAssetIDs: Set<UUID>
    let affectedCollectionIDs: Set<UUID>
    let fields: CatalogChangeFields
    let changesBookMembership: Bool
}

private nonisolated struct FullTextCatalogChange: Sendable {
    let revision: Int
    let affectedBookIDs: Set<UUID>?
}

@MainActor
@Observable
// Write-driven invalidation tokens. Persistence observers can follow every save, while
// library UI follows only catalog-affecting writes and avoids rebuilding for notices/wishlist.
final class LibraryMutationLog {
    static let shared = LibraryMutationLog()

    private(set) var revision = 0
    private(set) var catalogRevision = 0
    private(set) var fullTextRevision = 0
    @ObservationIgnored private var catalogChanges: [LibraryCatalogChange] = []
    @ObservationIgnored private var fullTextChanges: [FullTextCatalogChange] = []

    func bump(
        catalogChanged: Bool = true,
        affectedBookIDs: Set<UUID>? = nil,
        affectedWorkIDs: Set<UUID> = [],
        affectedAssetIDs: Set<UUID> = [],
        affectedCollectionIDs: Set<UUID> = [],
        fields: CatalogChangeFields = .all,
        changesBookMembership: Bool = false,
        fullTextAffectedBookIDs: Set<UUID>? = []
    ) {
        revision &+= 1
        guard catalogChanged else { return }

        catalogRevision &+= 1
        catalogChanges.append(
            LibraryCatalogChange(
                revision: catalogRevision,
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs,
                affectedAssetIDs: affectedAssetIDs,
                affectedCollectionIDs: affectedCollectionIDs,
                fields: fields,
                changesBookMembership: changesBookMembership
            )
        )
        if catalogChanges.count > 256 {
            catalogChanges.removeFirst(catalogChanges.count - 256)
        }

        if fullTextAffectedBookIDs == nil || fullTextAffectedBookIDs?.isEmpty == false {
            fullTextRevision &+= 1
            fullTextChanges.append(
                FullTextCatalogChange(
                    revision: fullTextRevision,
                    affectedBookIDs: fullTextAffectedBookIDs
                )
            )
            if fullTextChanges.count > 256 {
                fullTextChanges.removeFirst(fullTextChanges.count - 256)
            }
        }
    }

    func catalogDelta(since revision: Int) -> LibraryCatalogDelta {
        guard revision >= 0, revision <= catalogRevision else {
            return fullDelta(since: revision)
        }
        guard revision != catalogRevision else {
            return LibraryCatalogDelta(
                fromRevision: revision,
                toRevision: catalogRevision,
                affectedBookIDs: [],
                affectedWorkIDs: [],
                affectedAssetIDs: [],
                affectedCollectionIDs: [],
                fields: [],
                requiresFullRebuild: false,
                changesBookMembership: false
            )
        }

        let changes = catalogChanges.filter { $0.revision > revision }
        guard changes.first?.revision == revision + 1,
              changes.last?.revision == catalogRevision else {
            return fullDelta(since: revision)
        }

        var affectedBookIDs: Set<UUID> = []
        var affectedWorkIDs: Set<UUID> = []
        var affectedAssetIDs: Set<UUID> = []
        var affectedCollectionIDs: Set<UUID> = []
        var fields: CatalogChangeFields = []
        var requiresFullRebuild = false
        var changesBookMembership = false
        for change in changes {
            if let ids = change.affectedBookIDs {
                affectedBookIDs.formUnion(ids)
            } else {
                requiresFullRebuild = true
            }
            affectedWorkIDs.formUnion(change.affectedWorkIDs)
            affectedAssetIDs.formUnion(change.affectedAssetIDs)
            affectedCollectionIDs.formUnion(change.affectedCollectionIDs)
            fields.formUnion(change.fields)
            changesBookMembership = changesBookMembership || change.changesBookMembership
        }
        return LibraryCatalogDelta(
            fromRevision: revision,
            toRevision: catalogRevision,
            affectedBookIDs: affectedBookIDs,
            affectedWorkIDs: affectedWorkIDs,
            affectedAssetIDs: affectedAssetIDs,
            affectedCollectionIDs: affectedCollectionIDs,
            fields: fields,
            requiresFullRebuild: requiresFullRebuild,
            changesBookMembership: changesBookMembership
        )
    }

    func fullTextDelta(since revision: Int) -> FullTextCatalogDelta {
        guard revision >= 0, revision <= fullTextRevision else {
            return fullTextFullDelta(since: revision)
        }
        guard revision != fullTextRevision else {
            return FullTextCatalogDelta(
                fromRevision: revision,
                toRevision: fullTextRevision,
                affectedBookIDs: [],
                requiresFullRebuild: false
            )
        }

        let changes = fullTextChanges.filter { $0.revision > revision }
        guard changes.first?.revision == revision + 1,
              changes.last?.revision == fullTextRevision else {
            return fullTextFullDelta(since: revision)
        }

        var affectedBookIDs: Set<UUID> = []
        var requiresFullRebuild = false
        for change in changes {
            if let ids = change.affectedBookIDs {
                affectedBookIDs.formUnion(ids)
            } else {
                requiresFullRebuild = true
            }
        }
        return FullTextCatalogDelta(
            fromRevision: revision,
            toRevision: fullTextRevision,
            affectedBookIDs: affectedBookIDs,
            requiresFullRebuild: requiresFullRebuild
        )
    }

    private func fullDelta(since revision: Int) -> LibraryCatalogDelta {
        LibraryCatalogDelta(
            fromRevision: revision,
            toRevision: catalogRevision,
            affectedBookIDs: [],
            affectedWorkIDs: [],
            affectedAssetIDs: [],
            affectedCollectionIDs: [],
            fields: .all,
            requiresFullRebuild: true,
            changesBookMembership: true
        )
    }

    private func fullTextFullDelta(since revision: Int) -> FullTextCatalogDelta {
        FullTextCatalogDelta(
            fromRevision: revision,
            toRevision: fullTextRevision,
            affectedBookIDs: [],
            requiresFullRebuild: true
        )
    }
}
