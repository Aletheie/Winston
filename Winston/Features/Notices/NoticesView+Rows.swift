import AppKit
import SwiftUI

struct NoticeRow: View {
    let notice: LibraryNotice
    let notices: NoticeService
    let viewModel: LibraryViewModel
    let onOpenSeries: (String) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme

    private var book: Book? { notices.book(for: notice) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NoticeUnreadControl(notice: notice, notices: notices)
                .frame(width: 10, height: 63)

            NoticeCover(notice: notice, book: book)
                .frame(width: 42, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                NoticeCopy(notice: notice)
                NoticeActions(
                    notice: notice,
                    book: book,
                    notices: notices,
                    viewModel: viewModel,
                    onOpenSeries: onOpenSeries,
                    openURL: openURL
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if theme.usesTerminalCopy {
                    Text(verbatim: notice.dateCreated.formatted(date: .numeric, time: .omitted))
                } else {
                    Text(notice.dateCreated, format: .relative(presentation: .named))
                }
            }
            .font(theme.label(size: 10, weight: .regular))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if notice.isUnread {
                Button("Mark as read", systemImage: "checkmark.circle") {
                    notices.markRead(notice)
                }
            } else {
                Button("Mark as unread", systemImage: "circle") {
                    notices.markUnread(notice)
                }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                notices.delete(notice)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct NoticeUnreadControl: View {
    let notice: LibraryNotice
    let notices: NoticeService

    @Environment(\.theme) private var theme

    var body: some View {
        VStack {
            if notice.isUnread {
                Button {
                    notices.markRead(notice)
                } label: {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 7, height: 7)
                        .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(.plain)
                .help("Mark as read")
                .accessibilityLabel("Mark as read")
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

private struct NoticeCopy: View {
    let notice: LibraryNotice

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            title
                .font(theme.body(size: 13, weight: notice.isUnread ? .semibold : .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)

            if let detail = metadataLine {
                Text(verbatim: detail)
                    .font(theme.label(size: 10, weight: .regular))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var title: Text {
        switch notice.kind {
        case .newRelease:
            if theme.usesTerminalCopy {
                return Text(verbatim: "new in \(seriesLabel): \(notice.bookTitle)")
            }
            return Text("New in \(seriesLabel): \(notice.bookTitle)")
        case .nextInSeries:
            if theme.usesTerminalCopy {
                return Text(verbatim: "next in \(seriesLabel): \(notice.bookTitle)")
            }
            return Text("Next in \(seriesLabel): \(notice.bookTitle)")
        case .ratingPrompt:
            if theme.usesTerminalCopy {
                return Text(verbatim: "how was \(notice.bookTitle)?")
            }
            return Text("How was \(notice.bookTitle)?")
        case nil:
            return theme.styledText(terminal: "library update", native: "Library update")
        }
    }

    private var seriesLabel: String {
        guard let series = notice.seriesName, !series.isEmpty else {
            return String(localized: "your series")
        }
        return series
    }

    private var metadataLine: String? {
        var parts: [String] = []
        if let author = notice.author, !author.isEmpty { parts.append(author) }
        if let position = notice.positionText, !position.isEmpty {
            parts.append(theme.usesTerminalCopy ? "book \(position)" : String(localized: "Book \(position)"))
        }
        if let date = notice.releaseDateRaw.flatMap(DiscoveryReleaseDate.init(iso8601:)) {
            parts.append(date.iso8601)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct NoticeActions: View {
    let notice: LibraryNotice
    let book: Book?
    let notices: NoticeService
    let viewModel: LibraryViewModel
    let onOpenSeries: (String) -> Void
    let openURL: OpenURLAction

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            switch notice.kind {
            case .newRelease:
                releaseActions
            case .nextInSeries:
                nextBookActions
            case .ratingPrompt:
                ratingActions
            case nil:
                EmptyView()
            }
        }
        .font(theme.label(size: 11, weight: .medium))
    }

    @ViewBuilder
    private var releaseActions: some View {
        Button {
            notices.toggleWishlist(from: notice)
        } label: {
            Label {
                theme.styledText(
                    terminal: notices.isWishlisted(notice) ? "on_wishlist" : "add_to_wishlist",
                    native: notices.isWishlisted(notice) ? "On Wishlist" : "Add to Wishlist"
                )
            } icon: {
                Image(systemName: notices.isWishlisted(notice) ? "heart.fill" : "heart")
            }
        }
        .buttonStyle(.bordered)
        .tint(theme.accent)

        if let url = notice.hardcoverURL {
            Button {
                notices.markRead(notice)
                openURL(url)
            } label: {
                Label {
                    theme.styledText(terminal: "hardcover", native: "Open on Hardcover")
                } icon: {
                    Image(systemName: "arrow.up.right.square")
                }
            }
            .buttonStyle(.borderless)
            .tint(theme.accent)
        }
    }

    @ViewBuilder
    private var nextBookActions: some View {
        if let book {
            if let series = notice.seriesName, !series.isEmpty {
                Button {
                    notices.markRead(notice)
                    onOpenSeries(series)
                } label: {
                    Label {
                        theme.styledText(terminal: "show_series", native: "Show series")
                    } icon: {
                        Image(systemName: "books.vertical")
                    }
                }
                .buttonStyle(.bordered)
                .tint(theme.accent)
            }

            Button {
                notices.markRead(notice)
                LibraryExternalActions.openInReader(book)
            } label: {
                Label {
                    theme.styledText(terminal: "read_now", native: "Read now")
                } icon: {
                    Image(systemName: "book")
                }
            }
            .buttonStyle(.borderless)
            .tint(theme.accent)
        } else {
            Label {
                theme.styledText(
                    terminal: "no_longer_in_library",
                    native: "No longer in your library"
                )
            } icon: {
                Image(systemName: "questionmark.circle")
            }
            .foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder
    private var ratingActions: some View {
        if let book {
            NoticeRatingStars(
                rating: book.rating,
                onSelect: { rating in
                    viewModel.updateRating(for: book, rating: rating)
                    notices.markRead(notice)
                }
            )
        } else {
            Label {
                theme.styledText(
                    terminal: "no_longer_in_library",
                    native: "No longer in your library"
                )
            } icon: {
                Image(systemName: "questionmark.circle")
            }
            .foregroundStyle(theme.textSecondary)
        }
    }
}

private struct NoticeRatingStars: View {
    let rating: Int?
    let onSelect: (Int?) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    onSelect(rating == star ? nil : star)
                } label: {
                    Image(systemName: (rating ?? 0) >= star ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundStyle((rating ?? 0) >= star ? theme.highlight : theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(Text("Rate \(star) out of 5"))
                .accessibilityLabel(Text("Rate \(star) out of 5"))
            }
        }
    }
}

private struct NoticeCover: View {
    let notice: LibraryNotice
    let book: Book?

    var body: some View {
        ZStack {
            if notice.kind == .newRelease {
                NoticeRemoteCover(id: notice.hardcoverBookID ?? notice.dedupeKey, url: notice.coverURL)
            } else if let book {
                BookCoverImageView(book: book, tier: .thumb)
            } else {
                NoticeCoverPlaceholder(seed: notice.dedupeKey)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

private struct NoticeRemoteCover: View {
    let id: String
    let url: URL?

    @State private var image: NSImage?

    var body: some View {
        NoticeCoverPlaceholder(seed: id)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: url) {
                image = nil
                guard let url else { return }
                image = await DiscoveryImageLoader.shared.image(for: url)
            }
    }
}

private struct NoticeCoverPlaceholder: View {
    let seed: String

    @Environment(\.theme) private var theme

    var body: some View {
        let palettes = theme.coverPalettes
        let index = palettes.isEmpty ? 0 : Int(seed.hashValue.magnitude % UInt(palettes.count))
        let pair = palettes.isEmpty
            ? ColorPair(primary: theme.accent, secondary: theme.accentSecondary)
            : palettes[index]
        BookCoverArt(accent1: pair.primary, accent2: pair.secondary)
    }
}
