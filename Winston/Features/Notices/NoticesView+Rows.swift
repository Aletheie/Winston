import AppKit
import SwiftUI

struct NoticeFeaturedStory: View {
    let notice: LibraryNotice
    let notices: NoticeService
    let viewModel: LibraryViewModel
    let onOpenSeries: (String) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme

    private var book: Book? { notices.book(for: notice) }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            NoticeStoryCover(notice: notice, book: book, cornerRadius: 10)
                .frame(width: 148, height: 222)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.24), radius: 9, y: 5)

            VStack(alignment: .leading, spacing: 13) {
                NoticeStoryMeta(
                    notice: notice,
                    notices: notices,
                    presentation: .featured
                )

                NoticeStoryCopy(notice: notice, presentation: .featured)

                Spacer(minLength: 2)

                NoticeActions(
                    notice: notice,
                    book: book,
                    notices: notices,
                    viewModel: viewModel,
                    presentation: .featured,
                    onOpenSeries: onOpenSeries,
                    openURL: openURL
                )
            }
            .frame(maxWidth: .infinity, minHeight: 222, alignment: .topLeading)
        }
        .padding(24)
        .glassCard(cornerRadius: 16, tintOpacity: 0.5)
        .overlay {
            if notice.isUnread {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.accent.opacity(0.38), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.10), radius: 18, y: 9)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            NoticeManagementActions(notice: notice, notices: notices)
        }
        .accessibilityElement(children: .contain)
    }
}

struct NoticeTimelineRow: View {
    let notice: LibraryNotice
    let notices: NoticeService
    let viewModel: LibraryViewModel
    let onOpenSeries: (String) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme

    private var book: Book? { notices.book(for: notice) }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            NoticeStoryCover(notice: notice, book: book)
                .frame(width: 60, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 2)

            VStack(alignment: .leading, spacing: 8) {
                NoticeStoryMeta(
                    notice: notice,
                    notices: notices,
                    presentation: .timeline
                )

                NoticeStoryCopy(notice: notice, presentation: .timeline)

                NoticeActions(
                    notice: notice,
                    book: book,
                    notices: notices,
                    viewModel: viewModel,
                    presentation: .timeline,
                    onOpenSeries: onOpenSeries,
                    openURL: openURL
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .glassCard(cornerRadius: 12, tintOpacity: 0.35)
        .overlay {
            if notice.isUnread {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.accent.opacity(0.3), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            NoticeManagementActions(notice: notice, notices: notices)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Story typography

private enum NoticeStoryPresentation {
    case featured
    case timeline
}

private struct NoticeStoryMeta: View {
    let notice: LibraryNotice
    let notices: NoticeService
    let presentation: NoticeStoryPresentation

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: presentation == .featured ? 10 : 7) {
            NoticeKindLabel(kind: notice.kind, presentation: presentation)

            Spacer(minLength: 8)

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

            NoticeDateLabel(date: notice.dateCreated)

            NoticeMoreMenu(notice: notice, notices: notices)
        }
    }
}

private struct NoticeKindLabel: View {
    let kind: NoticeKind?
    let presentation: NoticeStoryPresentation

    @Environment(\.theme) private var theme

    var body: some View {
        Label {
            theme.styledText(terminal: terminalTitle, native: nativeTitle)
        } icon: {
            Image(systemName: icon)
        }
        .font(theme.label(
            size: presentation == .featured ? 11 : 10,
            weight: .semibold
        ))
        .foregroundStyle(tint)
        .lineLimit(1)
    }

    private var terminalTitle: String {
        switch kind {
        case .newRelease:   "new_release"
        case .nextInSeries: "next_to_read"
        case .ratingPrompt: "your_review"
        case nil:           "library_update"
        }
    }

    private var nativeTitle: LocalizedStringKey {
        switch kind {
        case .newRelease:   "New Release"
        case .nextInSeries: "Next to Read"
        case .ratingPrompt: "Your Review"
        case nil:           "Library update"
        }
    }

    private var icon: String {
        switch kind {
        case .newRelease:   "sparkles"
        case .nextInSeries: "books.vertical.fill"
        case .ratingPrompt: "star.bubble.fill"
        case nil:           "bell.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .newRelease:   theme.accent
        case .nextInSeries: theme.accentSecondary
        case .ratingPrompt: theme.accentTertiary
        case nil:           theme.textSecondary
        }
    }
}

private struct NoticeDateLabel: View {
    let date: Date

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if theme.usesTerminalCopy {
                Text(verbatim: date.formatted(date: .numeric, time: .omitted))
            } else {
                Text(date, format: .relative(presentation: .named))
            }
        }
        .font(theme.label(size: 10, weight: .regular))
        .foregroundStyle(theme.textSecondary)
        .lineLimit(1)
    }
}

private struct NoticeStoryCopy: View {
    let notice: LibraryNotice
    let presentation: NoticeStoryPresentation

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: presentation == .featured ? 9 : 4) {
            headline
                .font(theme.display(
                    size: presentation == .featured ? 26 : 17,
                    weight: presentation == .featured ? .bold : .semibold
                ))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(presentation == .featured ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)

            summary
                .font(theme.body(
                    size: presentation == .featured ? 13 : 11,
                    weight: .regular
                ))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(presentation == .featured ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)

            if let metadataLine {
                Text(verbatim: metadataLine)
                    .font(theme.label(size: presentation == .featured ? 11 : 10, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var headline: Text {
        switch notice.kind {
        case .newRelease:
            if theme.usesTerminalCopy {
                return Text(verbatim: "new_release: \(notice.bookTitle)")
            }
            return Text("\(notice.bookTitle) is out now")
        case .nextInSeries:
            if theme.usesTerminalCopy {
                return Text(verbatim: "continue_with: \(notice.bookTitle)")
            }
            return Text("Continue with \(notice.bookTitle)")
        case .ratingPrompt:
            if theme.usesTerminalCopy {
                return Text(verbatim: "your_review: \(notice.bookTitle)")
            }
            return Text("What did you think of \(notice.bookTitle)?")
        case nil:
            return theme.styledText(terminal: "library_update", native: "Library update")
        }
    }

    private var summary: Text {
        switch notice.kind {
        case .newRelease:
            if theme.usesTerminalCopy {
                return Text(verbatim: "a new book from \(seriesLabel) is available")
            }
            return Text("A new book from \(seriesLabel) is now available.")
        case .nextInSeries:
            if theme.usesTerminalCopy {
                return Text(verbatim: "the next unread book in \(seriesLabel) is in your library")
            }
            return Text("The next unread book in \(seriesLabel) is already in your library.")
        case .ratingPrompt:
            return theme.styledText(
                terminal: "rate it while the story is still fresh",
                native: "Add a rating while the story is still fresh."
            )
        case nil:
            return theme.styledText(
                terminal: "something new in your library",
                native: "There’s something new in your library."
            )
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
            parts.append(
                theme.usesTerminalCopy
                    ? "book_\(position)"
                    : String(localized: "Book \(position)")
            )
        }
        if let date = notice.releaseDateRaw.flatMap(DiscoveryReleaseDate.init(iso8601:)) {
            parts.append(date.iso8601)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Story actions

private struct NoticeActions: View {
    let notice: LibraryNotice
    let book: Book?
    let notices: NoticeService
    let viewModel: LibraryViewModel
    let presentation: NoticeStoryPresentation
    let onOpenSeries: (String) -> Void
    let openURL: OpenURLAction

    var body: some View {
        HStack(spacing: 8) {
            switch notice.kind {
            case .newRelease:
                NoticeReleaseActions(
                    notice: notice,
                    notices: notices,
                    presentation: presentation,
                    openURL: openURL
                )
            case .nextInSeries:
                NoticeNextBookActions(
                    notice: notice,
                    book: book,
                    notices: notices,
                    presentation: presentation,
                    onOpenSeries: onOpenSeries
                )
            case .ratingPrompt:
                NoticeRatingActions(
                    notice: notice,
                    book: book,
                    notices: notices,
                    viewModel: viewModel,
                    presentation: presentation
                )
            case nil:
                EmptyView()
            }
        }
        .controlSize(presentation == .featured ? .regular : .small)
    }
}

private struct NoticeReleaseActions: View {
    let notice: LibraryNotice
    let notices: NoticeService
    let presentation: NoticeStoryPresentation
    let openURL: OpenURLAction

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            NoticeWishlistButton(
                notice: notice,
                notices: notices,
                presentation: presentation
            )

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
                .buttonStyle(.bordered)
                .tint(theme.accent)
            }
        }
    }
}

private struct NoticeWishlistButton: View {
    let notice: LibraryNotice
    let notices: NoticeService
    let presentation: NoticeStoryPresentation

    @Environment(\.theme) private var theme

    var body: some View {
        let isWishlisted = notices.isWishlisted(notice)

        if presentation == .featured {
            Button {
                notices.toggleWishlist(from: notice)
            } label: {
                wishlistLabel(isWishlisted: isWishlisted)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
        } else {
            Button {
                notices.toggleWishlist(from: notice)
            } label: {
                wishlistLabel(isWishlisted: isWishlisted)
            }
            .buttonStyle(.bordered)
            .tint(theme.accent)
        }
    }

    private func wishlistLabel(isWishlisted: Bool) -> some View {
        Label {
            theme.styledText(
                terminal: isWishlisted ? "on_wishlist" : "add_to_wishlist",
                native: isWishlisted ? "On Wishlist" : "Add to Wishlist"
            )
        } icon: {
            Image(systemName: isWishlisted ? "heart.fill" : "heart")
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

private struct NoticeNextBookActions: View {
    let notice: LibraryNotice
    let book: Book?
    let notices: NoticeService
    let presentation: NoticeStoryPresentation
    let onOpenSeries: (String) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        if let book {
            HStack(spacing: 8) {
                NoticeReadButton(
                    notice: notice,
                    book: book,
                    notices: notices,
                    presentation: presentation
                )

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
            }
        } else {
            NoticeMissingBookLabel()
        }
    }
}

private struct NoticeReadButton: View {
    let notice: LibraryNotice
    let book: Book
    let notices: NoticeService
    let presentation: NoticeStoryPresentation

    @Environment(\.theme) private var theme

    var body: some View {
        if presentation == .featured {
            Button(action: openBook) {
                label
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
        } else {
            Button(action: openBook) {
                label
            }
            .buttonStyle(.bordered)
            .tint(theme.accent)
        }
    }

    private var label: some View {
        Label {
            theme.styledText(terminal: "read_now", native: "Read now")
        } icon: {
            Image(systemName: "book")
        }
    }

    private func openBook() {
        notices.markRead(notice)
        LibraryExternalActions.openInReader(book)
    }
}

private struct NoticeRatingActions: View {
    let notice: LibraryNotice
    let book: Book?
    let notices: NoticeService
    let viewModel: LibraryViewModel
    let presentation: NoticeStoryPresentation

    var body: some View {
        if let book {
            NoticeRatingStars(
                rating: book.rating,
                isLarge: presentation == .featured,
                onSelect: { rating in
                    viewModel.updateRating(for: book, rating: rating)
                    notices.markRead(notice)
                }
            )
        } else {
            NoticeMissingBookLabel()
        }
    }
}

private struct NoticeMissingBookLabel: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Label {
            theme.styledText(terminal: "no_longer_in_library", native: "No longer in your library")
        } icon: {
            Image(systemName: "questionmark.circle")
        }
        .font(theme.label(size: 11, weight: .medium))
        .foregroundStyle(theme.textSecondary)
    }
}

private struct NoticeRatingStars: View {
    let rating: Int?
    let isLarge: Bool
    let onSelect: (Int?) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: isLarge ? 5 : 3) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    onSelect(rating == star ? nil : star)
                } label: {
                    Image(systemName: (rating ?? 0) >= star ? "star.fill" : "star")
                        .font(.system(size: isLarge ? 17 : 13))
                        .foregroundStyle((rating ?? 0) >= star ? theme.highlight : theme.textSecondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(Text("Rate \(star) out of 5"))
                .accessibilityLabel(Text("Rate \(star) out of 5"))
            }
        }
    }
}

// MARK: - Management actions

private struct NoticeMoreMenu: View {
    let notice: LibraryNotice
    let notices: NoticeService

    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            NoticeManagementActions(notice: notice, notices: notices)
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(theme.styledText(terminal: "more_actions", native: "More actions"))
        .accessibilityLabel(theme.styledText(terminal: "more_actions", native: "More actions"))
    }
}

private struct NoticeManagementActions: View {
    let notice: LibraryNotice
    let notices: NoticeService

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if notice.isUnread {
                Button {
                    notices.markRead(notice)
                } label: {
                    Label {
                        theme.styledText(terminal: "mark_as_read", native: "Mark as read")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                }
            } else {
                Button {
                    notices.markUnread(notice)
                } label: {
                    Label {
                        theme.styledText(terminal: "mark_as_unread", native: "Mark as unread")
                    } icon: {
                        Image(systemName: "circle")
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                notices.delete(notice)
            } label: {
                Label {
                    theme.styledText(terminal: "delete", native: "Delete")
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
    }
}

// MARK: - Covers

private struct NoticeStoryCover: View {
    let notice: LibraryNotice
    let book: Book?
    var cornerRadius: CGFloat = 6

    var body: some View {
        ZStack {
            if notice.kind == .newRelease {
                NoticeRemoteCover(
                    id: notice.hardcoverBookID ?? notice.dedupeKey,
                    url: notice.coverURL
                )
            } else if let book {
                BookCoverImageView(book: book, tier: .thumb)
            } else {
                NoticeCoverPlaceholder(seed: notice.dedupeKey)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
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
        let index = palettes.isEmpty
            ? 0
            : Int(seed.hashValue.magnitude % UInt(palettes.count))
        let pair = palettes.isEmpty
            ? ColorPair(primary: theme.accent, secondary: theme.accentSecondary)
            : palettes[index]
        BookCoverArt(accent1: pair.primary, accent2: pair.secondary)
    }
}
