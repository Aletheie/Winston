import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import QuickLook
import OSLog

enum LibrarySheet: Identifiable {
    case addPhysicalBook
    case edit(Book)
    case bulkEdit(Set<UUID>)
    case libraryIntegrity
    case importRecovery
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
        case .bulkEdit(let ids): "bulkEdit-\(ids.count)-\(ids.hashValue)"
        case .libraryIntegrity: "libraryIntegrity"
        case .importRecovery: "importRecovery"
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
    var readModel: LibraryReadModel
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
    @State private var displayedIDs: [UUID] = []
    @State private var displayedReadModelGeneration = 0
    @State private var displayedQuery: LibraryQuerySpec?
    @State private var animateNextDisplayChange = false
    @State private var sortOrder: [KeyPathComparator<Book>] = [BookSort.dateAdded.comparator(ascending: false)]
    @State private var showDeleteConfirm = false
    @State private var pendingDeletion: [Book] = []
    @State private var pendingDeletionPlan: BulkOperationPlan?
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
        let id = selection.lastClickedBookID.flatMap {
            selection.selectedBookIDs.contains($0) ? $0 : nil
        } ?? selection.selectedBookIDs.first
        return readModel.book(id: id)
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
        let readModelGeneration: Int
        let readModelIsReady: Bool
        let query: LibraryQuerySpec
        let hasInvalidSmartShelf: Bool
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
        return DisplayRevision(
            readModelGeneration: readModel.generation,
            readModelIsReady: readModel.isReady,
            query: LibraryQuerySpec(
                filter: filter,
                searchText: debouncedSearch,
                sort: LibraryQuery.displaySort(for: sortOrder),
                savedSearch: smartShelf?.savedSearch,
                smartShelf: smartShelf?.definition,
                deviceFileNames: deviceMonitor.deviceFileNames,
                deviceIsConnected: deviceMonitor.isConnected,
                kindlePresenceFilter: kindlePresenceFilter
            ),
            hasInvalidSmartShelf: smartShelf != nil
                && smartShelf?.savedSearch == nil
                && smartShelf?.definition == nil
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
            editSelection: {
                activeSheet = .bulkEdit(Set(selectedBooks.map(\.uuid)))
            },
            fetchMetadata: { book in viewModel.fetchOnlineMetadata(for: book) },
            fetchMetadataSelection: { viewModel.fetchOnlineMetadata(for: selectedBooks) },
            setStatus: { book, status in
                let ids = Set(targetBooks(for: book).map(\.uuid))
                Task { await viewModel.setReadingStatus(status, bookIDs: ids) }
            },
            readingHistory: { activeSheet = .readingHistory($0) },
            addToCollection: { book, collection in
                let ids = Set(targetBooks(for: book).map(\.uuid))
                Task { await viewModel.add(bookIDs: ids, to: collection) }
            },
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
                prepareDeletion([book])
            },
            deleteSelection: {
                prepareDeletion(selectedBooks)
            },
            removeFromDevice: { book in deleteFromDevice(targetBooks(for: book)) },
            removeSelectionFromDevice: { deleteFromDevice(selectedBooks) }
        )
    }

    private var selectedBooks: [Book] {
        readModel.selectedBooks(for: selection.selectedBookIDs)
    }

    private func targetBooks(for book: Book) -> [Book] {
        (selection.count > 1 && selection.isSelected(book)) ? selectedBooks : [book]
    }

    private var convertibleSelectionCount: Int {
        selectedBooks.filter {
            $0.hasCatalogDigitalFile && EbookConverter.needsConversion(format: $0.format)
        }.count
    }

    // MARK: - Body

    var body: some View {
        let _ = LibraryPerformanceDiagnostics.recordBody("LibraryViewBody")
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
                        && selectedBooks.contains(where: \.hasCatalogDigitalFile)
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
                case .bulkEdit(let bookIDs):
                    BulkEditSheet(
                        bookIDs: bookIDs,
                        viewModel: viewModel
                    ) { edit in
                        Task {
                            await viewModel.bulkUpdate(bookIDs: bookIDs, edit: edit)
                        }
                    }
                case .libraryIntegrity:
                    LibraryIntegritySheet(
                        viewModel: viewModel,
                        onShowBook: showBookInLibrary,
                        onReviewMetadata: {
                            presentAfterDismissingSheet(.metadataFixes)
                        },
                        onOpenRecovery: {
                            presentAfterDismissingSheet(.importRecovery)
                        }
                    )
                case .importRecovery:
                    ImportRecoverySheet(viewModel: viewModel)
                case .metadataFixes:
                    MetadataFixesSheet(viewModel: viewModel)
                case .statistics:
                    StatisticsView(books: books)
                case .highlights:
                    HighlightsView()
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
                        readModel: readModel,
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
            .alert("Delete \(pendingDeletionPlan?.affectedTargetCount ?? pendingDeletion.count) books?",
                   isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { deletePending() }
                    .disabled(pendingDeletionPlan?.affectedTargetCount == 0)
                Button("Cancel", role: .cancel) {
                    pendingDeletion = []
                    pendingDeletionPlan = nil
                }
            } message: {
                DeleteBooksPlanMessage(plan: pendingDeletionPlan)
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
        if readModel.bookCount == 0 {
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
            if selection.count > 1 {
                activeSheet = .bulkEdit(Set(selectedBooks.map(\.uuid)))
            }
            else if let book = primarySelectedBook { activeSheet = .edit(book) }
        case .deleteSelected:
            if selection.hasSelection {
                prepareDeletion(selectedBooks)
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
        case .showLibraryIntegrity:
            activeSheet = .libraryIntegrity
        case .showImportRecovery:
            activeSheet = .importRecovery
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
            let ids = Set(selectedBooks.map(\.uuid))
            Task { await viewModel.setReadingStatus(status, bookIDs: ids) }
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
        guard let book = readModel.book(uuid: bookID) else { return }
        LibraryExternalActions.openInReader(book)
    }

    private func showBookInLibrary(_ bookID: UUID) {
        guard let book = readModel.book(uuid: bookID) else { return }
        showInLibrary(book)
    }

    private func presentAfterDismissingSheet(_ sheet: LibrarySheet) {
        activeSheet = nil
        Task { @MainActor in
            await Task.yield()
            activeSheet = sheet
        }
    }

    private func handleBookClick(book: Book) {
        let fresh = selection.handleClick(on: book, in: displayed)
        if fresh && !showInspector { showInspector = true }
    }

    private func transmitSelected() {
        let toSend = selectedBooks
        guard !toSend.isEmpty else { return }
        if settings.inspectBeforeKindleTransfer {
            presentBookDoctor(for: toSend, purpose: .sendToKindle)
        } else {
            beginTransferFromReadModel(bookIDs: toSend.map(\.uuid))
        }
    }

    private func beginTransferFromReadModel(bookIDs: [UUID]) {
        Task {
            if let descriptors = await readModel.kindleTransferDescriptors(
                for: bookIDs
            ) {
                guard !descriptors.isEmpty else { return }
                transferQueue.beginSend(
                    readModel: descriptors,
                    via: deviceMonitor
                )
            } else {
                let fallbackBooks = readModel.books(for: bookIDs)
                guard !fallbackBooks.isEmpty else { return }
                transferQueue.beginSend(
                    books: fallbackBooks,
                    via: deviceMonitor
                )
            }
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
            if !ready.isEmpty {
                beginTransferFromReadModel(bookIDs: ready.map(\.uuid))
            }
        case .review:
            break
        }
    }

    private func deletePending() {
        let toDelete = pendingDeletion
        let bookIDs = Set(toDelete.map(\.uuid))
        pendingDeletion = []
        pendingDeletionPlan = nil
        guard !bookIDs.isEmpty else { return }
        animateNextDisplayChange = viewMode == .grid
        Task { await viewModel.removeBooks(bookIDs: bookIDs) }
        toDelete.forEach { selection.remove($0.id) }
    }

    private func prepareDeletion(_ books: [Book]) {
        var seen: Set<UUID> = []
        let stableBooks = books.filter { seen.insert($0.uuid).inserted }
        let bookIDs = Set(stableBooks.map(\.uuid))
        guard !bookIDs.isEmpty else { return }
        pendingDeletion = stableBooks
        pendingDeletionPlan = nil
        Task {
            let plan = await viewModel.planRemoval(bookIDs: bookIDs)
            guard Set(pendingDeletion.map(\.uuid)) == bookIDs else { return }
            pendingDeletionPlan = plan
            showDeleteConfirm = true
        }
    }

    private func refreshDisplayed(for revision: DisplayRevision) async {
        if revision.hasInvalidSmartShelf {
            displayedIDs = []
            displayed = []
            displayedReadModelGeneration = revision.readModelGeneration
            displayedQuery = revision.query
            return
        }

        let signposter = Log.librarySignposter
        let delta = readModel.displayDelta(since: displayedReadModelGeneration)
        let ids: [UUID]
        let requiresBookResolution: Bool
        let resultGeneration: Int
        if displayedQuery == revision.query,
           let incremental = readModel.incrementallyUpdatingDisplayIDs(
               displayedIDs,
               with: delta,
               query: revision.query
           ) {
            let interval = signposter.beginInterval("LibraryFilterAndSortIncremental")
            ids = incremental.ids
            requiresBookResolution = incremental.changed
            resultGeneration = revision.readModelGeneration
            signposter.endInterval("LibraryFilterAndSortIncremental", interval)
        } else {
            let interval = signposter.beginInterval("LibraryFilterAndSort")
            let result = await readModel.query(revision.query)
            ids = result.ids
            resultGeneration = result.generation
            requiresBookResolution = true
            signposter.endInterval("LibraryFilterAndSort", interval)
        }
        guard !Task.isCancelled,
              resultGeneration == revision.readModelGeneration,
              displayRevision == revision else { return }

        displayedIDs = ids
        displayedReadModelGeneration = revision.readModelGeneration
        displayedQuery = revision.query
        guard requiresBookResolution else { return }

        let updated = readModel.books(for: ids)
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
        let deviceBookIDs = Set(deviceMonitor.books.lazy
            .filter { keys.contains($0.matchKey) }
            .map(\.id))
        guard !deviceBookIDs.isEmpty else { return }
        Task {
            let result = await deviceMonitor.removeFromDevice(ids: deviceBookIDs)
            if result.appliedTargetCount > 0 {
                toasts.success(String(
                    localized: "Removed \(result.appliedTargetCount) from Kindle."
                ))
            }
            if result.completion == .failed || result.conflictCount > 0 {
                toasts.error(String(
                    localized: "Some books couldn’t be deleted from the Kindle (\(result.conflictCount + result.pendingTargetIDs.count))."
                ))
            }
        }
    }
}

private struct DeleteBooksPlanMessage: View {
    let plan: BulkOperationPlan?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Deleted books are moved to the Trash.")
            if let plan, plan.conflictCount > 0 {
                Text("\(plan.conflictCount) selected books can’t be deleted.")
            }
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
            readModel: LibraryReadModel(),
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
