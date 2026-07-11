import SwiftUI

struct WishlistView: View {
    let wishlist: WishlistService
    let onBrowseDiscover: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme

    private var columns: [GridItem] {
        WinstonLayout.coverGridColumns(zoom: settings.gridZoom)
    }

    var body: some View {
        VStack(spacing: 0) {
            WishlistHeader(count: wishlist.count)
            Divider().opacity(0.3)

            if wishlist.items.isEmpty {
                ContentUnavailableView {
                    Label("No books on your Wishlist", systemImage: "heart")
                } description: {
                    Text("Add books from Discover and they’ll wait here until you import them.")
                } actions: {
                    Button("Browse Discover", action: onBrowseDiscover)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(wishlist.items) { item in
                            DiscoveryCardView(
                                book: item.discoveryBook,
                                externalBookURL: ExternalBookSearchURL.make(
                                    websiteURL: settings.externalBookWebsiteURL,
                                    title: item.title,
                                    author: item.author
                                ),
                                isWishlisted: true,
                                onToggleWishlist: { wishlist.remove(item) }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemedBackground())
        .navigationTitle(theme.usesTerminalCopy ? Text(verbatim: "") : Text("Wishlist"))
    }
}

private struct WishlistHeader: View {
    let count: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "heart.fill")
                .foregroundStyle(theme.accent)
            theme.styledText(terminal: "// wishlist", native: "Wishlist")
                .font(theme.display(size: 22, weight: .heavy))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Text(count, format: .number)
                .font(theme.label(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .monospacedDigit()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(theme.surfaceGlass, in: Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

private extension WishlistItem {
    var discoveryBook: DiscoveryBook {
        DiscoveryBook(
            id: hardcoverID,
            title: title,
            author: author,
            coverURL: coverURLString.flatMap(URL.init(string:)),
            hardcoverURL: URL(string: hardcoverURLString)
                ?? URL(string: "https://hardcover.app")!,
            rating: rating
        )
    }
}
