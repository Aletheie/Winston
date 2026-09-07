import Foundation
import Observation
import SwiftData

nonisolated enum HighlightsWorkspaceMode: String, CaseIterable, Identifiable, Sendable {
    case library
    case review

    var id: Self { self }

    var label: LocalizedStringResource {
        switch self {
        case .library: "Library"
        case .review: "Review"
        }
    }
}

nonisolated enum HighlightQuickFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case favorites
    case reflections

    var id: Self { self }

    var label: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .reflections: "Reflections"
        }
    }
}

nonisolated struct HighlightFilterRequest: Hashable, Sendable {
    let query: String
    let quickFilter: HighlightQuickFilter
    let bookID: UUID?
    let tag: String?
    let sourceGeneration: Int
}

nonisolated struct HighlightBookFilterOption: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let author: String?
}

nonisolated struct HighlightBookGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let author: String?
    var items: [HighlightWorkspaceItem]
}

nonisolated enum HighlightWorkspaceFilter {
    static func apply(
        to items: [HighlightWorkspaceItem],
        request: HighlightFilterRequest
    ) -> [HighlightWorkspaceItem] {
        let query = MetadataNormalizer.searchKey(request.query)
        let tagKey = request.tag.map(MetadataNormalizer.tagComparisonKey)
        return items.filter { item in
            let quickFilterMatches = switch request.quickFilter {
            case .all: true
            case .favorites: item.isFavorite
            case .reflections: item.hasReflection
            }
            guard quickFilterMatches else { return false }
            if let bookID = request.bookID, item.bookID != bookID { return false }
            if let tagKey,
               !item.tags.contains(where: {
                   MetadataNormalizer.tagComparisonKey($0) == tagKey
               }) {
                return false
            }
            return query.isEmpty || item.searchableText.contains(query)
        }
    }

    @concurrent
    static func applyConcurrently(
        to items: [HighlightWorkspaceItem],
        request: HighlightFilterRequest
    ) async -> [HighlightWorkspaceItem] {
        apply(to: items, request: request)
    }

    static func groups(
        from items: [HighlightWorkspaceItem]
    ) -> [HighlightBookGroup] {
        var groups: [HighlightBookGroup] = []
        var groupIndexByBookID: [UUID: Int] = [:]
        for item in items {
            if let index = groupIndexByBookID[item.bookID] {
                groups[index].items.append(item)
            } else {
                groupIndexByBookID[item.bookID] = groups.count
                groups.append(HighlightBookGroup(
                    id: item.bookID,
                    title: item.bookTitle,
                    author: item.bookAuthor,
                    items: [item]
                ))
            }
        }
        return groups
    }
}

nonisolated enum HighlightReviewPlanner {
    static let defaultSessionSize = 5

    static func makeSession(
        from items: [HighlightWorkspaceItem],
        excluding excludedIDs: Set<PersistentIdentifier> = [],
        limit: Int = defaultSessionSize
    ) -> [HighlightWorkspaceItem] {
        guard limit > 0 else { return [] }
        return items.enumerated()
            .filter { !excludedIDs.contains($0.element.id) }
            .sorted { lhs, rhs in
                switch (lhs.element.lastReviewedAt, rhs.element.lastReviewedAt) {
                case (nil, nil):
                    return lhs.offset < rhs.offset
                case (nil, _):
                    return true
                case (_, nil):
                    return false
                case (let lhsDate?, let rhsDate?):
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                    return lhs.offset < rhs.offset
                }
            }
            .prefix(limit)
            .map(\.element)
    }
}

@MainActor
@Observable
final class HighlightsWorkspaceModel {
    private struct Draft: Equatable {
        var favorite: Bool
        var tags: [String]
        var reflection: String?
    }

    var mode: HighlightsWorkspaceMode = .library
    var searchText = ""
    var quickFilter: HighlightQuickFilter = .all
    var selectedBookID: UUID?
    var selectedTag: String?

    private(set) var allItems: [HighlightWorkspaceItem] = []
    private(set) var visibleItems: [HighlightWorkspaceItem] = []
    private(set) var visibleGroups: [HighlightBookGroup] = []
    private(set) var bookOptions: [HighlightBookFilterOption] = []
    private(set) var tagOptions: [String] = []
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var sourceGeneration = 0

    private(set) var selectedHighlightID: PersistentIdentifier?
    var draftFavorite = false
    var draftTagsText = ""
    var draftReflection = ""
    private var draftBaseline: Draft?

    private(set) var reviewItems: [HighlightWorkspaceItem] = []
    private(set) var reviewIndex = 0
    private(set) var reviewCompleted = false
    private(set) var reviewedInLastSession = 0
    private var usedReviewIDs: Set<PersistentIdentifier> = []
    private var reviewedSessionIDs: Set<PersistentIdentifier> = []

    var filterRequest: HighlightFilterRequest {
        HighlightFilterRequest(
            query: searchText,
            quickFilter: quickFilter,
            bookID: selectedBookID,
            tag: selectedTag,
            sourceGeneration: sourceGeneration
        )
    }

    var totalCount: Int { allItems.count }
    var visibleCount: Int { visibleItems.count }

    var selectedItem: HighlightWorkspaceItem? {
        guard let selectedHighlightID else { return nil }
        return allItems.first { $0.id == selectedHighlightID }
    }

    var currentReviewItem: HighlightWorkspaceItem? {
        guard reviewItems.indices.contains(reviewIndex) else { return nil }
        return reviewItems[reviewIndex]
    }

    var hasUnsavedChanges: Bool {
        guard let draftBaseline else { return false }
        return currentDraft != draftBaseline
    }

    var canMoveBackInReview: Bool {
        !reviewCompleted && reviewIndex > 0
    }

    var reviewProgress: (current: Int, total: Int) {
        guard !reviewItems.isEmpty else { return (0, 0) }
        return (min(reviewIndex + 1, reviewItems.count), reviewItems.count)
    }

    func reload(using service: HighlightsService) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let items = try service.workspaceItems()
            allItems = items
            loadError = nil
            sourceGeneration &+= 1
            rebuildFacets()
            reconcileDraftAfterReload()
            await applyFilter(filterRequest)
        } catch {
            loadError = error.localizedDescription
            if allItems.isEmpty {
                visibleItems = []
                visibleGroups = []
            }
        }
    }

    func applyFilter(_ request: HighlightFilterRequest) async {
        if !request.query.isEmpty {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
        }
        let items = allItems
        let filtered = await HighlightWorkspaceFilter.applyConcurrently(
            to: items,
            request: request
        )
        guard !Task.isCancelled, request == filterRequest else { return }
        visibleItems = filtered
        visibleGroups = HighlightWorkspaceFilter.groups(from: filtered)
        if selectedHighlightID == nil, let first = filtered.first {
            select(first.id)
        }
    }

    func select(_ id: PersistentIdentifier) {
        guard let item = allItems.first(where: { $0.id == id }) else { return }
        selectedHighlightID = id
        loadDraft(from: item)
    }

    func discardDraft() {
        guard let item = selectedItem else {
            clearDraft()
            return
        }
        loadDraft(from: item)
    }

    func patchForDraft(reviewedAt: Date? = nil) -> HighlightPatch {
        var fields: HighlightPatchFields = [.favorite, .tags, .reflection]
        if reviewedAt != nil { fields.insert(.lastReviewedAt) }
        return HighlightPatch(
            fields: fields,
            favorite: draftFavorite,
            tags: HighlightTagNormalizer.normalize(draftTagsText),
            reflection: normalizedReflection(draftReflection),
            lastReviewedAt: reviewedAt
        )
    }

    func acceptSavedItem(_ item: HighlightWorkspaceItem) {
        replace(item)
        selectedHighlightID = item.id
        loadDraft(from: item)
        rebuildAfterLocalMutation()
    }

    func acceptFavoriteUpdate(_ item: HighlightWorkspaceItem) {
        replace(item)
        if let index = reviewItems.firstIndex(where: { $0.id == item.id }) {
            reviewItems[index] = item
        }
        if selectedHighlightID == item.id {
            draftFavorite = item.isFavorite
            draftBaseline?.favorite = item.isFavorite
        }
        rebuildAfterLocalMutation()
    }

    func enterLibrary() {
        mode = .library
        reviewCompleted = false
        if let selectedHighlightID,
           allItems.contains(where: { $0.id == selectedHighlightID }) {
            return
        }
        if let first = visibleItems.first { select(first.id) }
    }

    func startReview() {
        mode = .review
        reviewCompleted = false
        reviewedInLastSession = 0
        reviewedSessionIDs.removeAll()
        let currentPool = HighlightWorkspaceFilter.apply(
            to: allItems,
            request: filterRequest
        )
        var session = HighlightReviewPlanner.makeSession(
            from: currentPool,
            excluding: usedReviewIDs
        )
        if session.isEmpty, !currentPool.isEmpty {
            usedReviewIDs.removeAll()
            session = HighlightReviewPlanner.makeSession(from: currentPool)
        }
        reviewItems = session
        reviewIndex = 0
        if let first = session.first { select(first.id) } else { clearDraft() }
    }

    func moveBackInReview() {
        guard canMoveBackInReview else { return }
        reviewIndex -= 1
        select(reviewItems[reviewIndex].id)
    }

    func acceptReviewedItem(_ item: HighlightWorkspaceItem) {
        replace(item)
        if let index = reviewItems.firstIndex(where: { $0.id == item.id }) {
            reviewItems[index] = item
        }
        usedReviewIDs.insert(item.id)
        reviewedSessionIDs.insert(item.id)
        reviewedInLastSession = reviewedSessionIDs.count
        rebuildAfterLocalMutation()

        if reviewIndex + 1 < reviewItems.count {
            reviewIndex += 1
            select(reviewItems[reviewIndex].id)
        } else {
            reviewCompleted = true
            clearDraft()
        }
    }

    private var currentDraft: Draft {
        Draft(
            favorite: draftFavorite,
            tags: HighlightTagNormalizer.normalize(draftTagsText),
            reflection: normalizedReflection(draftReflection)
        )
    }

    private func loadDraft(from item: HighlightWorkspaceItem) {
        let draft = Draft(
            favorite: item.isFavorite,
            tags: item.tags,
            reflection: normalizedReflection(item.reflection ?? "")
        )
        draftFavorite = draft.favorite
        draftTagsText = draft.tags.joined(separator: ", ")
        draftReflection = draft.reflection ?? ""
        draftBaseline = draft
    }

    private func clearDraft() {
        selectedHighlightID = nil
        draftFavorite = false
        draftTagsText = ""
        draftReflection = ""
        draftBaseline = nil
    }

    private func normalizedReflection(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : value
    }

    private func replace(_ item: HighlightWorkspaceItem) {
        if let index = allItems.firstIndex(where: { $0.id == item.id }) {
            allItems[index] = item
        }
        if let index = visibleItems.firstIndex(where: { $0.id == item.id }) {
            visibleItems[index] = item
        }
    }

    private func rebuildAfterLocalMutation() {
        sourceGeneration &+= 1
        rebuildFacets()
        visibleItems = HighlightWorkspaceFilter.apply(
            to: allItems,
            request: filterRequest
        )
        visibleGroups = HighlightWorkspaceFilter.groups(from: visibleItems)
    }

    private func rebuildFacets() {
        var booksByID: [UUID: HighlightBookFilterOption] = [:]
        var tagsByKey: [String: String] = [:]
        for item in allItems {
            if booksByID[item.bookID] == nil {
                booksByID[item.bookID] = HighlightBookFilterOption(
                    id: item.bookID,
                    title: item.bookTitle,
                    author: item.bookAuthor
                )
            }
            for tag in item.tags {
                let key = MetadataNormalizer.tagComparisonKey(tag)
                if tagsByKey[key] == nil { tagsByKey[key] = tag }
            }
        }
        bookOptions = booksByID.values.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        tagOptions = tagsByKey.values.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        if let selectedBookID, booksByID[selectedBookID] == nil {
            self.selectedBookID = nil
        }
        if let selectedTag,
           tagsByKey[MetadataNormalizer.tagComparisonKey(selectedTag)] == nil {
            self.selectedTag = nil
        }
    }

    private func reconcileDraftAfterReload() {
        guard let selectedHighlightID else { return }
        guard let item = allItems.first(where: { $0.id == selectedHighlightID }) else {
            clearDraft()
            return
        }
        if !hasUnsavedChanges { loadDraft(from: item) }
    }
}
