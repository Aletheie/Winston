import SwiftUI

nonisolated struct LibrarySelectionCommandBarModel: Equatable, Sendable {
    let selectedCount: Int
    let visibleSelectedCount: Int
    let displayedCount: Int
    let availability: BookActionAvailability
    let deviceIsConnected: Bool
    let kindleOperationIsActive: Bool

    var hiddenCount: Int { max(selectedCount - visibleSelectedCount, 0) }
    var canSelectAllVisible: Bool {
        displayedCount > 0 && visibleSelectedCount < displayedCount
    }
    var canSend: Bool {
        deviceIsConnected && !kindleOperationIsActive && availability.canTransmit
    }
}

struct LibrarySelectionCommandBar: View {
    let model: LibrarySelectionCommandBarModel
    let collections: [BookCollection]
    let onSelectAllVisible: () -> Void
    let onClear: () -> Void
    let onEdit: () -> Void
    let onSetStatus: (ReadingStatus) -> Void
    let onAddToCollection: (BookCollection) -> Void
    let onNewCollection: () -> Void
    let onSend: () -> Void
    let onDelete: () -> Void

    private var manualCollections: [BookCollection] {
        collections.filter { !$0.isSmart && !$0.isSystem }
    }

    var body: some View {
        SelectionCommandBar(
            selectedCount: model.selectedCount,
            hiddenCount: model.hiddenCount,
            canSelectAllVisible: model.canSelectAllVisible,
            onSelectAllVisible: onSelectAllVisible,
            onClear: onClear
        ) {
            Button("Edit", systemImage: "pencil", action: onEdit)
                .disabled(!model.availability.canEditMetadata)
            statusMenu
            collectionMenu
            Button("Send", systemImage: "paperplane", action: onSend)
                .disabled(!model.canSend)
                .help(sendHelp)
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        } compactActions: {
            Button("Edit", systemImage: "pencil", action: onEdit)
                .labelStyle(.iconOnly)
                .disabled(!model.availability.canEditMetadata)
                .help("Edit Metadata")
            Menu {
                statusMenu
                collectionMenu
                Divider()
                Button("Send to Kindle", systemImage: "paperplane", action: onSend)
                    .disabled(!model.canSend)
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Label("More Selection Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .help("More Selection Actions")
        }
    }

    private var statusMenu: some View {
        Menu("Status", systemImage: "bookmark") {
            ForEach(ReadingStatus.allCases) { status in
                Button(status.label) { onSetStatus(status) }
            }
        }
    }

    private var collectionMenu: some View {
        Menu("Collection", systemImage: "tray.full") {
            ForEach(manualCollections) { collection in
                Button(collection.name) { onAddToCollection(collection) }
            }
            if !manualCollections.isEmpty { Divider() }
            Button("New Collection…", action: onNewCollection)
        }
    }

    private var sendHelp: LocalizedStringResource {
        if model.kindleOperationIsActive {
            return "A Kindle operation is already in progress"
        }
        if !model.deviceIsConnected {
            return "Connect a Kindle to send books"
        }
        if !model.availability.canTransmit {
            return "The selection has no sendable digital files"
        }
        return "Send selected books to the device"
    }
}
