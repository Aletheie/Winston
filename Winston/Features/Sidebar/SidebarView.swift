import SwiftUI
import SwiftData
import OSLog

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

    @State private var facets = Facets()

    var body: some View {
        List(selection: $selection) {
            Section {
                SidebarRow(title: theme.styledText(terminal: "ALL BOOKS", native: "All Books"),
                           systemImage: "books.vertical", count: books.count)
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
                    let draggedBooks = books.filter { bookIDs.contains($0.uuid) }
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
        .task(id: FacetRevision(
            revision: LibraryMutationLog.shared.catalogRevision,
            bookCount: books.count,
            deviceFileNames: deviceMonitor.deviceFileNames,
            deviceIsConnected: deviceMonitor.isConnected
        )) {
            await refreshFacets()
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
                let count = books.lazy.filter { $0.tags.contains(target) }.count
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

    private var authorTip: (original: String, suggestion: String)? {
        facets.authorTips.first { !dismissedAuthorTips.contains($0.original) }
    }

    private var seriesTip: (original: String, suggestion: String)? {
        facets.seriesTips.first { !dismissedSeriesTips.contains($0.original) }
    }

    // MARK: - Facets

    private struct FacetRevision: Hashable {
        let revision: Int
        let bookCount: Int
        let deviceFileNames: Set<String>
        let deviceIsConnected: Bool
    }

    private nonisolated struct FacetBook: Sendable {
        let format: String
        let author: String?
        let series: String?
        let tags: [String]
        let isRated: Bool
        let readingStatus: ReadingStatus
        let dateAdded: Date

        @MainActor init(_ book: Book) {
            format = book.format
            author = book.displayAuthor
            series = book.series
            tags = book.tags
            isRated = (book.rating ?? 0) > 0
            readingStatus = book.readingStatus
            dateAdded = book.dateAdded
        }
    }

    private nonisolated struct Facets: Sendable {
        var formats: [String: Int] = [:]
        var authors: [String: Int] = [:]
        var series: [String: Int] = [:]
        var tags: [String: Int] = [:]
        var formatKeys: [String] = []
        var authorKeys: [String] = []
        var seriesKeys: [String] = []
        var tagKeys: [String] = []
        var rated = 0
        var statusCounts: [ReadingStatus: Int] = [:]
        var recent = 0
        var smartCounts: [UUID: Int] = [:]
        var authorTips: [(original: String, suggestion: String)] = []
        var seriesTips: [(original: String, suggestion: String)] = []
    }

    private func refreshFacets() async {
        var searches: [(UUID, String)] = []
        var shelves: [(UUID, SmartShelfDefinition)] = []
        for collection in collections where collection.isSmart && !collection.isWishlist {
            if let definition = collection.smartShelfDefinition {
                shelves.append((collection.id, definition))
            } else if let search = collection.savedSearch {
                searches.append((collection.id, search))
            }
        }
        var facetBooks: [FacetBook] = []
        var searchBooks: [LibraryQuery.SearchSnapshot] = []
        var shelfBooks: [SmartShelfBookSnapshot] = []
        let includesSearch = !searches.isEmpty
        let includesShelves = !shelves.isEmpty
        let includesHighlights = shelves.contains { $0.1.requiresHighlights }
        facetBooks.reserveCapacity(books.count)
        if includesSearch { searchBooks.reserveCapacity(books.count) }
        if includesShelves { shelfBooks.reserveCapacity(books.count) }
        for (index, book) in books.enumerated() {
            facetBooks.append(FacetBook(book))
            if includesSearch { searchBooks.append(LibraryQuery.SearchSnapshot(book)) }
            if includesShelves {
                shelfBooks.append(SmartShelfBookSnapshot(book, includeHighlights: includesHighlights))
            }
            if (index + 1).isMultiple(of: 512) {
                await Task.yield()
                guard !Task.isCancelled else { return }
            }
        }
        let signposter = Log.librarySignposter
        let interval = signposter.beginInterval("SidebarFacets")
        let updated = await Self.makeFacets(
            books: facetBooks,
            searchBooks: searchBooks,
            searches: searches,
            shelfBooks: shelfBooks,
            shelves: shelves,
            deviceFileNames: deviceMonitor.deviceFileNames,
            deviceIsConnected: deviceMonitor.isConnected
        )
        signposter.endInterval("SidebarFacets", interval)
        guard !Task.isCancelled else { return }
        facets = updated
    }

    // @Model values are snapshotted on the main actor before this work starts.
    @concurrent
    private static func makeFacets(
        books: [FacetBook],
        searchBooks: [LibraryQuery.SearchSnapshot],
        searches: [(UUID, String)],
        shelfBooks: [SmartShelfBookSnapshot],
        shelves: [(UUID, SmartShelfDefinition)],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) async -> Facets {
        var facets = Facets()
        let recentCutoff = Date.now.addingTimeInterval(-14 * 24 * 3600)
        for book in books {
            guard !Task.isCancelled else { return facets }
            facets.formats[book.format, default: 0] += 1
            if let author = book.author { facets.authors[author, default: 0] += 1 }
            if let series = book.series, !series.isEmpty { facets.series[series, default: 0] += 1 }
            for tag in book.tags { facets.tags[tag, default: 0] += 1 }
            if book.isRated { facets.rated += 1 }
            facets.statusCounts[book.readingStatus, default: 0] += 1
            if book.dateAdded > recentCutoff { facets.recent += 1 }
        }
        facets.formatKeys = facets.formats.keys.sorted()
        facets.authorKeys = facets.authors.keys.sorted()
        facets.seriesKeys = facets.series.compactMap { series, count in
            count > 1 ? series : nil
        }.sorted()
        facets.tagKeys = facets.tags.keys.sorted()
        facets.authorTips = facets.authorKeys.compactMap { author in
            MetadataFixFinder.reversedAuthorSuggestion(author).map { (author, $0) }
        }
        facets.seriesTips = SeriesSuggestions.unificationTips(counts: facets.series)
        facets.smartCounts = LibraryQuery.smartCounts(for: searchBooks, searches: searches)
        let structuredCounts = LibraryQuery.smartShelfCounts(
            for: shelfBooks,
            shelves: shelves,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected
        )
        facets.smartCounts.merge(structuredCounts) { _, structured in structured }
        return facets
    }
}

// MARK: - Previews

#Preview("Sidebar") {
    let container = PersistenceController.inMemory()
    SidebarView(
        books: [],
        collections: [],
        viewModel: LibraryViewModel(modelContext: container.mainContext, settings: AppSettings(), toasts: ToastCenter()),
        selection: .constant(.all),
        onReviewEditions: {}
    )
    .modelContainer(container)
    .environment(DeviceMonitor())
    .frame(width: 240, height: 620)
}
