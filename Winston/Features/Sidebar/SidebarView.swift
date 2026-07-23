import SwiftUI
import SwiftData

enum SidebarItem: Hashable, RawRepresentable {
    case all
    case recentlyAdded
    case status(ReadingStatus)
    case collection(UUID)
    case rated
    case format(String)
    case author(String)
    case series(String)
    case tag(String)
    case device
    case discover
    case catalogs
    case updates

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let value = parts.count == 2 ? String(parts[1]) : ""
        switch String(parts[0]) {
        case "all": self = .all
        case "recentlyAdded": self = .recentlyAdded
        case "rated": self = .rated
        case "device": self = .device
        case "discover": self = .discover
        case "catalogs": self = .catalogs
        case "updates": self = .updates
        case "status":
            guard let status = ReadingStatus(rawValue: value) else { return nil }
            self = .status(status)
        case "collection":
            guard let id = UUID(uuidString: value) else { return nil }
            self = .collection(id)
        case "format": self = .format(value)
        case "author": self = .author(value)
        case "series": self = .series(value)
        case "tag": self = .tag(value)
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .all: "all"
        case .recentlyAdded: "recentlyAdded"
        case .rated: "rated"
        case .device: "device"
        case .discover: "discover"
        case .catalogs: "catalogs"
        case .updates: "updates"
        case .status(let status): "status:\(status.rawValue)"
        case .collection(let id): "collection:\(id.uuidString)"
        case .format(let value): "format:\(value)"
        case .author(let value): "author:\(value)"
        case .series(let value): "series:\(value)"
        case .tag(let value): "tag:\(value)"
        }
    }

    var libraryFilter: LibraryFilter {
        switch self {
        case .all, .device, .discover, .catalogs, .updates: .all
        case .recentlyAdded:   .recentlyAdded
        case .status(let s):   .status(s)
        case .collection(let id): .collection(id)
        case .rated:           .rated
        case .format(let f):   .format(f)
        case .author(let a):   .author(a)
        case .series(let s):   .series(s)
        case .tag(let t):      .tag(t)
        }
    }
}

struct SidebarView: View {
    var books: [Book]
    var collections: [BookCollection]
    var readModel: LibraryReadModel
    var viewModel: LibraryViewModel
    @Binding var selection: SidebarItem?
    let onReviewEditions: () -> Void

    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings
    @Environment(DeviceMonitor.self) private var deviceMonitor
    @State private var showAuthors = false
    @State private var showSeries = false
    @State private var showTags = false
    @State private var showCreateCollection = false
    @State private var newCollectionName = ""
    @State private var smartShelfRequest: SmartShelfEditorRequest?
    @State private var renameTarget: BookCollection?
    @State private var renameText = ""
    @State private var browseRename: BrowseRename?
    @State private var browseRenameText = ""
    @State private var deleteCollectionTarget: BookCollection?
    @State private var deleteTagTarget: String?
    @State private var dismissedAuthorTips: Set<String> = []
    @State private var dismissedSeriesTips: Set<String> = []

    enum BrowseRename: Identifiable {
        case author(String), series(String), tag(String)
        var id: String {
            switch self {
            case .author(let v): "a:\(v)"
            case .series(let v): "s:\(v)"
            case .tag(let v):    "t:\(v)"
            }
        }
        var original: String {
            switch self {
            case .author(let v), .series(let v), .tag(let v): v
            }
        }
    }

    private var facets: LibraryFacetSnapshot { readModel.facets }

    var body: some View {
        List(selection: $selection) {
            Section {
                SidebarRow(title: theme.styledText(terminal: "ALL BOOKS", native: "All Books"),
                           systemImage: "books.vertical", count: readModel.bookCount)
                    .tag(SidebarItem.all)
                if settings.showDiscoverInSidebar {
                    Label {
                        theme.styledText(terminal: "DISCOVER", native: "Discover")
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                    .font(theme.label(size: 14))
                    .lineLimit(1)
                    .tag(SidebarItem.discover)
                    .accessibilityIdentifier("sidebar.discover")
                }
                if settings.showCatalogsInSidebar {
                    Label {
                        theme.styledText(terminal: "CATALOGS", native: "Catalogs")
                    } icon: {
                        Image(systemName: "globe")
                    }
                    .font(theme.label(size: 14))
                    .lineLimit(1)
                    .tag(SidebarItem.catalogs)
                    .accessibilityIdentifier("sidebar.catalogs")
                }
                SidebarRow(
                    title: theme.styledText(terminal: "UPDATES", native: "Updates"),
                    systemImage: "bell",
                    count: viewModel.notices.unreadCount
                )
                .tag(SidebarItem.updates)
                .accessibilityIdentifier("sidebar.updates")
                if facets.recent > 0 {
                    SidebarRow(title: theme.styledText(terminal: "RECENTLY ADDED", native: "Recently Added"),
                               systemImage: "clock", count: facets.recent)
                        .tag(SidebarItem.recentlyAdded)
                }
                if facets.rated > 0 {
                    SidebarRow(title: theme.styledText(terminal: "RATED", native: "Rated"),
                               systemImage: "star", count: facets.rated)
                        .tag(SidebarItem.rated)
                }
                if viewModel.editions.pendingCount > 0 {
                    Button(action: onReviewEditions) {
                        SidebarRow(
                            title: theme.styledText(terminal: "NAVRHY", native: "Suggestions"),
                            systemImage: "rectangle.stack.badge.plus",
                            count: viewModel.editions.pendingCount
                        )
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                header(terminal: "LIBRARY", native: "Library")
            }

            CollectionsSection(
                collections: collections,
                smartCounts: facets.smartCounts,
                wishlistCount: viewModel.wishlist.count,
                onNewCollection: { newCollectionName = ""; showCreateCollection = true },
                onNewSmartShelf: { smartShelfRequest = .create() },
                onEditSmartShelf: { smartShelfRequest = SmartShelfEditorRequest.edit($0) },
                onRename: { renameText = $0.name; renameTarget = $0 },
                onDelete: { deleteCollectionTarget = $0 },
                onDropBooks: { bookIDs, collection in
                    guard !collection.isSystem, !collection.isSmart else { return }
                    let draggedBooks = readModel.books(for: Array(bookIDs))
                    guard !draggedBooks.isEmpty else { return }
                    viewModel.add(draggedBooks, to: collection)
                }
            )

            if !facets.formatKeys.isEmpty || !facets.authorKeys.isEmpty || !facets.seriesKeys.isEmpty || !facets.tagKeys.isEmpty {
                Section {
                    ForEach(facets.formatKeys, id: \.self) { format in
                        SidebarRow(title: Text(verbatim: format), systemImage: "doc", count: facets.formats[format] ?? 0)
                            .tag(SidebarItem.format(format))
                    }
                    BrowseDisclosure(terminal: "AUTHORS", native: "Authors", isExpanded: $showAuthors, items: facets.authorKeys,
                                     icon: "person", count: { facets.authors[$0] ?? 0 }, make: SidebarItem.author,
                                     onRename: { browseRenameText = $0; browseRename = .author($0) }, onDelete: nil)
                    BrowseDisclosure(terminal: "SERIES", native: "Series", isExpanded: $showSeries, items: facets.seriesKeys,
                                     icon: "books.vertical.fill", count: { facets.series[$0] ?? 0 }, make: SidebarItem.series,
                                     onRename: { browseRenameText = $0; browseRename = .series($0) }, onDelete: nil)
                    BrowseDisclosure(terminal: "TAGS", native: "Tags", isExpanded: $showTags, items: facets.tagKeys,
                                     icon: "tag", count: { facets.tags[$0] ?? 0 }, make: SidebarItem.tag,
                                     onRename: { browseRenameText = $0; browseRename = .tag($0) }, onDelete: { deleteTagTarget = $0 })
                } header: {
                    header(terminal: "BROWSE", native: "Browse")
                }
            }

            Section {
                if deviceMonitor.info != nil {
                    DeviceSidebarRow(info: deviceMonitor.info)
                        .tag(SidebarItem.device)
                } else {
                    DeviceSidebarRow(info: nil)
                }
            } header: {
                header(terminal: "DEVICE", native: "Device")
            }

            Section {
                ForEach(ReadingStatus.allCases) { status in
                    SidebarRow(
                        title: Text(verbatim: theme.usesTerminalCopy
                            ? status.terminalLabel.uppercased()
                            : status.label),
                        systemImage: status == .unread ? "book.closed" : status.systemImage,
                        count: facets.statusCounts[status, default: 0]
                    )
                    .tag(SidebarItem.status(status))
                }
            } header: {
                header(terminal: "STATUS", native: "Reading Status")
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection, initial: true) { _, selection in
            guard let selection else { return }
            switch selection {
            case .author:
                showAuthors = true
            case .series:
                showSeries = true
            case .tag:
                showTags = true
            default:
                break
            }
        }
        .tint(theme.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let tip = authorTip {
                    SidebarFixTip(
                        title: theme.styledText(terminal: "fix_author?", native: "Author name looks reversed"),
                        applyHelp: theme.styledText(
                            terminal: "rename author everywhere",
                            native: "Rename this author across the library"
                        ),
                        original: tip.original,
                        suggestion: tip.suggestion,
                        onApply: { viewModel.renameAuthor(tip.original, to: tip.suggestion) },
                        onDismiss: { dismissedAuthorTips.insert(tip.original) }
                    )
                    Divider().opacity(0.3)
                } else if let tip = seriesTip {
                    SidebarFixTip(
                        title: theme.styledText(terminal: "fix_series?", native: "Series name looks duplicated"),
                        applyHelp: theme.styledText(
                            terminal: "rename series everywhere",
                            native: "Rename this series across the library"
                        ),
                        original: tip.original,
                        suggestion: tip.suggestion,
                        onApply: { viewModel.renameSeries(tip.original, to: tip.suggestion) },
                        onDismiss: { dismissedSeriesTips.insert(tip.original) }
                    )
                    Divider().opacity(0.3)
                }
                Text(verbatim: "v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .font(theme.label(size: 9, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
        }
        .sheet(item: $smartShelfRequest) { request in
            SmartShelfEditorSheet(
                request: request,
                books: books,
                formats: facets.formatKeys,
                deviceFileNames: deviceMonitor.deviceFileNames,
                deviceIsConnected: deviceMonitor.isConnected
            ) { name, definition in
                saveSmartShelf(request: request, name: name, definition: definition)
            }
        }
        .alert(theme.usesTerminalCopy ? "// new_collection" : "New Collection", isPresented: $showCreateCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                let name = newCollectionName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { viewModel.createCollection(named: name) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Rename Collection", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if let target = renameTarget, !name.isEmpty { viewModel.renameCollection(target, to: name) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Rename", isPresented: Binding(
            get: { browseRename != nil },
            set: { if !$0 { browseRename = nil } }
        )) {
            TextField("Name", text: $browseRenameText)
            Button("Rename") {
                if let target = browseRename {
                    switch target {
                    case .author(let v): viewModel.renameAuthor(v, to: browseRenameText)
                    case .series(let v): viewModel.renameSeries(v, to: browseRenameText)
                    case .tag(let v):    viewModel.renameTag(v, to: browseRenameText)
                    }
                }
                browseRename = nil
            }
            Button("Cancel", role: .cancel) { browseRename = nil }
        }
        .alert("Delete Collection \u{201C}\(deleteCollectionTarget?.name ?? "")\u{201D}?", isPresented: Binding(
            get: { deleteCollectionTarget != nil },
            set: { if !$0 { deleteCollectionTarget = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let target = deleteCollectionTarget { viewModel.deleteCollection(target) }
                deleteCollectionTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteCollectionTarget = nil }
        } message: {
            if let target = deleteCollectionTarget {
                Text(
                    "\(target.books.count) books in this collection stay in your library.",
                    comment: "Deletion confirmation: number of books that remain after their collection is deleted."
                )
            }
        }
        .alert("Delete Tag \u{201C}\(deleteTagTarget ?? "")\u{201D}?", isPresented: Binding(
            get: { deleteTagTarget != nil },
            set: { if !$0 { deleteTagTarget = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let target = deleteTagTarget { viewModel.deleteTag(target) }
                deleteTagTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTagTarget = nil }
        } message: {
            if let target = deleteTagTarget {
                let count = facets.tags[target, default: 0]
                Text(
                    "The tag is removed from \(count) books.",
                    comment: "Deletion confirmation: number of books from which the tag is removed."
                )
            }
        }
    }

    private func header(terminal: String, native: LocalizedStringKey) -> Text {
        theme.styledText(terminal: terminal, native: native)
            .font(theme.label(size: 10, weight: .semibold))
    }

    private func saveSmartShelf(
        request: SmartShelfEditorRequest,
        name: String,
        definition: SmartShelfDefinition
    ) -> Bool {
        if let id = request.collectionID,
           let collection = collections.first(where: { $0.id == id }) {
            guard viewModel.updateSmartShelf(collection, name: name, definition: definition) else {
                return false
            }
            selection = .collection(collection.id)
            return true
        }
        guard let collection = viewModel.createSmartShelf(named: name, definition: definition) else {
            return false
        }
        selection = .collection(collection.id)
        return true
    }

    // MARK: - Author tip

    private var authorTip: LibraryFacetTip? {
        facets.authorTips.first { !dismissedAuthorTips.contains($0.original) }
    }

    private var seriesTip: LibraryFacetTip? {
        facets.seriesTips.first { !dismissedSeriesTips.contains($0.original) }
    }
}

// MARK: - Previews

#Preview("Sidebar") {
    let container = PersistenceController.inMemory()
    SidebarView(
        books: [],
        collections: [],
        readModel: LibraryReadModel(),
        viewModel: LibraryViewModel(modelContext: container.mainContext, settings: AppSettings(), toasts: ToastCenter()),
        selection: .constant(.all),
        onReviewEditions: {}
    )
    .modelContainer(container)
    .environment(DeviceMonitor())
    .frame(width: 240, height: 620)
}
