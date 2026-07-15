import SwiftData
import SwiftUI

struct NoticesView: View {
    let notices: NoticeService
    let viewModel: LibraryViewModel
    let onOpenSeries: (String) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            ThemedBackground()

            if notices.notices.isEmpty {
                NoticesEmptyFeed(
                    notices: notices,
                    releaseCheckAvailable: gatingReason == nil,
                    gatingReason: gatingReason,
                    lastCheckFailed: notices.lastCheckFailed
                )
            } else {
                NoticesFeed(
                    items: notices.notices,
                    notices: notices,
                    viewModel: viewModel,
                    gatingReason: gatingReason,
                    lastCheckFailed: notices.lastCheckFailed,
                    onOpenSeries: onOpenSeries
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(theme.usesTerminalCopy ? Text(verbatim: "") : Text("Updates"))
        .toolbar {
            NoticesToolbar(notices: notices)
        }
    }

    private var gatingReason: NoticesGatingBanner.Reason? {
        if !settings.onlineMetadataEnabled { return .onlineDisabled }
        if settings.hardcoverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .tokenMissing
        }
        if !settings.releaseCheckEnabled { return .checkDisabled }
        return nil
    }
}

// MARK: - Feed

private struct NoticesFeed: View {
    let items: [LibraryNotice]
    let notices: NoticeService
    let viewModel: LibraryViewModel
    let gatingReason: NoticesGatingBanner.Reason?
    let lastCheckFailed: Bool
    let onOpenSeries: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                NoticesMasthead(unreadCount: notices.unreadCount)
                    .padding(.bottom, 16)

                if let gatingReason {
                    NoticesGatingBanner(reason: gatingReason)
                        .padding(.bottom, 16)
                } else if lastCheckFailed {
                    NoticesFailureBanner(notices: notices)
                        .padding(.bottom, 16)
                }

                if let latest = items.first {
                    NoticeFeaturedStory(
                        notice: latest,
                        notices: notices,
                        viewModel: viewModel,
                        onOpenSeries: onOpenSeries
                    )
                    .padding(.bottom, 28)
                }

                if items.count > 1 {
                    NoticesSectionHeader()
                        .padding(.bottom, 12)

                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(items.dropFirst()) { notice in
                            NoticeTimelineRow(
                                notice: notice,
                                notices: notices,
                                viewModel: viewModel,
                                onOpenSeries: onOpenSeries
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct NoticesMasthead: View {
    let unreadCount: Int

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.accent)
                theme.styledText(terminal: "// updates", native: "Updates")
                    .font(theme.display(size: 22, weight: .heavy))
                    .foregroundStyle(theme.textPrimary)

                Spacer(minLength: 16)

                if unreadCount > 0 {
                    Group {
                        if theme.usesTerminalCopy {
                            Text(verbatim: "\(unreadCount) unread")
                        } else {
                            Text("\(unreadCount) unread")
                        }
                    }
                    .font(theme.label(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(theme.accent.opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(theme.accent.opacity(0.25), lineWidth: 1))
                }
            }

            theme.styledText(
                terminal: "a reading journal for your library",
                native: "A reading journal for your library — new releases, what to read next, and the books you’ve finished."
            )
            .font(theme.body(size: 13, weight: .regular))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct NoticesSectionHeader: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            theme.styledText(terminal: "EARLIER", native: "Earlier Updates")
                .font(theme.label(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Rectangle()
                .fill(theme.borderSubtle)
                .frame(height: 1)
        }
    }
}

// MARK: - Empty state

private struct NoticesEmptyFeed: View {
    let notices: NoticeService
    let releaseCheckAvailable: Bool
    let gatingReason: NoticesGatingBanner.Reason?
    let lastCheckFailed: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            NoticesMasthead(unreadCount: 0)
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 16)

            if let gatingReason {
                NoticesGatingBanner(reason: gatingReason)
                    .frame(maxWidth: 860)
                    .padding(.horizontal, 20)
            } else if lastCheckFailed {
                NoticesFailureBanner(notices: notices)
                    .frame(maxWidth: 860)
                    .padding(.horizontal, 20)
            }

            ContentUnavailableView {
                Label {
                    theme.styledText(terminal: "no_new_updates", native: "You’re all caught up")
                } icon: {
                    Image(systemName: "newspaper")
                }
            } description: {
                theme.styledText(
                    terminal: "new releases, recommendations and rating prompts land here",
                    native: "New releases from your series, reading recommendations, and rating prompts will appear here."
                )
            } actions: {
                if releaseCheckAvailable {
                    Button {
                        Task { await notices.checkForNewReleases() }
                    } label: {
                        Label {
                            theme.styledText(terminal: "check_now", native: "Check Now")
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(notices.isChecking)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Toolbar

private struct NoticesToolbar: ToolbarContent {
    let notices: NoticeService

    @Environment(\.theme) private var theme

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                notices.markAllRead()
            } label: {
                Label("Mark all as read", systemImage: "checkmark.circle")
            }
            .disabled(notices.unreadCount == 0)
            .help(theme.styledText(terminal: "mark_all_read", native: "Mark all as read"))

            Button {
                Task { await notices.checkForNewReleases() }
            } label: {
                if notices.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Check for new releases", systemImage: "arrow.clockwise")
                }
            }
            .disabled(!notices.releaseCheckAvailable || notices.isChecking)
            .help(theme.styledText(terminal: "check_for_new_releases", native: "Check for new releases"))
        }
    }
}

// MARK: - Release status

struct NoticesGatingBanner: View {
    enum Reason {
        case onlineDisabled
        case tokenMissing
        case checkDisabled
    }

    let reason: Reason

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            message
                .font(theme.body(size: 12, weight: .regular))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            SettingsLink {
                theme.styledText(terminal: "settings", native: "Open Settings")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 10, tintOpacity: 0.35)
    }

    private var icon: String {
        switch reason {
        case .onlineDisabled: "network.slash"
        case .tokenMissing:   "key"
        case .checkDisabled:  "bell.slash"
        }
    }

    private var message: Text {
        switch reason {
        case .onlineDisabled:
            theme.styledText(
                terminal: "release_alerts_off // enable online metadata",
                native: "Enable online metadata to get alerts about new series releases."
            )
        case .tokenMissing:
            theme.styledText(
                terminal: "release_alerts_off // add hardcover token",
                native: "Add a Hardcover API token to get alerts about new series releases."
            )
        case .checkDisabled:
            theme.styledText(
                terminal: "release_alerts_off // check disabled",
                native: "Checking for new series releases is turned off."
            )
        }
    }
}

private struct NoticesFailureBanner: View {
    let notices: NoticeService

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.destructive)
            theme.styledText(
                terminal: "release_check_failed",
                native: "The last check for new releases failed."
            )
            .font(theme.body(size: 12, weight: .regular))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button {
                Task { await notices.checkForNewReleases() }
            } label: {
                theme.styledText(terminal: "retry", native: "Try Again")
            }
            .controlSize(.small)
            .disabled(notices.isChecking)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 10, tintOpacity: 0.35)
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func makePreviewModel(theme: Theme) -> (LibraryViewModel, ModelContainer) {
    let container = PersistenceController.inMemory()
    let context = container.mainContext

    let book = Book(fileName: "prvni-dil.epub", originalFileName: "První díl.epub")
    book.title = "První díl"
    book.author = "Jana Nováková"
    book.series = "Kroniky"
    book.seriesIndex = "1"
    context.insert(book)

    let release = LibraryNotice(
        dedupeKey: "release:1",
        kind: .newRelease,
        dateCreated: .now,
        bookTitle: "Třetí díl"
    )
    release.seriesName = "Kroniky"
    release.author = "Jana Nováková"
    release.positionText = "3"
    release.hardcoverBookID = "1"
    release.hardcoverURLString = "https://hardcover.app/books/treti-dil"
    release.releaseDateRaw = "2026-05-14"
    context.insert(release)

    let next = LibraryNotice(
        dedupeKey: "next:\(book.uuid)",
        kind: .nextInSeries,
        dateCreated: .now.addingTimeInterval(-86_400),
        bookTitle: "První díl"
    )
    next.seriesName = "Kroniky"
    next.author = "Jana Nováková"
    next.bookUUID = book.uuid
    next.readAt = .now
    context.insert(next)

    let rate = LibraryNotice(
        dedupeKey: "rate:\(book.uuid)",
        kind: .ratingPrompt,
        dateCreated: .now.addingTimeInterval(-172_800),
        bookTitle: "První díl"
    )
    rate.author = "Jana Nováková"
    rate.bookUUID = book.uuid
    context.insert(rate)
    try? context.save()

    let viewModel = LibraryViewModel(modelContext: context, settings: AppSettings(), toasts: ToastCenter())
    return (viewModel, container)
}

#Preview("Black") {
    let (viewModel, container) = makePreviewModel(theme: .black)
    NoticesView(notices: viewModel.notices, viewModel: viewModel, onOpenSeries: { _ in })
        .modelContainer(container)
        .environment(AppSettings())
        .environment(ToastCenter())
        .environment(\.theme, .black)
        .tint(Theme.black.accent)
        .preferredColorScheme(.dark)
        .frame(width: 820, height: 680)
}

#Preview("Purple") {
    let (viewModel, container) = makePreviewModel(theme: .purple)
    NoticesView(notices: viewModel.notices, viewModel: viewModel, onOpenSeries: { _ in })
        .modelContainer(container)
        .environment(AppSettings())
        .environment(ToastCenter())
        .environment(\.theme, .purple)
        .tint(Theme.purple.accent)
        .preferredColorScheme(.dark)
        .frame(width: 820, height: 680)
}

#Preview("White") {
    let (viewModel, container) = makePreviewModel(theme: .white)
    NoticesView(notices: viewModel.notices, viewModel: viewModel, onOpenSeries: { _ in })
        .modelContainer(container)
        .environment(AppSettings())
        .environment(ToastCenter())
        .environment(\.theme, .white)
        .tint(Theme.white.accent)
        .preferredColorScheme(.light)
        .frame(width: 820, height: 680)
}
#endif
