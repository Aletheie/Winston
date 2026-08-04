import SwiftUI
import SwiftData

nonisolated struct EntityNavigationModel: Equatable, Sendable {
    enum Level: String, CaseIterable, Equatable, Sendable {
        case work
        case edition
        case asset
    }

    struct Asset: Identifiable, Equatable, Sendable {
        let id: UUID
        let label: String
        let fileName: String
        let isPrimary: Bool
    }

    struct Edition: Identifiable, Equatable, Sendable {
        let id: UUID
        let label: String
        let assets: [Asset]
    }

    struct Position: Equatable, Sendable {
        let current: Int
        let total: Int
    }

    private(set) var workID: UUID?
    private(set) var workTitle: String
    private(set) var editions: [Edition]
    private(set) var level: Level
    private(set) var selectedEditionID: UUID?
    private(set) var selectedAssetID: UUID?

    init(
        workID: UUID?,
        workTitle: String,
        editions: [Edition],
        selectedEditionID: UUID? = nil,
        selectedAssetID: UUID? = nil,
        level: Level = .edition
    ) {
        self.workID = workID
        self.workTitle = workTitle
        self.editions = editions
        self.level = level
        self.selectedEditionID = editions.contains(where: { $0.id == selectedEditionID })
            ? selectedEditionID
            : editions.first?.id
        self.selectedAssetID = selectedAssetID
        repairSelection()
    }

    var selectedEdition: Edition? {
        guard let selectedEditionID else { return nil }
        return editions.first(where: { $0.id == selectedEditionID })
    }

    var selectedAsset: Asset? {
        guard let selectedAssetID else { return nil }
        return selectedEdition?.assets.first(where: { $0.id == selectedAssetID })
    }

    var assets: [Asset] { selectedEdition?.assets ?? [] }

    var position: Position? {
        switch level {
        case .work:
            guard workID != nil else { return nil }
            return Position(current: 1, total: 1)
        case .edition:
            guard let selectedEditionID,
                  let index = editions.firstIndex(where: { $0.id == selectedEditionID }) else {
                return nil
            }
            return Position(current: index + 1, total: editions.count)
        case .asset:
            guard let selectedAssetID,
                  let index = assets.firstIndex(where: { $0.id == selectedAssetID }) else {
                return nil
            }
            return Position(current: index + 1, total: assets.count)
        }
    }

    var canMovePrevious: Bool { (position?.current ?? 1) > 1 }
    var canMoveNext: Bool {
        guard let position else { return false }
        return position.current < position.total
    }

    mutating func selectWork() {
        guard workID != nil else { return }
        level = .work
    }

    mutating func selectEdition(_ id: UUID) {
        guard let edition = editions.first(where: { $0.id == id }) else { return }
        selectedEditionID = edition.id
        selectedAssetID = preferredAssetID(in: edition)
        level = .edition
    }

    mutating func selectAsset(_ id: UUID) {
        guard let edition = editions.first(where: { edition in
            edition.assets.contains(where: { $0.id == id })
        }) else { return }
        selectedEditionID = edition.id
        selectedAssetID = id
        level = .asset
    }

    mutating func movePrevious() {
        move(by: -1)
    }

    mutating func moveNext() {
        move(by: 1)
    }

    mutating func reconcile(with updated: EntityNavigationModel) {
        workID = updated.workID
        workTitle = updated.workTitle
        editions = updated.editions

        if !editions.contains(where: { $0.id == selectedEditionID }) {
            selectedEditionID = updated.selectedEditionID ?? editions.first?.id
        }
        repairSelection()
    }

    @MainActor
    init(book: Book) {
        let work = book.work
        let liveEditions = Self.sortedEditions(
            work?.editions.filter { $0.modelContext != nil } ?? [book]
        )
        self.init(
            workID: work?.uuid,
            workTitle: work?.displayTitle ?? String(localized: "No work"),
            editions: liveEditions.map(Self.editionSnapshot),
            selectedEditionID: book.uuid,
            selectedAssetID: book.primaryAsset?.uuid,
            level: .edition
        )
    }

    @MainActor
    init(work: Work, selectedEditionID: UUID? = nil) {
        let liveEditions = Self.sortedEditions(work.editions.filter { $0.modelContext != nil })
        let initialEditionID = selectedEditionID
            ?? WorkService.preferredEdition(in: work)?.uuid
            ?? liveEditions.first?.uuid
        let initialBook = liveEditions.first(where: { $0.uuid == initialEditionID })
        self.init(
            workID: work.uuid,
            workTitle: work.displayTitle,
            editions: liveEditions.map(Self.editionSnapshot),
            selectedEditionID: initialEditionID,
            selectedAssetID: initialBook?.primaryAsset?.uuid,
            level: .work
        )
    }

    private mutating func repairSelection() {
        guard !editions.isEmpty else {
            selectedEditionID = nil
            selectedAssetID = nil
            level = workID == nil ? .edition : .work
            return
        }

        if selectedEdition == nil {
            selectedEditionID = editions.first?.id
        }
        guard let edition = selectedEdition else {
            selectedAssetID = nil
            return
        }
        if !edition.assets.contains(where: { $0.id == selectedAssetID }) {
            selectedAssetID = preferredAssetID(in: edition)
        }
        if level == .work, workID == nil { level = .edition }
        if level == .asset, selectedAssetID == nil { level = .edition }
    }

    private mutating func move(by offset: Int) {
        switch level {
        case .work:
            return
        case .edition:
            guard let selectedEditionID,
                  let index = editions.firstIndex(where: { $0.id == selectedEditionID }) else {
                return
            }
            let destination = index + offset
            guard editions.indices.contains(destination) else { return }
            selectEdition(editions[destination].id)
        case .asset:
            guard let selectedAssetID,
                  let index = assets.firstIndex(where: { $0.id == selectedAssetID }) else {
                return
            }
            let destination = index + offset
            guard assets.indices.contains(destination) else { return }
            selectAsset(assets[destination].id)
        }
    }

    private func preferredAssetID(in edition: Edition) -> UUID? {
        edition.assets.first(where: \.isPrimary)?.id ?? edition.assets.first?.id
    }

    @MainActor
    private static func sortedEditions(_ editions: [Book]) -> [Book] {
        editions.sorted {
            if $0.dateAdded != $1.dateAdded { return $0.dateAdded < $1.dateAdded }
            return $0.uuid.uuidString < $1.uuid.uuidString
        }
    }

    @MainActor
    private static func editionSnapshot(_ book: Book) -> Edition {
        let primaryID = book.primaryAsset?.uuid
        let assets = book.assets
            .sorted {
                if ($0.uuid == primaryID) != ($1.uuid == primaryID) {
                    return $0.uuid == primaryID
                }
                if $0.format != $1.format { return $0.format < $1.format }
                if $0.fileName != $1.fileName { return $0.fileName < $1.fileName }
                return $0.uuid.uuidString < $1.uuid.uuidString
            }
            .map { asset in
                Asset(
                    id: asset.uuid,
                    label: asset.format.isEmpty ? asset.fileName : asset.format,
                    fileName: asset.fileName,
                    isPrimary: asset.uuid == primaryID
                )
            }
        return Edition(id: book.uuid, label: book.displayTitle, assets: assets)
    }
}

struct EntityBreadcrumb: View {
    @Binding var model: EntityNavigationModel

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: WinstonLayout.space2) {
            navigationMenu
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            contextPosition
                .font(theme.label(size: 9, weight: .medium))
                .foregroundStyle(theme.textTertiary)

            Button(action: { model.movePrevious() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canMovePrevious)
            .help(previousLabel)
            .accessibilityLabel(previousLabel)

            Button(action: { model.moveNext() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canMoveNext)
            .help(nextLabel)
            .accessibilityLabel(nextLabel)
        }
        .padding(.horizontal, WinstonLayout.space3)
        .padding(.vertical, WinstonLayout.space1)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Related item navigator")
        .accessibilityAction(named: Text(previousLabel)) {
            model.movePrevious()
        }
        .accessibilityAction(named: Text(nextLabel)) {
            model.moveNext()
        }
    }

    private var navigationMenu: some View {
        Menu {
            if model.workID != nil {
                Button {
                    model.selectWork()
                } label: {
                    if model.level == .work {
                        Label(model.workTitle, systemImage: "checkmark")
                    } else {
                        Text(model.workTitle)
                    }
                }
            }

            if !model.editions.isEmpty {
                Section("Editions") {
                    ForEach(model.editions) { edition in
                        Button {
                            model.selectEdition(edition.id)
                        } label: {
                            if model.level == .edition,
                               edition.id == model.selectedEditionID {
                                Label(edition.label, systemImage: "checkmark")
                            } else {
                                Text(edition.label)
                            }
                        }
                    }
                }
            }

            if !model.assets.isEmpty {
                Section("Files") {
                    ForEach(model.assets) { asset in
                        Button {
                            model.selectAsset(asset.id)
                        } label: {
                            if model.level == .asset,
                               asset.id == model.selectedAssetID {
                                Label(asset.fileName, systemImage: "checkmark")
                            } else {
                                Text(asset.fileName)
                            }
                        }
                    }
                }
            }
        } label: {
            Label(currentTitle, systemImage: currentSystemImage)
                .font(theme.label(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(theme.textSecondary)
        .accessibilityLabel(currentAccessibilityLabel)
    }

    @ViewBuilder
    private var contextPosition: some View {
        if let position = model.position {
            Text("\(position.current)/\(position.total)")
        } else {
            EmptyView()
        }
    }

    private var currentTitle: String {
        switch model.level {
        case .work:
            model.workTitle
        case .edition:
            model.selectedEdition?.label ?? String(localized: "No edition")
        case .asset:
            model.selectedAsset?.label ?? String(localized: "No digital asset")
        }
    }

    private var currentSystemImage: String {
        switch model.level {
        case .work: "books.vertical"
        case .edition: "book.closed"
        case .asset: "doc"
        }
    }

    private var currentAccessibilityLabel: String {
        switch model.level {
        case .work:
            return String(localized: "Work: \(model.workTitle)")
        case .edition:
            guard let edition = model.selectedEdition else {
                return String(localized: "No edition")
            }
            guard let position = model.position else {
                return String(localized: "Edition: \(edition.label)")
            }
            return String(localized: "Edition \(position.current) of \(position.total): \(edition.label)")
        case .asset:
            guard let asset = model.selectedAsset else {
                return String(localized: "No digital asset")
            }
            guard let position = model.position else {
                return String(localized: "Asset: \(asset.fileName)")
            }
            return String(localized: "Asset \(position.current) of \(position.total): \(asset.fileName)")
        }
    }

    private var previousLabel: String {
        switch model.level {
        case .work: String(localized: "Previous work")
        case .edition: String(localized: "Previous edition")
        case .asset: String(localized: "Previous asset")
        }
    }

    private var nextLabel: String {
        switch model.level {
        case .work: String(localized: "Next work")
        case .edition: String(localized: "Next edition")
        case .asset: String(localized: "Next asset")
        }
    }
}
