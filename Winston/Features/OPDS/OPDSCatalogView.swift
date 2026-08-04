import SwiftData
import SwiftUI

struct OPDSCatalogView: View {
    let library: LibraryViewModel
    let readModel: LibraryReadModel

    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings
    @Environment(OPDSViewModel.self) private var viewModel

    @State private var searchText = ""
    @State private var selectedResultID: String?
    @State private var expandedResultIDs: Set<String> = []
    @State private var selectedCatalogFilter: String?
    @State private var selectedLanguageFilter: String?
    @State private var selectedFormatFilter: String?
    @State private var selectedRelationFilter:
        OPDSAcquisitionRelation?
    @State private var hidesOwned = false
    @State private var commandContext = CatalogCommandContext()
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(WinstonLayout.dividerOpacity)
            content
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
        }
        .toolbar {
            OPDSCatalogToolbar(
                viewModel: viewModel,
                showsSettings: viewModel.selectedCatalog == nil
            ) {
                searchText = ""
                viewModel.goBack()
            }
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text(
                viewModel.selectedCatalog == nil
                    ? "Search enabled catalogs"
                    : "Search this catalog"
            )
        )
        .searchFocused($searchIsFocused)
        .onSubmit(of: .search, submitSearch)
        .onChange(of: viewModel.selectedCatalog) { _, _ in
            searchText = ""
        }
        .onChange(of: searchText) { oldValue, newValue in
            guard !oldValue.isEmpty, newValue.isEmpty else { return }
            viewModel.clearSearch()
        }
        .onChange(of: settings.onlineMetadataEnabled) { _, _ in
            viewModel.onlineSettingDidChange()
        }
        .onChange(of: viewModel.activeSearchSeed) { _, seed in
            guard let seed else { return }
            searchText = seed.query
            submitUnifiedSearch()
        }
        .focusedSceneValue(\.catalogCommandContext, commandContext)
        .onChange(of: commandContext.focusSearchGeneration) {
            searchIsFocused = true
        }
        .onKeyPress(.escape) {
            guard viewModel.isSearching else { return .ignored }
            viewModel.cancelSearch()
            return .handled
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .top
        )
        .background(ThemedBackground())
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let catalog = viewModel.selectedCatalog {
                    Text(verbatim: viewModel.feed?.title ?? catalog.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(
                            verbatim: viewModel.feed?.subtitle
                                ?? catalog.rootURL.host()
                                ?? catalog.name
                        )
                        if let format = viewModel.feed?.documentFormat {
                            Text(verbatim: documentFormatLabel(format))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    theme.surface,
                                    in: Capsule()
                                )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                } else {
                    theme.styledText(
                        terminal: "// catalog_hub",
                        native: "Catalog Hub"
                    )
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityIdentifier("opds.title")
                    Text(
                        "Search every enabled catalog or open one to browse its shelves."
                    )
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                }
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.selectedCatalog == nil {
            hubContent
        } else {
            browseContent
        }
    }

    @ViewBuilder
    private var hubContent: some View {
        if !settings.onlineMetadataEnabled {
            OPDSUnavailableView(
                title: "Catalogs are offline",
                systemImage: "wifi.slash",
                description: String(
                    localized: "Turn on online metadata in Settings to browse and search OPDS catalogs."
                )
            ) {
                SettingsLink { Text("Open Settings") }
            }
        } else if viewModel.catalogs.isEmpty {
            OPDSUnavailableView(
                title: "No catalogs configured",
                systemImage: "books.vertical",
                description: String(
                    localized: "Add an OPDS catalog in Settings to begin."
                )
            ) {
                SettingsLink { Text("Add Catalog") }
            }
        } else {
            HSplitView {
                catalogList
                    .frame(
                        minWidth: 240,
                        idealWidth: 290,
                        maxWidth: 360,
                        maxHeight: .infinity,
                        alignment: .top
                    )
                searchSurface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var catalogList: some View {
        List {
            Section {
                ForEach(viewModel.catalogs) { catalog in
                    CatalogListRow(
                        catalog: catalog,
                        searchState: viewModel.searchStates[catalog.id]
                    ) {
                        Task { await viewModel.open(catalog) }
                    }
                }
            } header: {
                HStack {
                    Text("Catalogs")
                    Spacer()
                    Text("\(viewModel.enabledCatalogs.count) enabled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("opds.catalogList")
    }

    @ViewBuilder
    private var searchSurface: some View {
        if viewModel.searchStates.isEmpty {
            ContentUnavailableView {
                Label(
                    "Search your catalogs",
                    systemImage: "books.vertical.circle"
                )
            } description: {
                Text(
                    "Enter a title, author, or ISBN. Winston searches only enabled catalogs and keeps every source and format visible."
                )
            }
        } else if viewModel.searchGroups.isEmpty,
                  viewModel.isSearching {
            VStack(spacing: 16) {
                ProgressView(
                    value: Double(viewModel.searchCompletedCount),
                    total: Double(max(1, viewModel.searchRequestedCount))
                )
                .frame(width: 280)
                Text(
                    "Searching \(viewModel.searchCompletedCount) of \(viewModel.searchRequestedCount) catalogs…"
                )
                .font(theme.body(size: 13, weight: .semibold))
                Text("Successful catalogs appear as soon as they finish.")
                    .font(theme.body(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.searchGroups.isEmpty {
            searchEmptyState
        } else {
            VStack(spacing: 0) {
                searchStatusBar
                Divider().opacity(WinstonLayout.dividerOpacity)
                searchFilters
                Divider().opacity(WinstonLayout.dividerOpacity)
                searchResults
            }
        }
    }

    private var searchStatusBar: some View {
        HStack(spacing: 10) {
            if viewModel.isSearching {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(theme.success)
            }
            Text(
                "\(viewModel.searchCompletedCount) of \(viewModel.searchRequestedCount) catalogs completed"
            )
            .font(theme.label(size: 10, weight: .semibold))
            if viewModel.hasPartialSearchFailure {
                Label(
                    "Some catalogs failed",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(theme.label(size: 10, weight: .semibold))
                .foregroundStyle(theme.highlight)
                .accessibilityLabel(
                    "Partial search failure. Successful results remain available."
                )
            }
            Spacer()
            Text("\(filteredGroups.count) results")
                .font(theme.label(size: 10))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(theme.backgroundAlt.opacity(0.35))
    }

    private var searchFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Picker(
                    "Catalog",
                    selection: $selectedCatalogFilter
                ) {
                    Text("All catalogs").tag(String?.none)
                    ForEach(viewModel.enabledCatalogs) {
                        Text(verbatim: $0.name).tag(Optional($0.id))
                    }
                }
                Picker(
                    "Language",
                    selection: $selectedLanguageFilter
                ) {
                    Text("All languages").tag(String?.none)
                    ForEach(availableLanguages, id: \.self) {
                        Text(verbatim: $0).tag(Optional($0))
                    }
                }
                Picker("Format", selection: $selectedFormatFilter) {
                    Text("All formats").tag(String?.none)
                    ForEach(availableFormats, id: \.self) {
                        Text(verbatim: $0).tag(Optional($0))
                    }
                }
                Picker(
                    "Acquisition",
                    selection: $selectedRelationFilter
                ) {
                    Text("All acquisitions")
                        .tag(OPDSAcquisitionRelation?.none)
                    ForEach(availableRelations, id: \.self) {
                        Text(verbatim: $0.localizedLabel)
                            .tag(Optional($0))
                    }
                }
                Toggle("Hide owned", isOn: $hidesOwned)
                    .toggleStyle(.checkbox)
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var searchResults: some View {
        List(filteredGroups, selection: $selectedResultID) { group in
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedResultIDs.contains(group.id) },
                    set: {
                        if $0 {
                            expandedResultIDs.insert(group.id)
                        } else {
                            expandedResultIDs.remove(group.id)
                        }
                    }
                )
            ) {
                SearchSourceList(
                    variants: filteredVariants(in: group),
                    library: library,
                    viewModel: viewModel
                )
                .padding(.leading, 26)
                .padding(.vertical, 6)
            } label: {
                CatalogSearchResultLabel(group: group)
            }
            .tag(group.id)
            .accessibilityIdentifier("opds.result.\(group.id)")
        }
        .listStyle(.plain)
        .onKeyPress(.return) {
            guard let selectedResultID else { return .ignored }
            if expandedResultIDs.contains(selectedResultID) {
                expandedResultIDs.remove(selectedResultID)
            } else {
                expandedResultIDs.insert(selectedResultID)
            }
            return .handled
        }
    }

    private var searchEmptyState: some View {
        ContentUnavailableView {
            if viewModel.searchWasCancelled {
                Label("Search cancelled", systemImage: "xmark.circle")
            } else if viewModel.searchStates.values.allSatisfy({
                $0 == .disabled
            }) {
                Label("All catalogs are disabled", systemImage: "pause.circle")
            } else if viewModel.searchStates.values.allSatisfy({
                $0 == .unsupportedSearch || $0 == .disabled
            }) {
                Label(
                    "No searchable catalogs",
                    systemImage: "magnifyingglass"
                )
            } else {
                Label("No catalog results", systemImage: "books.vertical")
            }
        } description: {
            Text(
                viewModel.searchWasCancelled
                    ? "Submit the search again when you’re ready."
                    : "Try a title, author, or ISBN, or open a catalog to browse it."
            )
        } actions: {
            if viewModel.searchStates.values.contains(where: {
                if case .failed = $0 { return true }
                return false
            }) {
                Menu("Retry failed catalogs") {
                    ForEach(failedCatalogs) { catalog in
                        Button(catalog.name) {
                            viewModel.retrySearch(
                                catalogID: catalog.id,
                                ownershipRecords:
                                    readModel.recordSnapshot()
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var browseContent: some View {
        switch viewModel.phase {
        case .home:
            EmptyView()
        case .disabledOnline:
            OPDSUnavailableView(
                title: "Catalogs are offline",
                systemImage: "wifi.slash",
                description: String(
                    localized: "Turn on online metadata in Settings to browse and download from OPDS catalogs."
                )
            ) {
                SettingsLink { Text("Open Settings") }
            }
        case .loading:
            OPDSLoadingView()
        case .failed(let failure):
            OPDSUnavailableView(
                title: "Couldn’t open catalog",
                systemImage: "exclamationmark.triangle",
                description: failure.message
            ) {
                Button("Try Again") {
                    Task { await viewModel.retry() }
                }
            }
        case .empty:
            if hasVisibleBrowseResults {
                feedContent
            } else {
                OPDSEmptyResultsView(isSearching: !searchText.isEmpty)
            }
        case .loaded:
            if hasVisibleBrowseResults {
                feedContent
            } else {
                OPDSEmptyResultsView(isSearching: !searchText.isEmpty)
            }
        }
    }

    private var feedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !filteredNavigation.isEmpty {
                    OPDSNavigationSection(
                        items: filteredNavigation
                    ) { item in
                        searchText = ""
                        Task { await viewModel.open(item) }
                    }
                }

                if !filteredPublications.isEmpty {
                    OPDSPublicationSection(
                        publications: filteredPublications,
                        library: library,
                        viewModel: viewModel
                    )
                }

                if viewModel.canLoadNextPage {
                    HStack {
                        Spacer()
                        Button {
                            Task { await viewModel.loadNextPage() }
                        } label: {
                            if viewModel.isLoadingNextPage {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(
                                    "Load More",
                                    systemImage: "arrow.down.circle"
                                )
                            }
                        }
                        .disabled(viewModel.isLoadingNextPage)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(24)
        }
    }

    private func submitSearch() {
        searchIsFocused = false
        if viewModel.selectedCatalog == nil {
            submitUnifiedSearch()
        } else {
            Task {
                await viewModel.searchCurrentCatalog(searchText)
            }
        }
    }

    private func submitUnifiedSearch() {
        viewModel.performUnifiedSearch(
            searchText,
            ownershipRecords: readModel.recordSnapshot()
        )
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredNavigation: [OPDSNavigationItem] {
        guard let items = viewModel.feed?.navigation else { return [] }
        guard !normalizedSearchText.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(
                normalizedSearchText
            )
                || $0.subtitle?.localizedCaseInsensitiveContains(
                    normalizedSearchText
                ) == true
        }
    }

    private var filteredPublications: [OPDSPublication] {
        guard let items = viewModel.feed?.publications else { return [] }
        guard !normalizedSearchText.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(
                normalizedSearchText
            )
                || $0.authorLine?.localizedCaseInsensitiveContains(
                    normalizedSearchText
                ) == true
                || $0.language?.localizedCaseInsensitiveContains(
                    normalizedSearchText
                ) == true
        }
    }

    private var hasVisibleBrowseResults: Bool {
        !filteredNavigation.isEmpty || !filteredPublications.isEmpty
    }

    private var filteredGroups: [OPDSSearchResultGroup] {
        viewModel.searchGroups.filter { group in
            (!hidesOwned || !group.isOwned)
                && !filteredVariants(in: group).isEmpty
        }
    }

    private func filteredVariants(
        in group: OPDSSearchResultGroup
    ) -> [OPDSSearchVariant] {
        group.variants.filter { variant in
            if let selectedCatalogFilter,
               variant.catalogID != selectedCatalogFilter {
                return false
            }
            if let selectedLanguageFilter,
               variant.publication.language != selectedLanguageFilter {
                return false
            }
            let acquisitions = variant.publication.acquisitions
            if let selectedFormatFilter,
               !acquisitions.contains(where: {
                   $0.formatLabel == selectedFormatFilter
               }) {
                return false
            }
            if let selectedRelationFilter,
               !acquisitions.contains(where: {
                   $0.relation == selectedRelationFilter
               }) {
                return false
            }
            return true
        }
    }

    private var availableLanguages: [String] {
        unique(viewModel.searchGroups.flatMap(\.languages)).sorted()
    }

    private var availableFormats: [String] {
        unique(viewModel.searchGroups.flatMap(\.formats)).sorted()
    }

    private var availableRelations: [OPDSAcquisitionRelation] {
        var seen: Set<OPDSAcquisitionRelation> = []
        return viewModel.searchGroups
            .flatMap(\.acquisitionRelations)
            .filter { seen.insert($0).inserted }
    }

    private var failedCatalogs: [OPDSCatalogConfiguration] {
        viewModel.catalogs.filter {
            if case .failed = viewModel.searchStates[$0.id] {
                return true
            }
            return false
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private func documentFormatLabel(
        _ format: OPDSDocumentFormat
    ) -> String {
        switch format {
        case .opds1: "OPDS 1"
        case .opds2: "OPDS 2"
        case .atom: "Atom"
        case .mediaWiki: "MediaWiki"
        }
    }
}

private struct OPDSCatalogToolbar: ToolbarContent {
    let viewModel: OPDSViewModel
    let showsSettings: Bool
    let onBack: () -> Void

    var body: some ToolbarContent {
        if viewModel.canGoBack {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .help("Back")
                .accessibilityIdentifier("opds.back")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if showsSettings {
                SettingsLink {
                    Label("Catalog Settings", systemImage: "gearshape")
                }
                .help("Add, edit, reorder, or test catalogs")
                .accessibilityIdentifier("opds.settings")
            } else {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    if viewModel.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(!viewModel.canRefresh)
                .help("Refresh")
                .accessibilityIdentifier("opds.refresh")
            }
        }
    }
}

private struct CatalogListRow: View {
    let catalog: OPDSCatalogConfiguration
    let searchState: OPDSCatalogSearchState?
    let onBrowse: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onBrowse) {
            HStack(spacing: 10) {
                Image(systemName: catalog.presentationSystemImage)
                    .font(.body.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(
                        catalog.isEnabled
                            ? theme.accent
                            : theme.textTertiary
                    )
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(verbatim: catalog.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        if catalog.authenticationMode == .basic {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .accessibilityLabel(
                                    "Uses Basic authentication"
                                )
                        }
                        if catalog.isHTTP {
                            Image(
                                systemName:
                                    "exclamationmark.triangle.fill"
                            )
                            .font(.system(size: 8))
                            .foregroundStyle(theme.highlight)
                            .accessibilityLabel(
                                "Insecure HTTP catalog"
                            )
                        }
                    }
                    Text(verbatim: statusLabel)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!catalog.isEnabled)
        .accessibilityLabel(catalog.name)
        .accessibilityValue(statusLabel)
        .help(
            catalog.isEnabled
                ? String(localized: "Browse this catalog")
                : String(
                    localized: "Enable this catalog in Settings before browsing."
                )
        )
    }

    private var statusLabel: String {
        guard catalog.isEnabled else {
            return String(localized: "Disabled")
        }
        guard let searchState else {
            return catalog.rootURL.host()
                ?? String(localized: "Ready to browse")
        }
        return switch searchState {
        case .loading: String(localized: "Searching…")
        case .success(let publications):
            String(localized: "\(publications.count) results")
        case .empty: String(localized: "No results")
        case .failed(let error): error.description
        case .unsupportedSearch:
            String(localized: "Browse only")
        case .disabled: String(localized: "Disabled")
        case .cancelled: String(localized: "Search cancelled")
        }
    }

    private var statusColor: Color {
        guard let searchState else { return theme.textSecondary }
        return switch searchState {
        case .failed:
            theme.highlight
        case .success:
            theme.success
        default:
            theme.textSecondary
        }
    }
}

private struct CatalogSearchResultLabel: View {
    let group: OPDSSearchResultGroup

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            OPDSCoverView(id: group.id, coverURL: group.coverURL)
                .frame(width: 38, height: 56)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: WinstonLayout.cornerSmall
                    )
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: group.title)
                    .font(theme.body(size: 13, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                if let author = group.author {
                    Text(verbatim: author)
                        .font(theme.body(size: 10))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text("\(group.sourceCount) sources")
                    if !group.formats.isEmpty {
                        Text(verbatim: group.formats.joined(separator: " · "))
                    }
                    if !group.languages.isEmpty {
                        Text(
                            verbatim: group.languages.joined(
                                separator: " · "
                            )
                        )
                    }
                }
                .font(theme.label(size: 9))
                .foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 8)
            if group.isOwned {
                Label(
                    group.appearsToBeAnotherEdition
                        ? "Other edition"
                        : "Owned",
                    systemImage: group.appearsToBeAnotherEdition
                        ? "books.vertical.fill"
                        : "checkmark.circle.fill"
                )
                .font(theme.label(size: 9, weight: .semibold))
                .foregroundStyle(theme.success)
                .accessibilityLabel(
                    group.appearsToBeAnotherEdition
                        ? "A matching work is owned; this appears to be another edition."
                        : "A matching local book is already owned."
                )
            }
        }
        .padding(.vertical, 5)
    }
}

private struct SearchSourceList: View {
    let variants: [OPDSSearchVariant]
    let library: LibraryViewModel
    let viewModel: OPDSViewModel

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(variants) { variant in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label(
                            variant.catalogName,
                            systemImage: "books.vertical"
                        )
                        .font(theme.body(size: 11, weight: .semibold))
                        .accessibilityLabel(
                            "Source catalog \(variant.catalogName)"
                        )
                        Spacer()
                        if let language =
                            variant.publication.language {
                            Text(verbatim: language)
                                .font(theme.label(size: 9))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    ForEach(variant.publication.acquisitionOptions) {
                        acquisition in
                        AcquisitionSourceRow(
                            acquisition: acquisition,
                            publication: variant.publication,
                            catalogID: variant.catalogID,
                            library: library,
                            viewModel: viewModel
                        )
                    }
                    if let rights = variant.publication.rights {
                        Text("Rights: \(rights)")
                            .font(theme.body(size: 9))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }
                    if let attribution =
                        variant.publication.attribution {
                        Text("Attribution: \(attribution)")
                            .font(theme.body(size: 9))
                            .foregroundStyle(theme.textSecondary)
                    }
                    if !variant.publication.contributors.isEmpty {
                        Text(
                            "Contributors: \(variant.publication.contributors.joined(separator: ", "))"
                        )
                        .font(theme.body(size: 9))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(3)
                    }
                    if let sourceURL = variant.publication.sourceURL {
                        Link(destination: sourceURL) {
                            Label("Source", systemImage: "safari")
                        }
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(
                    theme.backgroundAlt.opacity(0.55),
                    in: RoundedRectangle(
                        cornerRadius: WinstonLayout.cornerMedium
                    )
                )
            }
        }
    }
}

private struct AcquisitionSourceRow: View {
    let acquisition: OPDSAcquisition
    let publication: OPDSPublication
    let catalogID: String
    let library: LibraryViewModel
    let viewModel: OPDSViewModel

    @Environment(\.theme) private var theme
    @Environment(DeviceMonitor.self) private var deviceMonitor
    @Environment(TransferQueue.self) private var transferQueue

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: acquisition.formatLabel)
                .font(theme.label(size: 9, weight: .bold))
                .frame(minWidth: 36, alignment: .leading)
            Text(verbatim: acquisition.relation.localizedLabel)
                .font(theme.body(size: 10))
            if let price = formattedPrice {
                Text(verbatim: price)
                    .font(theme.label(size: 9))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Link(destination: acquisition.url) {
                Label("Open Source", systemImage: "safari")
            }
            .controlSize(.small)
            .help("Open this exact acquisition at its source")
            .accessibilityLabel(
                "Open \(acquisition.relation.localizedLabel) source in browser"
            )

            if acquisition.canImport {
                if viewModel.isDownloading(
                    publication,
                    catalogID: catalogID
                ) {
                    Button("Cancel") {
                        viewModel.cancelDownload(
                            publication,
                            catalogID: catalogID
                        )
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Cancel book download")
                } else {
                    Menu {
                        Button("Import") {
                            importBook(sendsToKindle: false)
                        }
                        if deviceMonitor.isConnected {
                            Button("Import and Send to Kindle") {
                                importBook(sendsToKindle: true)
                            }
                        }
                    } label: {
                        Text("Import")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(
                        "Download this exact format and open Import Review"
                    )
                    .accessibilityLabel(
                        "Import \(acquisition.formatLabel) from catalog"
                    )
                }
            } else {
                Button("Import") {}
                    .controlSize(.small)
                    .disabled(true)
                    .help(importDisabledReason)
                    .accessibilityLabel(
                        "Import unavailable. \(importDisabledReason)"
                    )
            }
        }
    }

    private var formattedPrice: String? {
        guard let price = acquisition.price else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = acquisition.currency
        return formatter.string(from: price as NSDecimalNumber)
    }

    private var importDisabledReason: String {
        if !acquisition.relation.isDirectlyDownloadable {
            return String(
                localized: "This acquisition is not a direct download. Open it at the source."
            )
        }
        return String(
            localized: "Winston cannot import this advertised format."
        )
    }

    private func importBook(sendsToKindle: Bool) {
        if sendsToKindle {
            viewModel.addToLibrary(
                publication,
                acquisition: acquisition,
                catalogID: catalogID,
                library: library,
                onSuccessfulImport: { imported in
                    Task {
                        await transferQueue.send(
                            books: imported,
                            via: deviceMonitor
                        )
                    }
                }
            )
        } else {
            viewModel.addToLibrary(
                publication,
                acquisition: acquisition,
                catalogID: catalogID,
                library: library
            )
        }
    }
}

private struct OPDSNavigationSection: View {
    let items: [OPDSNavigationItem]
    let onOpen: (OPDSNavigationItem) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Browse")
                .font(theme.body(size: 14, weight: .bold))
            ForEach(items) { item in
                Button { onOpen(item) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "books.vertical.fill")
                            .foregroundStyle(theme.accent)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.title)
                                .font(
                                    theme.body(
                                        size: 12,
                                        weight: .semibold
                                    )
                                )
                            if let subtitle = item.subtitle {
                                Text(verbatim: subtitle)
                                    .font(theme.body(size: 10))
                                    .foregroundStyle(
                                        theme.textSecondary
                                    )
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(theme.textTertiary)
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(WinstonLayout.dividerOpacity)
            }
        }
    }
}

private struct OPDSPublicationSection: View {
    let publications: [OPDSPublication]
    let library: LibraryViewModel
    let viewModel: OPDSViewModel

    @Environment(\.theme) private var theme
    @Environment(DeviceMonitor.self) private var deviceMonitor
    @Environment(TransferQueue.self) private var transferQueue
    private let columns = [
        GridItem(.adaptive(minimum: 170, maximum: 215), spacing: 16),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Books")
                .font(theme.body(size: 14, weight: .bold))
            LazyVGrid(
                columns: columns,
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(publications) { publication in
                    OPDSPublicationCard(
                        publication: publication,
                        isDownloading: viewModel.isDownloading(
                            publication
                        )
                    ) { acquisition in
                        viewModel.addToLibrary(
                            publication,
                            acquisition: acquisition,
                            library: library
                        )
                    } onImportAndSend: { acquisition in
                        viewModel.addToLibrary(
                            publication,
                            acquisition: acquisition,
                            library: library,
                            onSuccessfulImport: { imported in
                                Task {
                                    await transferQueue.send(
                                        books: imported,
                                        via: deviceMonitor
                                    )
                                }
                            }
                        )
                    } onCancel: {
                        viewModel.cancelDownload(publication)
                    }
                }
            }
        }
    }
}

private struct OPDSPublicationCard: View {
    let publication: OPDSPublication
    let isDownloading: Bool
    let onAdd: (OPDSAcquisition) -> Void
    let onImportAndSend: (OPDSAcquisition) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @Environment(DeviceMonitor.self) private var deviceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OPDSCoverView(
                id: publication.id,
                coverURL: publication.coverURL
            )
            .aspectRatio(WinstonLayout.coverAspect, contentMode: .fill)
            .clipped()
            .clipShape(
                RoundedRectangle(cornerRadius: WinstonLayout.cornerMedium)
            )

            Text(verbatim: publication.title)
                .font(theme.body(size: 12, weight: .bold))
                .lineLimit(2)
            Text(
                verbatim: publication.authorLine
                    ?? String(localized: "Author not listed")
            )
            .font(theme.body(size: 9))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)

            if isDownloading {
                Button("Cancel Download", action: onCancel)
                    .controlSize(.small)
            } else if let preferred =
                publication.preferredAcquisition {
                HStack(spacing: 4) {
                    Button("Import \(preferred.formatLabel)") {
                        onAdd(preferred)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    if publication.acquisitionOptions.count > 1 {
                        Menu {
                            if deviceMonitor.isConnected {
                                Button("Import and Send to Kindle") {
                                    onImportAndSend(preferred)
                                }
                                Divider()
                            }
                            ForEach(
                                publication.acquisitionOptions
                            ) { acquisition in
                                if acquisition.canImport {
                                    Button(
                                        acquisition.optionLabel
                                    ) {
                                        onAdd(acquisition)
                                    }
                                } else {
                                    Link(
                                        "\(acquisition.optionLabel) — \(acquisition.relation.localizedLabel)",
                                        destination: acquisition.url
                                    )
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Choose an exact source format")
                    }
                }
                if !deviceMonitor.isConnected {
                    Text("Connect a Kindle to import and send immediately.")
                        .font(theme.label(size: 8))
                        .foregroundStyle(theme.textTertiary)
                        .help(
                            "Import and Send to Kindle is unavailable because no device is connected."
                        )
                }
            } else if let source =
                publication.acquisitionOptions.first {
                Link("Open Source", destination: source.url)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            theme.surface.opacity(0.78),
            in: RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge)
        )
        .overlay {
            RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge)
                .stroke(theme.borderSubtle, lineWidth: 1)
        }
        .help(publication.summary ?? publication.title)
    }
}

private struct OPDSCoverView: View {
    let id: String
    let coverURL: URL?

    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings
    @State private var image: NSImage?

    var body: some View {
        let colors = palette
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    BookCoverArt(
                        accent1: colors.primary,
                        accent2: colors.secondary
                    )
                }
            }
            .clipped()
            .task(id: coverTaskID) {
                image = nil
                guard settings.onlineMetadataEnabled,
                      let coverURL else {
                    return
                }
                image = await DiscoveryImageLoader.shared.image(
                    for: coverURL
                )
            }
    }

    private var coverTaskID: String {
        "\(settings.onlineMetadataEnabled)|\(coverURL?.absoluteString ?? "")"
    }

    private var palette: ColorPair {
        let palettes = theme.coverPalettes
        guard !palettes.isEmpty else {
            return ColorPair(
                primary: theme.accent,
                secondary: theme.accentSecondary
            )
        }
        let index = id.utf8.reduce(0) {
            ($0 &* 31 &+ Int($1)) % palettes.count
        }
        return palettes[index]
    }
}

private struct OPDSLoadingView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Opening catalog…")
                .font(theme.body(size: 14, weight: .bold))
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(
                    cornerRadius: WinstonLayout.cornerMedium
                )
                .fill(theme.surfaceGlass)
                .frame(height: 54)
            }
        }
        .padding(24)
        .redacted(reason: .placeholder)
        .accessibilityLabel("Opening catalog")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OPDSUnavailableView<Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(verbatim: description)
        } actions: {
            actions()
        }
    }
}

private struct OPDSEmptyResultsView: View {
    let isSearching: Bool

    var body: some View {
        ContentUnavailableView {
            Label(
                isSearching ? "No Search Results" : "No Books Here",
                systemImage: isSearching
                    ? "magnifyingglass"
                    : "books.vertical"
            )
        } description: {
            Text(
                isSearching
                    ? "Try a different search."
                    : "Go back to choose another section, or search this catalog."
            )
        }
    }
}

#if DEBUG
#Preview("Catalog Hub") {
    let container = PersistenceController.inMemory()
    let settings = AppSettings()
    let toasts = ToastCenter()
    OPDSCatalogView(
        library: LibraryViewModel(
            modelContext: container.mainContext,
            settings: settings,
            toasts: toasts
        ),
        readModel: LibraryReadModel()
    )
    .modelContainer(container)
    .environment(settings)
    .environment(OPDSViewModel(settings: settings, toasts: toasts))
    .environment(toasts)
    .environment(ThemeManager())
    .environment(\.theme, .black)
    .frame(width: 980, height: 680)
}
#endif
