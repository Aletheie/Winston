import Foundation
import Observation

nonisolated struct LibraryCatalogDelta: Equatable, Sendable {
    let fromRevision: Int
    let toRevision: Int
    let affectedBookIDs: Set<UUID>
    let affectedCollectionIDs: Set<UUID>
    let requiresFullRebuild: Bool
    let changesBookMembership: Bool

    var isEmpty: Bool {
        fromRevision == toRevision
            && affectedBookIDs.isEmpty
            && affectedCollectionIDs.isEmpty
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
    let affectedCollectionIDs: Set<UUID>
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
        affectedCollectionIDs: Set<UUID> = [],
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
                affectedCollectionIDs: affectedCollectionIDs,
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
                affectedCollectionIDs: [],
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
        var affectedCollectionIDs: Set<UUID> = []
        var requiresFullRebuild = false
        var changesBookMembership = false
        for change in changes {
            if let ids = change.affectedBookIDs {
                affectedBookIDs.formUnion(ids)
            } else {
                requiresFullRebuild = true
            }
            affectedCollectionIDs.formUnion(change.affectedCollectionIDs)
            changesBookMembership = changesBookMembership || change.changesBookMembership
        }
        return LibraryCatalogDelta(
            fromRevision: revision,
            toRevision: catalogRevision,
            affectedBookIDs: affectedBookIDs,
            affectedCollectionIDs: affectedCollectionIDs,
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
            affectedCollectionIDs: [],
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
