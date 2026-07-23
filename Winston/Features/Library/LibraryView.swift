import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import QuickLook
import OSLog

enum LibrarySheet: Identifiable {
    case addPhysicalBook
    case edit(Book)
    case bulkEdit
    case metadataFixes
    case statistics
    case highlights
    case series(name: String?)
    case work(Work)
    case editionReview
    case bookDoctor(BookDoctorRequest)
    case readingHistory(Book)
    case fullTextSearch
    case readingRecommendation
    case readingHistoryImport(URL)

    var id: String {
        switch self {
        case .addPhysicalBook: "addPhysicalBook"
        case .edit(let book): "edit-\(book.uuid.uuidString)"
        case .bulkEdit:       "bulkEdit"
        case .metadataFixes:  "metadataFixes"
        case .statistics:     "statistics"
        case .highlights:     "highlights"
        case .series(let name): "series-\(name ?? "all")"
        case .work(let work): "work-\(work.uuid.uuidString)"
        case .editionReview:  "editionReview"
        case .bookDoctor(let request): "bookDoctor-\(request.id.uuidString)"
        case .readingHistory(let book): "readingHistory-\(book.uuid.uuidString)"
        case .fullTextSearch: "fullTextSearch"
        case .readingRecommendation: "readingRecommendation"
        case .readingHistoryImport(let url): "readingHistoryImport-\(url.path(percentEncoded: false))"
        }
    }
}

struct LibraryView: View {
    var books: [Book]
    var collections: [BookCollection]
    var viewModel: LibraryViewModel
    let filter: LibraryFilter
    let onShowAll: () -> Void
    let onShowAuthor: (String) -> Void
    let onShowSeries: (String) -> Void
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var activeSheet: LibrarySheet?

    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings
    @Environment(DeviceMonitor.self) private var deviceMonitor
    @Environment(TransferQueue.self) private var transferQueue
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @FocusState private var searchFocused: Bool
    @State private var selection = BookSelectionModel()
    @State private var isDropTargeted = false
    @State private var isImporting = false
    @SceneStorage("library.viewMode") private var restoredViewMode = LibraryViewMode.grid.rawValue
    @State private var viewMode: LibraryViewMode = .grid
    @SceneStorage("library.showInspector") private var showInspector = true
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var kindlePresenceFilter: KindlePresenceFilter = .all
    @State private var displayed: [Book] = []
    @State private var animateNextDisplayChange = false
    @State private var displaySnapshots: [LibraryDisplaySnapshot] = []
    @State private var displaySnapshotRevision: DisplaySnapshotRevision?
    @State private var sortOrder: [KeyPathComparator<Book>] = [BookSort.dateAdded.comparator(ascending: false)]
    @State private var showDeleteConfirm = false
    @State private var pendingDeletion: [Book] = []
    @State private var quickLookURL: URL?
    @State private var showNewCollectionAlert = false
    @State private var newCollectionName = ""
    @State private var newCollectionTargets: [Book] = []
    @State private var showSaveSearchAlert = false
    @State private var saveSearchName = ""
    @State private var scrollTarget: Book.ID?
    @State private var commandContext = LibraryCommandContext()

    // MARK: - Derived state

    private var primarySelectedBook: Book? {
        selection.primaryBook(in: books)
    }

    private struct DisplaySnapshotRevision: Hashable {
        let mutationRevision: Int
        let bookCount: Int
        let includeCollections: Bool
        let includeHighlights: Bool
    }

    private enum ContentState: Hashable {
        case empty
        case grid
        case table
    }

    private var contentState: ContentState {
        if displayed.isEmpty { return .empty }
        return viewMode == .grid ? .grid : .table
    }

    private struct SmartShelfDisplayConfiguration: Hashable {
        let savedSearch: String?
        let definition: SmartShelfDefinition?
    }

    private struct DisplayRevision: Hashable {
        let snapshot: DisplaySnapshotRevision
        let filter: LibraryFilter
        let searchText: String
        let sort: LibraryDisplaySort
        let smartShelf: SmartShelfDisplayConfiguration?
        let deviceFileNames: Set<String>
        let deviceIsConnected: Bool
        let kindlePresenceFilter: KindlePresenceFilter
    }

    private var smartShelfDisplayConfiguration: SmartShelfDisplayConfiguration? {
        guard case .collection(let id) = filter,
              let collection = collections.first(where: { $0.id == id && $0.isSmart }) else {
            return nil
        }
        return SmartShelfDisplayConfiguration(
            savedSearch: collection.savedSearch,
            definition: collection.smartShelfDefinition
        )
    }

    private var displayRevision: DisplayRevision {
        let smartShelf = smartShelfDisplayConfiguration
        let includeCollections: Bool
        if case .collection = filter, smartShelf == nil {
            includeCollections = true
        } else {
            includeCollections = false
        }
        return DisplayRevision(
            snapshot: DisplaySnapshotRevision(
                mutationRevision: LibraryMutationLog.shared.catalogRevision,
                bookCount: books.count,
                includeCollections: includeCollections,
                includeHighlights: smartShelf?.definition?.requiresHighlights == true
            ),
            filter: filter,
            searchText: debouncedSearch,
            sort: LibraryQuery.displaySort(for: sortOrder),
            smartShelf: smartShelf,
            deviceFileNames: deviceMonitor.deviceFileNames,
            deviceIsConnected: deviceMonitor.isConnected,
            kindlePresenceFilter: kindlePresenceFilter
        )
    }

    private var bookActions: BookActions {
        BookActions(
            open: { LibraryExternalActions.openInReader($0) },
            openWork: { activeSheet = .work($0) },
            openSeries: { activeSheet = .series(name: $0) },
            showAuthorInLibrary: showAuthorInLibrary,
            quickLook: { quickLookURL = $0.primaryFileURL },
            showInFinder: { LibraryExternalActions.showInFinder($0) },
            edit: { activeSheet = .edit($0) },
            editSelection: { activeSheet = .bulkEdit },
            fetchMetadata: { book in viewModel.fetchOnlineMetadata(for: book) },
            fetchMetadataSelection: { viewModel.fetchOnlineMetadata(for: selectedBooks) },
            setStatus: { book, status in viewModel.setReadingStatus(status, for: targetBooks(for: book)) },
            readingHistory: { activeSheet = .readingHistory($0) },
            addToCollection: { book, collection in viewModel.add(targetBooks(for: book), to: collection) },
            newCollection: { book in
                newCollectionTargets = targetBooks(for: book)
                newCollectionName = ""
                showNewCollectionAlert = true
            },
            setCover: { book, url in viewModel.setCustomCover(for: book, from: url) },
            setCoverData: { book, data in viewModel.setCustomCover(for: book, from: data) },
            resetCover: { book in viewModel.resetCover(for: book) },
            relink: { book in Task { await LibraryExternalActions.relink(book, via: viewModel) } },
            inspect: { book in presentBookDoctor(for: [book], purpose: .review) },
            convert: { book in viewModel.convert(book) },
            convertTo: { book, format in viewModel.convert(book, to: format) },
            convertSelection: convertSelectedBooks,
            convertSelectionTo: { format in viewModel.convertBooks(selectedBooks, to: format) },
            delete: { book in
                pendingDeletion = [book]
                showDeleteConfirm = true
            },
            deleteSelection: {
                pendingDeletion = selectedBooks
                showDeleteConfirm = true
            },
            removeFromDevice: { book in deleteFromDevice(targetBooks(for: book)) },
            removeSelectionFromDevice: { deleteFromDevice(selectedBooks) }
        )
    }

    private var selectedBooks: [Book] {
        books.filter { selection.selectedBookIDs.contains($0.id) }
    }

    private func targetBooks(for book: Book) -> [Book] {
        (selection.count > 1 && selection.isSelected(book)) ? selectedBooks : [book]
    }

    private var convertibleSelectionCount: Int {
        selectedBooks.filter { $0.hasDigitalFile && EbookConverter.needsConversion(format: $0.format) }.count
    }

    // MARK: - Body

    var body: some View {
        content
            .background { ThemedBackground() }
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .inspector(isPresented: $showInspector) {
                BookDetailPanel(
                    book: primarySelectedBook,
                    multiCount: selection.count,
                    convertibleSelectionCount: convertibleSelectionCount,
                    viewModel: viewModel,
                    actions: bookActions
                )
                .inspectorColumnWidth(min: 240, ideal: 270, max: 360)
            }
            .toolbar {
                LibraryToolbar(
                    viewMode: $viewMode,
                    sortOrder: $sortOrder,
                    showInspector: $showInspector,
                    kindlePresenceFilter: $kindlePresenceFilter,
                    showsKindleFilter: deviceMonitor.isConnected,
                    transmitEnabled: deviceMonitor.isConnected
                        && selectedBooks.contains(where: \.hasDigitalFile)
                        && !transferQueue.isTransferring,
                    onImport: { isImporting = true },
                    onAddPhysicalBook: { activeSheet = .addPhysicalBook },
                    onTransmit: transmitSelected
                )
            }
            .quickLookPreview($quickLookURL)
            .searchable(text: $searchText, prompt: Text(theme.copy.searchPlaceholder))
            .searchFocused($searchFocused)
            .navigationTitle(theme.usesTerminalCopy ? "" : "Library")
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result, !urls.isEmpty {
                    viewModel.addBooks(from: urls)
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .addPhysicalBook:
                    AddPhysicalBookSheet(viewModel: viewModel)
                case .edit(let book):
                    EditMetadataSheet(book: book, viewModel: viewModel)
                case .bulkEdit:
                    BulkEditSheet(
                        bookCount: selectedBooks.count,
                        viewModel: viewModel
                    ) { edit in
                        viewModel.bulkUpdate(selectedBooks, edit)
                    }
                case .metadataFixes:
                    MetadataFixesSheet(viewModel: viewModel)
                case .statistics:
                    StatisticsView(books: books)
                case .highlights:
                    HighlightsView(books: books)
                case .series(let name):
                    SeriesView(
                        books: books,
                        onOpen: { LibraryExternalActions.openInReader($0) },
                        onShowInLibrary: showSeriesInLibrary,
                        seriesName: name
                    )
                case .work(let work):
                    WorkDetailSheet(work: work, viewModel: viewModel, onShowInLibrary: showInLibrary)
                case .editionReview:
                    EditionReviewSheet(books: books, service: viewModel.editions)
                case .bookDoctor(let request):
                    BookDoctorSheet(request: request) { urls in
                        handleBookDoctorProceed(request, urls: urls)
                    }
                case .readingHistory(let book):
                    ReadingHistorySheet(book: book, viewModel: viewModel)
                case .fullTextSearch:
                    FullTextSearchSheet(
                        books: books,
                        onOpen: openBook,
                        onShowInLibrary: showBookInLibrary
                    )
                case .readingRecommendation:
                    ReadingRecommendationSheet(
                        books: books,
                        onOpen: openBook,
                        onShowInLibrary: showBookInLibrary
                    )
                case .readingHistoryImport(let url):
                    ReadingHistoryImportSheet(fileURL: url)
                }
            }
            .alert("Delete \(pendingDeletion.count) books?",
                   isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { deletePending() }
                Button("Cancel", role: .cancel) { pendingDeletion = [] }
            } message: {
                Text("Deleted books are moved to the Trash.")
            }
            .alert("New Collection", isPresented: $showNewCollectionAlert) {
                TextField("Name", text: $newCollectionName)
                Button("Create") {
                    let name = newCollectionName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { viewModel.createCollection(named: name, adding: newCollectionTargets) }
                }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Save Search as Collection", isPresented: $showSaveSearchAlert) {
                TextField("Name", text: $saveSearchName)
                Button("Save") {
                    let name = saveSearchName.trimmingCharacters(in: .whitespaces)
                    let query = searchText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, !query.isEmpty {
                        viewModel.createCollection(named: name, savedSearch: query)
                    }
                }
                Button("Cancel", role: .cancel) { }
            }
            .focusedSceneValue(\.libraryCommandContext, commandContext)
            .onChange(of: commandContext.requestGeneration) {
                performCommand(commandContext.request)
            }
            .onChange(of: commandAvailability, initial: true) { _, availability in
                commandContext.updateAvailability(availability)
            }
            .task(id: searchText) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                debouncedSearch = searchText
            }
            .task(id: displayRevision) {
                await refreshDisplayed(for: displayRevision)
            }
            .onAppear {
                viewMode = LibraryViewMode(rawValue: restoredViewMode) ?? .grid
            }
            .onChange(of: viewMode) { _, mode in
                restoredViewMode = mode.rawValue
            }
            .onChange(of: deviceMonitor.isConnected) { _, isConnected in
                if !isConnected { kindlePresenceFilter = .all }
            }
    }

    private func showInLibrary(_ book: Book) {
        activeSheet = nil
        onShowAll()
        kindlePresenceFilter = .all
        searchText = ""
        debouncedSearch = ""
        selection.selectedBookIDs = [book.id]
        selection.lastClickedBookID = book.id
        Task { @MainActor in
            await Task.yield()
            await refreshDisplayed(for: displayRevision)
            guard !Task.isCancelled, displayed.contains(where: { $0.id == book.id }) else { return }
            scrollTarget = book.id
        }
    }

    private func showSeriesInLibrary(_ name: String) {
        activeSheet = nil
        searchText = ""
        debouncedSearch = ""
        selection.clear()
        onShowSeries(name)
    }

    private func showAuthorInLibrary(_ author: String) {
        activeSheet = nil
        kindlePresenceFilter = .all
        searchText = ""
        debouncedSearch = ""
        onShowAuthor(author)
    }

    // MARK: - Top bar

    @ViewBuilder
    private var topBar: some View {
        LibraryDropZone(isTargeted: $isDropTargeted,
                        onDrop: { LibraryExternalActions.handleDrop(providers: $0, viewModel: viewModel) })
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(.ultraThinMaterial)
    }

    // MARK: - Content (grid or table)

    private var content: some View {
        Group {
            if displayed.isEmpty {
                LibraryEmptyState(kind: emptyStateKind)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewMode == .grid {
                BookGridView(
                    books: displayed,
                    selection: selection,
                    deviceFileNames: deviceMonitor.deviceFileNames,
                    conversion: viewModel.conversion,
                    health: viewModel.health,
                    editions: viewModel.editions,
                    collections: collections,
                    actions: bookActions,
                    onClick: handleBookClick,
                    scrollTarget: $scrollTarget
                )
            } else {
                BookTableView(
                    books: displayed,
                    selection: selection,
                    deviceFileNames: deviceMonitor.deviceFileNames,
                    conversion: viewModel.conversion,
                    editions: viewModel.editions,
                    collections: collections,
                    actions: bookActions,
                    sortOrder: $sortOrder
                )
            }
        }
        .id(contentState)
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: contentState)
    }

    private var emptyStateKind: LibraryEmptyState.Kind {
        if books.isEmpty {
            .emptyLibrary(onImport: { isImporting = true },
                          onImportCalibre: { Task { await LibraryExternalActions.importFromCalibre(via: viewModel) } })
        } else if !searchText.isEmpty {
            .noSearchResults(query: searchText, onClear: { searchText = "" })
        } else {
            .noFilterMatches(onShowAll: {
                kindlePresenceFilter = .all
                onShowAll()
            })
        }
    }

    // MARK: - Menu actions

    private var commandAvailability: LibraryCommandAvailability {
        LibraryCommandAvailability(
            hasSelection: selection.hasSelection,
            canConvert: convertibleSelectionCount > 0,
            canFetchMetadata: viewModel.onlineMetadataEnabled && selection.hasSelection,
            canSaveSearch: !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        )
    }

    private func performCommand(_ command: LibraryCommand?) {
        guard let command else { return }
        switch command {
        case .importBooks:
            isImporting = true
        case .importCalibre:
            Task { await LibraryExternalActions.importFromCalibre(via: viewModel) }
        case .importReadingHistory:
            Task {
                guard let url = await LibraryExternalActions.chooseReadingHistoryExport() else { return }
                activeSheet = .readingHistoryImport(url)
            }
        case .openInReader:
            if let book = primarySelectedBook { LibraryExternalActions.openInReader(book) }
        case .quickLook:
            if let book = primarySelectedBook { quickLookURL = book.primaryFileURL }
        case .showInFinder:
            if let book = primarySelectedBook { LibraryExternalActions.showInFinder(book) }
        case .editMetadata:
            if selection.count > 1 { activeSheet = .bulkEdit }
            else if let book = primarySelectedBook { activeSheet = .edit(book) }
        case .deleteSelected:
            if selection.hasSelection {
                pendingDeletion = selectedBooks
                showDeleteConfirm = true
            }
        case .selectAll:
            selection.selectAll(displayed)
        case .toggleSidebar:
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        case .toggleInspector:
            showInspector.toggle()
        case .setGridView:
            viewMode = .grid
        case .setListView:
            viewMode = .table
        case .focusSearch:
            searchFocused = true
        case .convertSelected:
            convertSelectedBooks()
        case .fetchMetadata:
            viewModel.fetchOnlineMetadata(for: selectedBooks)
        case .showMetadataFixes:
            activeSheet = .metadataFixes
        case .reviewEditions:
            activeSheet = .editionReview
        case .showStatistics:
            activeSheet = .statistics
        case .showHighlights:
            activeSheet = .highlights
        case .showSeries:
            activeSheet = .series(name: nil)
        case .searchInsideBooks:
            activeSheet = .fullTextSearch
        case .exportLibrary:
            Task { await LibraryExternalActions.exportLibrary(via: viewModel) }
        case .saveSearchAsCollection:
            saveSearchName = ""
            showSaveSearchAlert = true
        case .recommendReading:
            activeSheet = .readingRecommendation
        case .markSelection(let status):
            viewModel.setReadingStatus(status, for: selectedBooks)
        case .replaceSelected:
            if let book = primarySelectedBook {
                Task { await LibraryExternalActions.relink(book, via: viewModel) }
            }
        case .inspectSelected:
            presentBookDoctor(for: selectedBooks, purpose: .review)
        }
    }

    private func convertSelectedBooks() {
        viewModel.convertBooks(selectedBooks)
    }

    private func openBook(_ bookID: UUID) {
        guard let book = books.first(where: { $0.uuid == bookID }) else { return }
        LibraryExternalActions.openInReader(book)
    }

    private func showBookInLibrary(_ bookID: UUID) {
        guard let book = books.first(where: { $0.uuid == bookID }) else { return }
        showInLibrary(book)
    }

    private func handleBookClick(book: Book) {
        let fresh = selection.handleClick(on: book, in: displayed)
        if fresh && !showInspector { showInspector = true }
    }

    private func transmitSelected() {
        let toSend = books.filter { selection.selectedBookIDs.contains($0.id) && $0.hasDigitalFile }
        guard !toSend.isEmpty else { return }
        if settings.inspectBeforeKindleTransfer {
            presentBookDoctor(for: toSend, purpose: .sendToKindle)
        } else {
            transferQueue.beginSend(books: toSend, via: deviceMonitor)
        }
    }

    private func presentBookDoctor(for books: [Book], purpose: BookDoctorRequest.Purpose) {
        let sources = books.compactMap { book in
            book.primaryFileURL.map { BookDoctorSource(id: book.uuid, title: book.displayTitle, url: $0) }
        }
        guard !sources.isEmpty else { return }
        activeSheet = .bookDoctor(BookDoctorRequest(sources: sources, purpose: purpose))
    }

    private func handleBookDoctorProceed(_ request: BookDoctorRequest, urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch request.purpose {
        case .sendToKindle:
            let paths = Set(urls.map { $0.standardizedFileURL.path(percentEncoded: false) })
            let ready = books.filter { book in
                guard let url = book.primaryFileURL else { return false }
                return paths.contains(url.standardizedFileURL.path(percentEncoded: false))
            }
            if !ready.isEmpty { transferQueue.beginSend(books: ready, via: deviceMonitor) }
        case .review:
            break
        }
    }

    private func deletePending() {
        let toDelete = pendingDeletion.filter { $0.modelContext != nil }
        pendingDeletion = []
        guard !toDelete.isEmpty else { return }
        animateNextDisplayChange = viewMode == .grid
        Task { await viewModel.removeBooks(toDelete) }
        toDelete.forEach { selection.remove($0.id) }
    }

    private func refreshDisplayed(for revision: DisplayRevision) async {
        let snapshots: [LibraryDisplaySnapshot]
        if displaySnapshotRevision == revision.snapshot {
            snapshots = displaySnapshots
        } else {
            let signposter = Log.librarySignposter
            let interval = signposter.beginInterval("LibrarySnapshot")
            defer { signposter.endInterval("LibrarySnapshot", interval) }
            var updated: [LibraryDisplaySnapshot] = []
            updated.reserveCapacity(books.count)
            for (index, book) in books.enumerated() {
                updated.append(
                    LibraryDisplaySnapshot(
                        book,
                        sourceOrdinal: index,
                        includeCollections: revision.snapshot.includeCollections,
                        includeHighlights: revision.snapshot.includeHighlights
                    )
                )
                if (index + 1).isMultiple(of: 512) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                }
            }
            displaySnapshots = updated
            displaySnapshotRevision = revision.snapshot
            snapshots = updated
        }

        if let smartShelf = revision.smartShelf,
           smartShelf.savedSearch == nil,
           smartShelf.definition == nil {
            displayed = []
            return
        }

        let signposter = Log.librarySignposter
        let queryInterval = signposter.beginInterval("LibraryFilterAndSort")
        let ids = await LibraryQuery.displayIDsConcurrently(
            for: snapshots,
            filter: revision.filter,
            searchText: revision.searchText,
            sort: revision.sort,
            savedSearch: revision.smartShelf?.savedSearch,
            smartShelf: revision.smartShelf?.definition,
            deviceFileNames: revision.deviceFileNames,
            deviceIsConnected: revision.deviceIsConnected,
            kindlePresenceFilter: revision.kindlePresenceFilter
        )
        signposter.endInterval("LibraryFilterAndSort", queryInterval)
        guard !Task.isCancelled, displayRevision == revision else { return }

        let booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.uuid, $0) })
        let updated = ids.compactMap { booksByID[$0] }
        if animateNextDisplayChange {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                displayed = updated
            }
            animateNextDisplayChange = false
        } else {
            displayed = updated
        }
    }

    private func deleteFromDevice(_ booksToRemove: [Book]) {
        let keys = Set(booksToRemove.flatMap(\.deviceMatchKeys))
            .intersection(deviceMonitor.deviceFileNames)
        guard !keys.isEmpty else { return }
        Task {
            let count = await deviceMonitor.removeFromDevice(matching: keys)
            if count > 0 { toasts.success(String(localized: "Removed \(count) from Kindle.")) }
        }
    }
}

// MARK: - Previews

#Preview("Idle") {
    let container = PersistenceController.inMemory()
    NavigationStack {
        LibraryView(
            books: [],
            collections: [],
            viewModel: LibraryViewModel(modelContext: container.mainContext, settings: AppSettings(), toasts: ToastCenter()),
            filter: .all,
            onShowAll: {},
            onShowAuthor: { _ in },
            onShowSeries: { _ in },
            columnVisibility: .constant(.all),
            activeSheet: .constant(nil)
        )
    }
    .modelContainer(container)
    .environment(DeviceMonitor())
    .environment(KindleSyncProfileStore())
    .environment(TransferQueue(toasts: ToastCenter()))
    .environment(ToastCenter())
    .environment(AppSettings())
    .frame(width: 980, height: 640)
}
