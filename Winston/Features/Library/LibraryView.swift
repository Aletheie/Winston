import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import QuickLook

enum LibrarySheet: Identifiable {
    case edit(Book)
    case bulkEdit
    case duplicates
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
        case .edit(let book): "edit-\(book.uuid.uuidString)"
        case .bulkEdit:       "bulkEdit"
        case .duplicates:     "duplicates"
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
    let onShowSeries: (String) -> Void
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var activeSheet: LibrarySheet?

    @Environment(\.theme) private var theme
    @Environment(DeviceMonitor.self) private var deviceMonitor
    @Environment(TransferQueue.self) private var transferQueue
    @Environment(ToastCenter.self) private var toasts

    @FocusState private var searchFocused: Bool
    @State private var selection = BookSelectionModel()
    @State private var isDropTargeted = false
    @State private var isImporting = false
    @State private var viewMode: LibraryViewMode = .grid
    @State private var showInspector = true
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var displayed: [Book] = []
    @State private var sortOrder: [KeyPathComparator<Book>] = [BookSort.dateAdded.comparator(ascending: false)]
    @State private var showDeleteConfirm = false
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

    private func recomputeDisplayed() {
        if case .collection(let id) = filter,
           let smart = collections.first(where: { $0.id == id && $0.isSmart }) {
            if let definition = smart.smartShelfDefinition {
                let shelfBooks = LibraryQuery.applySmartShelf(
                    to: books,
                    definition: definition,
                    deviceFileNames: deviceMonitor.deviceFileNames,
                    deviceIsConnected: deviceMonitor.isConnected,
                    sort: sortOrder
                )
                displayed = LibraryQuery.apply(
                    to: shelfBooks,
                    filter: .all,
                    searchText: debouncedSearch,
                    sort: sortOrder
                )
            } else if let search = smart.savedSearch {
                let shelfBooks = LibraryQuery.apply(
                    to: books,
                    filter: .all,
                    searchText: search,
                    sort: sortOrder
                )
                displayed = LibraryQuery.apply(
                    to: shelfBooks,
                    filter: .all,
                    searchText: debouncedSearch,
                    sort: sortOrder
                )
            } else {
                displayed = []
            }
        } else {
            displayed = LibraryQuery.apply(to: books, filter: filter, searchText: debouncedSearch, sort: sortOrder)
        }
    }

    private var bookActions: BookActions {
        BookActions(
            open: { LibraryExternalActions.openInReader($0) },
            openWork: { activeSheet = .work($0) },
            openSeries: { activeSheet = .series(name: $0) },
            quickLook: { quickLookURL = $0.fileURL },
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
            resetCover: { book in viewModel.resetCover(for: book) },
            relink: { book in Task { await LibraryExternalActions.relink(book, via: viewModel) } },
            inspect: { book in presentBookDoctor(for: [book], purpose: .review) },
            convert: { book in viewModel.convert(book) },
            convertTo: { book, format in viewModel.convert(book, to: format) },
            convertSelection: convertSelectedBooks,
            convertSelectionTo: { format in viewModel.convertBooks(selectedBooks, to: format) },
            delete: { book in
                viewModel.remove(book)
                selection.remove(book.id)
            },
            deleteSelection: { showDeleteConfirm = true },
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
        selectedBooks.filter { EbookConverter.needsConversion(format: $0.format) }.count
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
                    transmitEnabled: deviceMonitor.isConnected && selection.hasSelection && !transferQueue.isTransferring,
                    onImport: { isImporting = true },
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
                    let sources = urls.map { BookDoctorSource(title: $0.lastPathComponent, url: $0) }
                    activeSheet = .bookDoctor(BookDoctorRequest(sources: sources, purpose: .importFiles))
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .edit(let book):
                    EditMetadataSheet(book: book, viewModel: viewModel)
                case .bulkEdit:
                    BulkEditSheet(
                        bookCount: selectedBooks.count,
                        viewModel: viewModel
                    ) { edit in
                        viewModel.bulkUpdate(selectedBooks, edit)
                    }
                case .duplicates:
                    DuplicatesSheet(viewModel: viewModel, onReviewEditions: { activeSheet = .editionReview })
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
            .alert("Delete \(selection.count) books?",
                   isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) { }
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
            .onChange(of: LibraryMutationLog.shared.revision, initial: true) { recomputeDisplayed() }
            .onChange(of: filter) { recomputeDisplayed() }
            .onChange(of: debouncedSearch) { recomputeDisplayed() }
            .onChange(of: sortOrder) { recomputeDisplayed() }
            .onChange(of: deviceMonitor.deviceFileNames) { recomputeDisplayed() }
            .onChange(of: deviceMonitor.isConnected) { recomputeDisplayed() }
    }

    private func showInLibrary(_ book: Book) {
        activeSheet = nil
        onShowAll()
        searchText = ""
        debouncedSearch = ""
        displayed = LibraryQuery.apply(to: books, filter: .all, searchText: "", sort: sortOrder)
        selection.selectedBookIDs = [book.id]
        selection.lastClickedBookID = book.id
        Task { @MainActor in
            await Task.yield()
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

    // MARK: - Top bar (drop zone + transfer status)

    @ViewBuilder
    private var topBar: some View {
        VStack(spacing: 0) {
            LibraryDropZone(isTargeted: $isDropTargeted,
                            onDrop: { LibraryExternalActions.handleDrop(providers: $0, viewModel: viewModel) })
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Content (grid or table)

    @ViewBuilder
    private var content: some View {
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

    private var emptyStateKind: LibraryEmptyState.Kind {
        if books.isEmpty {
            .emptyLibrary(onImport: { isImporting = true },
                          onImportCalibre: { Task { await LibraryExternalActions.importFromCalibre(via: viewModel) } })
        } else if !searchText.isEmpty {
            .noSearchResults(query: searchText, onClear: { searchText = "" })
        } else {
            .noFilterMatches(onShowAll: onShowAll)
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
            if let book = primarySelectedBook { quickLookURL = book.fileURL }
        case .showInFinder:
            if let book = primarySelectedBook { LibraryExternalActions.showInFinder(book) }
        case .editMetadata:
            if selection.count > 1 { activeSheet = .bulkEdit }
            else if let book = primarySelectedBook { activeSheet = .edit(book) }
        case .deleteSelected:
            if selection.hasSelection { showDeleteConfirm = true }
        case .selectAll:
            selection.selectAll(displayed)
        case .toggleSidebar:
            withAnimation { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
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
        case .findDuplicates:
            activeSheet = .duplicates
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
        let toSend = books.filter { selection.selectedBookIDs.contains($0.id) }
        guard !toSend.isEmpty else { return }
        presentBookDoctor(for: toSend, purpose: .sendToKindle)
    }

    private func presentBookDoctor(for books: [Book], purpose: BookDoctorRequest.Purpose) {
        guard !books.isEmpty else { return }
        let sources = books.map {
            BookDoctorSource(id: $0.uuid, title: $0.displayTitle, url: $0.fileURL)
        }
        activeSheet = .bookDoctor(BookDoctorRequest(sources: sources, purpose: purpose))
    }

    private func handleBookDoctorProceed(_ request: BookDoctorRequest, urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch request.purpose {
        case .importFiles:
            viewModel.addBooks(from: urls)
        case .sendToKindle:
            let paths = Set(urls.map { $0.standardizedFileURL.path(percentEncoded: false) })
            let ready = books.filter { paths.contains($0.fileURL.standardizedFileURL.path(percentEncoded: false)) }
            if !ready.isEmpty { transferQueue.beginSend(books: ready, via: deviceMonitor) }
        case .review:
            break
        }
    }

    private func deleteSelected() {
        let toDelete = books.filter { selection.selectedBookIDs.contains($0.id) }
        viewModel.removeBooks(toDelete)
        selection.clear()
    }

    private func deleteFromDevice(_ booksToRemove: [Book]) {
        let keys = Set(booksToRemove.map(\.deviceMatchKey))
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
