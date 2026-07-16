import SwiftUI

struct DiscoveryCardView: View {
    let book: DiscoveryBook
    let externalBookURL: URL?
    let isWishlisted: Bool
    let onToggleWishlist: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isShowingActions = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                isShowingActions.toggle()
            } label: {
                DiscoveryBookLinkContent(
                    bookID: book.id,
                    title: book.title,
                    author: book.author,
                    coverURL: book.coverURL,
                    rating: book.rating,
                    releaseDate: book.releaseDate,
                    isWishlisted: isWishlisted
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .top)
            .help("Book actions")
            .accessibilityLabel(Text(verbatim: accessibilityText))
            .accessibilityHint("Shows actions for this book")
        }
        .popover(isPresented: $isShowingActions, arrowEdge: .bottom) {
            DiscoveryCardActionPopover(
                hardcoverURL: book.hardcoverURL,
                externalBookURL: externalBookURL,
                isWishlisted: isWishlisted,
                onToggleWishlist: onToggleWishlist
            )
        }
        .contextMenu {
            DiscoveryCardActions(
                hardcoverURL: book.hardcoverURL,
                externalBookURL: externalBookURL,
                isWishlisted: isWishlisted,
                onToggleWishlist: onToggleWishlist
            )
        }
        .glassCard(cornerRadius: WinstonLayout.cornerLarge)
        .overlay {
            RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge, style: .continuous)
                .stroke(isHovered ? theme.accent.opacity(0.4) : theme.borderSubtle,
                        lineWidth: 1)
        }
        .scaleEffect(isHovered && !reduceMotion ? 1.01 : 1.0)
        .shadow(color: .black.opacity(isHovered ? 0.14 : 0.07),
                radius: isHovered ? 6 : 3, y: isHovered ? 2 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge, style: .continuous))
        .onHover { isHovered = $0 }
    }

    private var accessibilityText: String {
        var parts = [book.title]
        if let author = book.author { parts.append(author) }
        return parts.joined(separator: ", ")
    }
}

private struct DiscoveryCardActionPopover: View {
    let hardcoverURL: URL
    let externalBookURL: URL?
    let isWishlisted: Bool
    let onToggleWishlist: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 2) {
            DiscoveryPopoverActionButton(
                title: "Open on Hardcover",
                systemImage: "books.vertical"
            ) {
                dismiss()
                openURL(hardcoverURL)
            }

            if let externalBookURL {
                DiscoveryPopoverActionButton(
                    title: "Search External Website",
                    systemImage: "magnifyingglass"
                ) {
                    dismiss()
                    openURL(externalBookURL)
                }
            }

            Divider()
                .padding(.vertical, 4)

            DiscoveryPopoverActionButton(
                title: isWishlisted ? "Remove from Wishlist" : "Add to Wishlist",
                systemImage: isWishlisted ? "heart.slash" : "heart"
            ) {
                dismiss()
                onToggleWishlist()
            }
        }
        .padding(8)
        .frame(width: 240)
    }
}

private struct DiscoveryPopoverActionButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .frame(width: 18)
            }
            .font(theme.body(size: 12, weight: .medium))
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? theme.accent.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct DiscoveryCardActions: View {
    let hardcoverURL: URL
    let externalBookURL: URL?
    let isWishlisted: Bool
    let onToggleWishlist: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(hardcoverURL) } label: {
            Label("Open on Hardcover", systemImage: "books.vertical")
        }

        if let externalBookURL {
            Button { openURL(externalBookURL) } label: {
                Label("Search External Website", systemImage: "magnifyingglass")
            }
        }

        Divider()

        Button(action: onToggleWishlist) {
            if isWishlisted {
                Label("Remove from Wishlist", systemImage: "heart.slash")
            } else {
                Label("Add to Wishlist", systemImage: "heart")
            }
        }
    }
}

private struct DiscoveryBookLinkContent: View {
    let bookID: String
    let title: String
    let author: String?
    let coverURL: URL?
    let rating: Double?
    let releaseDate: DiscoveryReleaseDate?
    let isWishlisted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DiscoveryCoverImageView(bookID: bookID, coverURL: coverURL)
                .frame(maxWidth: .infinity)
                .aspectRatio(WinstonLayout.coverAspect, contentMode: .fill)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(6)
            DiscoveryTitleStrip(
                title: title,
                author: author,
                rating: rating,
                releaseDate: releaseDate,
                isWishlisted: isWishlisted
            )
        }
        .contentShape(Rectangle())
    }
}

private struct DiscoveryTitleStrip: View {
    let title: String
    let author: String?
    let rating: Double?
    let releaseDate: DiscoveryReleaseDate?
    let isWishlisted: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title)
                .font(theme.body(size: 12, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)

            if let author {
                Text(verbatim: author)
                    .font(theme.label(size: 9))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            } else {
                Text("Author not listed")
                    .font(theme.label(size: 9))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                if let date = releaseDate?.date {
                    Text(date, format: .dateTime.day().month(.abbreviated).year())
                        .font(theme.label(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                if let rating {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.highlight)
                    Text(rating.formatted(.number.precision(.fractionLength(1))))
                        .font(theme.label(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                if isWishlisted {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

private struct DiscoveryCoverImageView: View {
    let bookID: String
    let coverURL: URL?

    @Environment(\.theme) private var theme
    @State private var image: NSImage?

    var body: some View {
        let accents = palette
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    BookCoverArt(accent1: accents.primary, accent2: accents.secondary)
                }
            }
            .clipped()
            .task(id: coverURL) {
                image = nil
                guard let coverURL else { return }
                image = await DiscoveryImageLoader.shared.image(for: coverURL)
            }
    }

    private var palette: ColorPair {
        let palettes = theme.coverPalettes
        guard !palettes.isEmpty else { return ColorPair(primary: theme.accent, secondary: theme.accentSecondary) }
        let index = bookID.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % palettes.count }
        return palettes[index]
    }
}

#if DEBUG
#Preview("Discovery card") {
    DiscoveryCardView(book: DiscoveryBook(
        id: "1",
        title: "The Fifth Season",
        author: "N. K. Jemisin",
        coverURL: nil,
        hardcoverURL: URL(string: "https://hardcover.app/books/the-fifth-season")!,
        rating: 4.3
    ), externalBookURL: URL(string: "https://example.com/search?q=The+Fifth+Season"),
       isWishlisted: false, onToggleWishlist: {})
    .frame(width: 180)
    .padding(24)
    .background(ThemedBackground())
    .environment(\.theme, .black)
}
#endif
