import AppKit
import SwiftData
import SwiftUI

struct DiscoveryView: View {
    let wishlist: WishlistService

    @Environment(DiscoveryViewModel.self) private var viewModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            DiscoveryHeader(
                selectedGenre: viewModel.selectedGenre,
                isRefreshing: viewModel.isRefreshing,
                refreshFailed: viewModel.refreshFailed,
                canRefresh: viewModel.phase != .loading
                    && viewModel.phase != .disabledOnline
                    && viewModel.phase != .disabledToken,
                onSelect: viewModel.select,
                onRefresh: { Task { await viewModel.refresh() } }
            )

            Divider().opacity(0.3)

            DiscoveryContent(
                phase: viewModel.phase,
                books: viewModel.visibleBooks,
                hasMore: viewModel.hasMore,
                columns: WinstonLayout.coverGridColumns(zoom: settings.gridZoom),
                externalBookWebsiteURL: settings.externalBookWebsiteURL,
                wishlist: wishlist,
                onRetry: { Task { await viewModel.retry() } },
                onLoadMore: viewModel.loadNextPage
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemedBackground())
        .task(id: viewModel.selectedGenre) { await viewModel.load() }
        .onChange(of: settings.onlineMetadataEnabled) { _, _ in
            viewModel.onlineSettingDidChange()
        }
        .onChange(of: settings.hardcoverToken) { _, _ in
            viewModel.hardcoverCredentialDidChange()
        }
    }
}

// MARK: - Header

private struct DiscoveryHeader: View {
    let selectedGenre: DiscoveryGenre
    let isRefreshing: Bool
    let refreshFailed: Bool
    let canRefresh: Bool
    let onSelect: (DiscoveryGenre) -> Void
    let onRefresh: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    theme.styledText(terminal: "// discover", native: "Discover")
                        .font(theme.display(size: 22, weight: .heavy))
                        .foregroundStyle(theme.textPrimary)

                    theme.styledText(
                        terminal: "newest released // cached 24h",
                        native: "Newest released books with covers, updated at most once every 24 hours."
                    )
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textSecondary)
                }

                Spacer(minLength: 12)

                Button(action: onRefresh) {
                    HStack(spacing: 7) {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        theme.styledText(
                            terminal: isRefreshing ? "refreshing" : "refresh",
                            native: "Refresh"
                        )
                    }
                    .font(theme.label(size: 11, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.pressable)
                .disabled(isRefreshing || !canRefresh)
                .help("Refresh")
            }

            if refreshFailed {
                Label("Refresh failed. Showing the previous results.", systemImage: "exclamationmark.triangle")
                    .font(theme.label(size: 10, weight: .medium))
                    .foregroundStyle(theme.highlight)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DiscoveryGenre.all) { genre in
                        GenreChip(genre: genre, isSelected: genre == selectedGenre) {
                            onSelect(genre)
                        }
                    }
                }
                .padding(.horizontal, 1)
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

private struct GenreChip: View {
    let genre: DiscoveryGenre
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            theme.styledText(terminal: genre.terminal, native: genre.nativeLabel)
                .font(theme.label(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(isSelected ? theme.accent : theme.surfaceGlass.opacity(0.5))
                )
                .overlay(
                    Capsule().stroke(isSelected ? .clear : theme.borderSubtle, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Content

private struct DiscoveryContent: View {
    let phase: DiscoveryViewModel.Phase
    let books: [DiscoveryBook]
    let hasMore: Bool
    let columns: [GridItem]
    let externalBookWebsiteURL: String
    let wishlist: WishlistService
    let onRetry: () -> Void
    let onLoadMore: @MainActor () async -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        switch phase {
        case .disabledOnline:
            DiscoveryPrompt(needsToken: false)
        case .disabledToken:
            DiscoveryPrompt(needsToken: true)
        case .loading:
            DiscoverySkeletonGrid(columns: columns)
        case .loaded:
            DiscoveryGrid(
                books: books,
                hasMore: hasMore,
                columns: columns,
                externalBookWebsiteURL: externalBookWebsiteURL,
                wishlist: wishlist,
                onLoadMore: onLoadMore
            )
        case .empty:
            DiscoveryMessage(
                systemImage: "books.vertical",
                title: theme.styledText(
                    terminal: "no_released_books_try_another_genre",
                    native: "No new releases found."
                ),
                onRetry: onRetry
            )
        case .failed:
            DiscoveryMessage(
                systemImage: "wifi.exclamationmark",
                title: theme.styledText(
                    terminal: "couldnt_reach_hardcover",
                    native: "Couldn’t reach Hardcover. Check your connection."
                ),
                onRetry: onRetry
            )
        }
    }
}

private struct DiscoveryGrid: View {
    let books: [DiscoveryBook]
    let hasMore: Bool
    let columns: [GridItem]
    let externalBookWebsiteURL: String
    let wishlist: WishlistService
    let onLoadMore: @MainActor () async -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(books) { book in
                        DiscoveryCardView(
                            book: book,
                            externalBookURL: ExternalBookSearchURL.make(
                                websiteURL: externalBookWebsiteURL,
                                title: book.title,
                                author: book.author
                            ),
                            isWishlisted: wishlist.contains(book),
                            onToggleWishlist: { wishlist.toggle(book) }
                        )
                    }
                }

                if hasMore {
                    DiscoveryLoadMoreTrigger(
                        visibleCount: books.count,
                        action: onLoadMore
                    )
                }
            }
            .padding(20)
        }
    }
}

private struct DiscoveryLoadMoreTrigger: View {
    let visibleCount: Int
    let action: @MainActor () async -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading more releases…")
                .font(theme.label(size: 10))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(height: 52)
        .task(id: visibleCount) { await action() }
    }
}

private struct DiscoverySkeletonGrid: View {
    let columns: [GridItem]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(0..<12, id: \.self) { _ in
                    DiscoverySkeletonCard()
                }
            }
            .padding(20)
        }
        .allowsHitTesting(false)
    }
}

private struct DiscoverySkeletonCard: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceGlass.opacity(0.55))
                .aspectRatio(WinstonLayout.coverAspect, contentMode: .fit)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.surfaceGlass.opacity(0.55))
                .frame(height: 10)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.surfaceGlass.opacity(0.4))
                .frame(width: 68, height: 8)
        }
        .padding(6)
        .glassCard(cornerRadius: WinstonLayout.cornerLarge)
        .redacted(reason: .placeholder)
        .shimmering()
        .clipShape(RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge, style: .continuous))
    }
}

// MARK: - Prompts

private struct DiscoveryPrompt: View {
    let needsToken: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(theme.accent)

            theme.styledText(terminal: "discover_new_books", native: "Discover new books")
                .font(theme.display(size: 18, weight: .bold))
                .foregroundStyle(theme.textPrimary)

            prompt
                .font(theme.body(size: 12))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Button {
                openSettingsWindow()
            } label: {
                theme.styledText(terminal: "open_settings", native: "Open Settings")
                    .font(theme.label(size: 12, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.pressable)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var prompt: Text {
        needsToken
            ? theme.styledText(
                terminal: "add_hardcover_token_in_settings",
                native: "Add your Hardcover API token in Settings to browse."
            )
            : theme.styledText(
                terminal: "enable_online_metadata_in_settings",
                native: "Turn on “Fetch metadata online” in Settings to browse Hardcover."
            )
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

private struct DiscoveryMessage: View {
    let systemImage: String
    let title: Text
    let onRetry: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(theme.textTertiary)

            title
                .font(theme.body(size: 13))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button(action: onRetry) {
                theme.styledText(terminal: "try_again", native: "Try Again")
                    .font(theme.label(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.pressable)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

#if DEBUG
#Preview("Discovery – loaded") {
    let container = PersistenceController.inMemory()
    let toasts = ToastCenter()
    let books = (1...32).map { index in
        DiscoveryBook(
            id: "\(index)",
            title: "Sample Book \(index)",
            author: index.isMultiple(of: 3) ? nil : "An Author",
            coverURL: nil,
            hardcoverURL: URL(string: "https://hardcover.app/books/sample-\(index)")!,
            rating: 4.0 + Double(index % 5) / 10,
            releaseDate: DiscoveryReleaseDate(year: 2026, month: 7, day: min(index, 15))
        )
    }
    return DiscoveryView(
        wishlist: WishlistService(modelContext: container.mainContext, toasts: toasts)
    )
    .modelContainer(container)
    .environment(DiscoveryViewModel.preview(.loaded, books: books))
    .environment(AppSettings())
    .environment(\.theme, .black)
    .frame(width: 820, height: 620)
}

#Preview("Discovery – disabled") {
    let container = PersistenceController.inMemory()
    let toasts = ToastCenter()
    DiscoveryView(
        wishlist: WishlistService(modelContext: container.mainContext, toasts: toasts)
    )
    .modelContainer(container)
    .environment(DiscoveryViewModel.preview(.disabledOnline))
    .environment(AppSettings())
    .environment(\.theme, .black)
    .frame(width: 820, height: 620)
}
#endif
