import SwiftUI
import SwiftData

struct OPDSCatalogView: View {
    let library: LibraryViewModel

    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings
    @Environment(OPDSViewModel.self) private var viewModel
    @State private var searchText = ""

    var body: some View {
        Group {
            if viewModel.selectedCatalog == nil {
                surface
            } else {
                surface
                    .searchable(text: $searchText, prompt: "Search catalog")
                    .onSubmit(of: .search) {
                        guard viewModel.supportsRemoteSearch else { return }
                        Task { await viewModel.search(searchText) }
                    }
            }
        }
        .toolbar {
            OPDSCatalogToolbar(viewModel: viewModel) {
                searchText = ""
                viewModel.goBack()
            }
        }
        .onChange(of: viewModel.selectedCatalog) { _, _ in
            searchText = ""
        }
        .onChange(of: settings.onlineMetadataEnabled) { _, _ in
            viewModel.onlineSettingDidChange()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemedBackground())
    }

    private var surface: some View {
        VStack(spacing: 0) {
            OPDSCatalogHeader(
                catalog: viewModel.selectedCatalog,
                feed: viewModel.feed,
                refreshFailure: viewModel.refreshFailure
            )
            Divider().opacity(0.3)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .home:
            OPDSCatalogHome(catalogs: viewModel.catalogs) { catalog in
                Task { await viewModel.open(catalog) }
            }
        case .disabledOnline:
            OPDSUnavailableView(
                title: "Catalogs are offline",
                systemImage: "wifi.slash",
                description: String(localized: "Turn on online metadata in Settings to browse and download from OPDS catalogs.")
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
                Button("Try Again") { Task { await viewModel.retry() } }
            }
        case .empty:
            if hasVisibleResults {
                feedContent
            } else {
                OPDSEmptyResultsView(isSearching: !searchText.isEmpty)
            }
        case .loaded:
            if hasVisibleResults {
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
                    OPDSNavigationSection(items: filteredNavigation) { item in
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
                                Label("Load More", systemImage: "arrow.down.circle")
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

    private var filteredNavigation: [OPDSNavigationItem] {
        guard let items = viewModel.feed?.navigation else { return [] }
        let query = normalizedSearchText
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var filteredPublications: [OPDSPublication] {
        guard let items = viewModel.feed?.publications else { return [] }
        let query = normalizedSearchText
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.authorLine?.localizedCaseInsensitiveContains(query) == true
                || $0.language?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasVisibleResults: Bool {
        !filteredNavigation.isEmpty || !filteredPublications.isEmpty
    }
}

// MARK: - Header and toolbar

private struct OPDSCatalogHeader: View {
    let catalog: OPDSCatalog?
    let feed: OPDSFeed?
    let refreshFailure: OPDSViewModel.OPDSFailure?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    if let catalog {
                        Text(verbatim: feed?.title ?? catalog.name)
                            .font(theme.display(size: 22, weight: .heavy))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(verbatim: feed?.subtitle ?? catalog.name)
                            .font(theme.label(size: 10))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    } else {
                        theme.styledText(terminal: "// opds_catalogs", native: "Open Catalogs")
                            .font(theme.display(size: 22, weight: .heavy))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .accessibilityIdentifier("opds.title")
                        theme.styledText(
                            terminal: "browse // download // kindle-ready",
                            native: "Browse free books, add them to your library, and prepare them for Kindle automatically."
                        )
                        .font(theme.label(size: 10))
                        .foregroundStyle(theme.textSecondary)
                    }
                }
                Spacer(minLength: 12)
                if let catalog {
                    Text(verbatim: protocolLabel(for: catalog))
                        .font(theme.label(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.surface.opacity(0.8), in: Capsule())
                }
            }

            if let refreshFailure {
                Label {
                    Text(verbatim: refreshFailure.message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.highlight)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func protocolLabel(for catalog: OPDSCatalog) -> String {
        switch catalog.kind {
        case .projectGutenberg: "OPDS 1.2"
        case .standardEbooks: "ATOM 1.0"
        }
    }
}

private struct OPDSCatalogToolbar: ToolbarContent {
    let viewModel: OPDSViewModel
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

            ToolbarItem(placement: .primaryAction) {
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

// MARK: - Catalog home

private struct OPDSCatalogHome: View {
    let catalogs: [OPDSCatalog]
    let onOpen: (OPDSCatalog) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(catalogs) { catalog in
                    OPDSProviderCard(catalog: catalog) { onOpen(catalog) }
                }
            }
            .padding(24)
        }
    }
}

private struct OPDSProviderCard: View {
    let catalog: OPDSCatalog
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 44, height: 44)
                        .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }

                Text(verbatim: catalog.name)
                    .font(theme.body(size: 16, weight: .bold))
                    .foregroundStyle(theme.textPrimary)

                Text(description)
                    .font(theme.body(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                    Text(availabilityLabel)
                }
                .font(theme.label(size: 9, weight: .semibold))
                .foregroundStyle(theme.accent)
            }
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .padding(18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: WinstonLayout.cornerLarge)
        .overlay {
            RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge, style: .continuous)
                .stroke(isHovered ? theme.accent.opacity(0.45) : theme.borderSubtle, lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
    }

    private var icon: String {
        switch catalog.kind {
        case .projectGutenberg: "text.book.closed.fill"
        case .standardEbooks: "book.pages.fill"
        }
    }

    private var description: LocalizedStringKey {
        switch catalog.kind {
        case .projectGutenberg:
            "A huge open library with classics in many languages, including Czech."
        case .standardEbooks:
            "The 15 newest carefully proofread editions, available from the public releases feed."
        }
    }

    private var availabilityLabel: LocalizedStringKey {
        switch catalog.kind {
        case .projectGutenberg: "Free public-domain books"
        case .standardEbooks: "15 latest public releases"
        }
    }
}

// MARK: - Feed sections

private struct OPDSNavigationSection: View {
    let items: [OPDSNavigationItem]
    let onOpen: (OPDSNavigationItem) -> Void

    @Environment(\.theme) private var theme
    private let columns = [GridItem(.adaptive(minimum: 235, maximum: 360), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse")
                .font(theme.body(size: 14, weight: .bold))
                .foregroundStyle(theme.textPrimary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    OPDSNavigationCard(item: item) { onOpen(item) }
                }
            }
        }
    }
}

private struct OPDSNavigationCard: View {
    let item: OPDSNavigationItem
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 34, height: 34)
                    .background(theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: item.title)
                        .font(theme.body(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                    if let subtitle = item.subtitle {
                        Text(verbatim: subtitle)
                            .font(theme.label(size: 9))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(theme.surface.opacity(isHovered ? 0.95 : 0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovered ? theme.accent.opacity(0.35) : theme.borderSubtle, lineWidth: 1)
        }
        .onHover { isHovered = $0 }
    }
}

private struct OPDSPublicationSection: View {
    let publications: [OPDSPublication]
    let library: LibraryViewModel
    let viewModel: OPDSViewModel

    @Environment(\.theme) private var theme
    private let columns = [GridItem(.adaptive(minimum: 165, maximum: 210), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Books")
                .font(theme.body(size: 14, weight: .bold))
                .foregroundStyle(theme.textPrimary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(publications) { publication in
                    OPDSPublicationCard(
                        publication: publication,
                        isDownloading: viewModel.isDownloading(publication),
                        isDownloaded: viewModel.isDownloaded(publication)
                    ) { acquisition in
                        viewModel.addToLibrary(
                            publication,
                            acquisition: acquisition,
                            library: library
                        )
                    }
                }
            }
        }
    }
}

private struct OPDSPublicationCard: View {
    let publication: OPDSPublication
    let isDownloading: Bool
    let isDownloaded: Bool
    let onAdd: (OPDSAcquisition) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OPDSCoverView(id: publication.id, coverURL: publication.coverURL)
                .aspectRatio(WinstonLayout.coverAspect, contentMode: .fill)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(6)

            VStack(alignment: .leading, spacing: 7) {
                Text(verbatim: publication.title)
                    .font(theme.body(size: 12, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)

                Text(verbatim: publication.authorLine ?? String(localized: "Author not listed"))
                    .font(theme.label(size: 9))
                    .foregroundStyle(publication.authorLine == nil ? theme.textTertiary : theme.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                actionRow
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .frame(minHeight: 94, alignment: .topLeading)
        }
        .glassCard(cornerRadius: WinstonLayout.cornerLarge)
        .overlay {
            RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge, style: .continuous)
                .stroke(isHovered ? theme.accent.opacity(0.4) : theme.borderSubtle, lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .help(publication.summary ?? publication.title)
    }

    @ViewBuilder
    private var actionRow: some View {
        if isDownloading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Adding…")
            }
            .font(theme.label(size: 9, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
        } else if isDownloaded {
            Label("In Library", systemImage: "checkmark.circle.fill")
                .font(theme.label(size: 9, weight: .semibold))
                .foregroundStyle(theme.success)
        } else if let preferred = publication.preferredAcquisition {
            HStack(spacing: 4) {
                Button {
                    onAdd(preferred)
                } label: {
                    Label("Add \(preferred.formatLabel)", systemImage: "plus")
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("opds.add.\(publication.id)")

                if publication.acquisitions.count > 1 {
                    Menu {
                        ForEach(publication.acquisitionOptions) { acquisition in
                            Button(acquisition.optionLabel) { onAdd(acquisition) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Choose format")
                }
            }
        }
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
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    BookCoverArt(accent1: colors.primary, accent2: colors.secondary)
                }
            }
            .clipped()
            .task(id: coverTaskID) {
                image = nil
                guard settings.onlineMetadataEnabled, let coverURL else { return }
                image = await DiscoveryImageLoader.shared.image(for: coverURL)
            }
    }

    private var coverTaskID: String {
        "\(settings.onlineMetadataEnabled)|\(coverURL?.absoluteString ?? "")"
    }

    private var palette: ColorPair {
        let palettes = theme.coverPalettes
        guard !palettes.isEmpty else {
            return ColorPair(primary: theme.accent, secondary: theme.accentSecondary)
        }
        let index = id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % palettes.count }
        return palettes[index]
    }
}

// MARK: - States

private struct OPDSLoadingView: View {
    @Environment(\.theme) private var theme
    private let columns = [GridItem(.adaptive(minimum: 235, maximum: 360), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Opening catalog…")
                    .font(theme.body(size: 14, weight: .bold))
                    .foregroundStyle(theme.textPrimary)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(0..<6, id: \.self) { _ in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.surfaceGlass)
                                .frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(theme.surfaceGlass)
                                    .frame(maxWidth: 150)
                                    .frame(height: 10)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(theme.surfaceGlass.opacity(0.7))
                                    .frame(maxWidth: 96)
                                    .frame(height: 8)
                            }
                            Spacer(minLength: 4)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                        .background(theme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(theme.borderSubtle, lineWidth: 1)
                        }
                    }
                }
                .redacted(reason: .placeholder)
                .accessibilityHidden(true)
            }
            .padding(24)
        }
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
            if isSearching {
                Label("No Search Results", systemImage: "magnifyingglass")
            } else {
                Label("No Books Here", systemImage: "books.vertical")
            }
        } description: {
            if isSearching {
                Text("Try a different search.")
            } else {
                Text("Go back to choose another section, or search this catalog.")
            }
        }
    }
}

#if DEBUG
#Preview("OPDS catalogs") {
    let container = PersistenceController.inMemory()
    let settings = AppSettings()
    let toasts = ToastCenter()
    OPDSCatalogView(
        library: LibraryViewModel(
            modelContext: container.mainContext,
            settings: settings,
            toasts: toasts
        )
    )
    .modelContainer(container)
    .environment(settings)
    .environment(OPDSViewModel(settings: settings, toasts: toasts))
    .environment(ToastCenter())
    .environment(ThemeManager())
    .environment(DiscoveryViewModel(settings: settings))
    .environment(\.theme, .black)
    .frame(width: 820, height: 620)
}
#endif
