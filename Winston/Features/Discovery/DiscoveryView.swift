import SwiftUI
import AppKit
import SwiftData

struct DiscoveryView: View {
    let wishlist: WishlistService

    @Environment(DiscoveryViewModel.self) private var viewModel
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme

    private var columns: [GridItem] { WinstonLayout.coverGridColumns(zoom: settings.gridZoom) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
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

    // MARK: - Header + genre filter

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            theme.styledText(terminal: "// discover", native: "Discover")
                .font(theme.display(size: 22, weight: .heavy))
                .foregroundStyle(theme.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DiscoveryGenre.all) { genre in
                        GenreChip(genre: genre, isSelected: genre == viewModel.selectedGenre) {
                            viewModel.select(genre)
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

    // MARK: - Phase content

    @ViewBuilder private var content: some View {
        switch viewModel.phase {
        case .disabledOnline:
            DiscoveryPrompt(needsToken: false)
        case .disabledToken:
            DiscoveryPrompt(needsToken: true)
        case .loading:
            skeletonGrid
        case .loaded(let books):
            grid(books)
        case .empty:
            DiscoveryMessage(
                systemImage: "books.vertical",
                title: theme.styledText(terminal: "no_results_try_another_genre",
                                        native: "No results — try another genre."),
                onRetry: { Task { await viewModel.retry() } }
            )
        case .failed:
            DiscoveryMessage(
                systemImage: "wifi.exclamationmark",
                title: theme.styledText(terminal: "couldnt_reach_hardcover",
                                        native: "Couldn’t reach Hardcover. Check your connection."),
                onRetry: { Task { await viewModel.retry() } }
            )
        }
    }

    private func grid(_ books: [DiscoveryBook]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(books) { book in
                    DiscoveryCardView(
                        book: book,
                        externalBookURL: ExternalBookSearchURL.make(
                            websiteURL: settings.externalBookWebsiteURL,
                            title: book.title,
                            author: book.author
                        ),
                        isWishlisted: wishlist.contains(book),
                        onToggleWishlist: { wishlist.toggle(book) }
                    )
                }
            }
            .padding(20)
        }
    }

    private var skeletonGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(0..<12, id: \.self) { _ in SkeletonCard() }
            }
            .padding(20)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Genre chip

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

// MARK: - Skeleton card (loading)

private struct SkeletonCard: View {
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

// MARK: - Prompt (online off / token missing)

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
            ? theme.styledText(terminal: "add_hardcover_token_in_settings",
                               native: "Add your Hardcover API token in Settings to browse.")
            : theme.styledText(terminal: "enable_online_metadata_in_settings",
                               native: "Turn on “Fetch metadata online” in Settings to browse Hardcover.")
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

// MARK: - Empty / failed message

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
    let books = (1...8).map { i in
        DiscoveryBook(id: "\(i)", title: "Sample Book \(i)", author: "An Author",
                      coverURL: nil,
                      hardcoverURL: URL(string: "https://hardcover.app/books/sample-\(i)")!,
                      rating: 4.0 + Double(i % 5) / 10)
    }
    return DiscoveryView(wishlist: WishlistService(modelContext: container.mainContext, toasts: toasts))
        .modelContainer(container)
        .environment(DiscoveryViewModel.preview(.loaded(books)))
        .environment(AppSettings())
        .environment(\.theme, .black)
        .frame(width: 820, height: 620)
}

#Preview("Discovery – disabled") {
    let container = PersistenceController.inMemory()
    let toasts = ToastCenter()
    DiscoveryView(wishlist: WishlistService(modelContext: container.mainContext, toasts: toasts))
        .modelContainer(container)
        .environment(DiscoveryViewModel.preview(.disabledOnline))
        .environment(AppSettings())
        .environment(\.theme, .black)
        .frame(width: 820, height: 620)
}
#endif
