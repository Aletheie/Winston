import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import QuickLook

enum LibrarySheet: Identifiable {
    case edit(Book)
    case bulkEdit
    case duplicates
    case statistics
    case highlights
    case series

    var id: String {
        switch self {
        case .edit(let book): "edit-\(book.uuid.uuidString)"
        case .bulkEdit:       "bulkEdit"
        case .duplicates:     "duplicates"
        case .statistics:     "statistics"
        case .highlights:     "highlights"
        case .series:         "series"
        }
    }
}

struct LibraryView: View {
    var books: [Book]
    var collections: [BookCollection]
    var viewModel: LibraryViewModel
    let filter: LibraryFilter
    let onShowAll: () -> Void
    @Binding var columnVisibility: NavigationSplitViewVisibility

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
    @State private var activeSheet: LibrarySheet?
    @State private var showDeleteConfirm = false
    @State private var quickLookURL: URL?
    @State private var showNewCollectionAlert = false
    @State private var newCollectionName = ""
    @State private var newCollectionTargets: [Book] = []
    @State private var showSaveSearchAlert = false
    @State private var saveSearchName = ""
    @State private var scrollTarget: Book.ID?

    // MARK: - Derived state

    private var primarySelectedBook: Book? {
        selection.primaryBook(in: books)
    }

    private func recomputeDisplayed() {
        if case .collection(let id) = filter,
           let smart = collections.first(where: { $0.id == id && $0.isSmart }),
           let search = smart.savedSearch {
            displayed = LibraryQuery.apply(to: books, filter: .all, searchText: search, sort: sortOrder)
        } else {
            displayed = LibraryQuery.apply(to: books, filter: filter, searchText: debouncedSearch, sort: sortOrder)
        }
    }

    private var bookActions: BookActions {
        BookActions(
            open: { LibraryExternalActions.openInReader($0) },
            quickLook: { quickLookURL = $0.fileURL },
            showInFinder: { LibraryExternalActions.showInFinder($0) },
            edit: { activeSheet = .edit($0) },
            editSelection: { activeSheet = .bulkEdit },
            fetchMetadata: { book in viewModel.fetchOnlineMetadata(for: book) },
            fetchMetadataSelection: { viewModel.fetchOnlineMetadata(for: selectedBooks) },
            setStatus: { book, status in viewModel.setReadingStatus(status, for: targetBooks(for: book)) },
            addToCollection: { book, collection in viewModel.add(targetBooks(for: book), to: collection) },
            newCollection: { book in
                newCollectionTargets = targetBooks(for: book)
                newCollectionName = ""
                showNewCollectionAlert = true
            },
            setCover: { book, url in viewModel.setCustomCover(for: book, from: url) },
            resetCover: { book in viewModel.resetCover(for: book) },
            relink: { book in Task { await LibraryExternalActions.relink(book, via: viewModel) } },
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
                if case .success(let urls) = result { viewModel.addBooks(from: urls) }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .edit(let book):
                    EditMetadataSheet(book: book, viewModel: viewModel)
                case .bulkEdit:
                    BulkEditSheet(bookCount: selectedBooks.count) { edit in
                        viewModel.bulkUpdate(selectedBooks, edit)
                    }
                case .duplicates:
                    DuplicatesSheet(viewModel: viewModel)
                case .statistics:
                    StatisticsView(books: books)
                case .highlights:
                    HighlightsView(books: books)
                case .series:
                    SeriesView(books: books, onOpen: { LibraryExternalActions.openInReader($0) })
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
            .focusedSceneValue(\.libraryActions, libraryActions)
            .task(id: searchText) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                debouncedSearch = searchText
            }
            .onChange(of: LibraryMutationLog.shared.revision, initial: true) { recomputeDisplayed() }
            .onChange(of: filter) { recomputeDisplayed() }
            .onChange(of: debouncedSearch) { recomputeDisplayed() }
            .onChange(of: sortOrder) { recomputeDisplayed() }
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

    private var libraryActions: LibraryActions {
        LibraryActions(
            importBooks: { isImporting = true },
            importCalibre: { Task { await LibraryExternalActions.importFromCalibre(via: viewModel) } },
            openInReader: { if let b = primarySelectedBook { LibraryExternalActions.openInReader(b) } },
            quickLook: { if let b = primarySelectedBook { quickLookURL = b.fileURL } },
            showInFinder: { if let b = primarySelectedBook { LibraryExternalActions.showInFinder(b) } },
            editMetadata: {
                if selection.count > 1 { activeSheet = .bulkEdit }
                else if let b = primarySelectedBook { activeSheet = .edit(b) }
            },
            deleteSelected: { if selection.hasSelection { showDeleteConfirm = true } },
            selectAll: { selection.selectAll(displayed) },
            toggleSidebar: { withAnimation { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly } },
            toggleInspector: { showInspector.toggle() },
            setGridView: { viewMode = .grid },
            setListView: { viewMode = .table },
            focusSearch: { searchFocused = true },
            convertSelected: convertSelectedBooks,
            fetchMetadata: { viewModel.fetchOnlineMetadata(for: selectedBooks) },
            findDuplicates: { activeSheet = .duplicates },
            showStatistics: { activeSheet = .statistics },
            showHighlights: { activeSheet = .highlights },
            showSeries: { activeSheet = .series },
            exportLibrary: { Task { await LibraryExternalActions.exportLibrary(via: viewModel) } },
            saveSearchAsCollection: { saveSearchName = ""; showSaveSearchAlert = true },
            surpriseMe: surpriseMe,
            markSelection: { status in viewModel.setReadingStatus(status, for: selectedBooks) },
            replaceSelected: { if let book = primarySelectedBook { Task { await LibraryExternalActions.relink(book, via: viewModel) } } },
            hasSelection: selection.hasSelection,
            canConvert: convertibleSelectionCount > 0,
            canFetchMetadata: viewModel.onlineMetadataEnabled && selection.hasSelection,
            canSaveSearch: !searchText.trimmingCharacters(in: .whitespaces).isEmpty,
            selectedCount: selection.count
        )
    }

    private func convertSelectedBooks() {
        viewModel.convertBooks(selectedBooks)
    }

    private func surpriseMe() {
        guard let pick = books.filter({ $0.readingStatus == .unread }).randomElement() else { return }
        onShowAll()
        searchText = ""
        debouncedSearch = ""
        displayed = LibraryQuery.apply(to: books, filter: .all, searchText: "", sort: sortOrder)
        selection.selectedBookIDs = [pick.id]
        selection.lastClickedBookID = pick.id
        if !showInspector { showInspector = true }
        Task { @MainActor in
            await Task.yield()
            scrollTarget = pick.id
        }
    }

    private func handleBookClick(book: Book) {
        let fresh = selection.handleClick(on: book, in: displayed)
        if fresh && !showInspector { showInspector = true }
    }

    private func transmitSelected() {
        let toSend = books.filter { selection.selectedBookIDs.contains($0.id) }
        guard !toSend.isEmpty else { return }
        transferQueue.beginSend(books: toSend, via: deviceMonitor)
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
            columnVisibility: .constant(.all)
        )
    }
    .modelContainer(container)
    .environment(DeviceMonitor())
    .environment(TransferQueue(toasts: ToastCenter()))
    .environment(ToastCenter())
    .environment(AppSettings())
    .frame(width: 980, height: 640)
}
