import SwiftUI
import SwiftData

enum SidebarItem: Hashable {
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
    case updates

    var libraryFilter: LibraryFilter {
        switch self {
        case .all, .device, .discover, .updates: .all
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
    @Environment(DeviceMonitor.self) private var deviceMonitor
    @State private var showAuthors = false
    @State private var showSeries = false
    @State private var showTags = false
    @State private var showCreateCollection = false
    @State private var newCollectionName = ""
    @State private var renameTarget: BookCollection?
    @State private var renameText = ""
    @State private var browseRename: BrowseRename?
    @State private var browseRenameText = ""
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
                Label {
                    theme.styledText(terminal: "DISCOVER", native: "Discover")
                } icon: {
                    Image(systemName: "sparkles")
                }
                .font(theme.label(size: 12))
                .lineLimit(1)
                .tag(SidebarItem.discover)
                SidebarRow(
                    title: theme.styledText(terminal: "UPDATES", native: "Updates"),
                    systemImage: "bell",
                    count: viewModel.notices.unreadCount
                )
                .tag(SidebarItem.updates)
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
                onNew: { newCollectionName = ""; showCreateCollection = true },
                onRename: { renameText = $0.name; renameTarget = $0 },
                onDelete: { viewModel.deleteCollection($0) }
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
                                     onRename: { browseRenameText = $0; browseRename = .tag($0) }, onDelete: { viewModel.deleteTag($0) })
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
                SidebarRow(title: theme.styledText(terminal: "UNREAD", native: "Unread"),
                           systemImage: "book.closed", count: facets.unread)
                    .tag(SidebarItem.status(.unread))
                SidebarRow(title: theme.styledText(terminal: "READING", native: "Reading"),
                           systemImage: "book", count: facets.reading)
                    .tag(SidebarItem.status(.reading))
                SidebarRow(title: theme.styledText(terminal: "FINISHED", native: "Finished"),
                           systemImage: "checkmark.circle", count: facets.finished)
                    .tag(SidebarItem.status(.finished))
            } header: {
                header(terminal: "STATUS", native: "Reading Status")
            }
        }
        .listStyle(.sidebar)
        .task(id: FacetRevision(
            revision: LibraryMutationLog.shared.revision,
            bookCount: books.count
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
    }

    private func header(terminal: String, native: LocalizedStringKey) -> Text {
        theme.styledText(terminal: terminal, native: native)
            .font(theme.label(size: 10, weight: .semibold))
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
        var unread = 0
        var reading = 0
        var finished = 0
        var recent = 0
        var smartCounts: [UUID: Int] = [:]
        var authorTips: [(original: String, suggestion: String)] = []
        var seriesTips: [(original: String, suggestion: String)] = []
    }

    private func refreshFacets() async {
        let searches = collections.compactMap { collection -> (UUID, String)? in
            guard collection.isSmart, !collection.isWishlist,
                  let search = collection.savedSearch else { return nil }
            return (collection.id, search)
        }
        var facetBooks: [FacetBook] = []
        var searchBooks: [LibraryQuery.SearchSnapshot] = []
        let includesSearch = !searches.isEmpty
        facetBooks.reserveCapacity(books.count)
        if includesSearch { searchBooks.reserveCapacity(books.count) }
        for (index, book) in books.enumerated() {
            facetBooks.append(FacetBook(book))
            if includesSearch { searchBooks.append(LibraryQuery.SearchSnapshot(book)) }
            if (index + 1).isMultiple(of: 512) {
                await Task.yield()
                guard !Task.isCancelled else { return }
            }
        }
        let updated = await Self.makeFacets(
            books: facetBooks,
            searchBooks: searchBooks,
            searches: searches
        )
        guard !Task.isCancelled else { return }
        facets = updated
    }

    // @Model values are snapshotted on the main actor before this work starts.
    @concurrent
    private static func makeFacets(
        books: [FacetBook],
        searchBooks: [LibraryQuery.SearchSnapshot],
        searches: [(UUID, String)]
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
            switch book.readingStatus {
            case .unread:   facets.unread += 1
            case .reading:  facets.reading += 1
            case .finished: facets.finished += 1
            }
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
