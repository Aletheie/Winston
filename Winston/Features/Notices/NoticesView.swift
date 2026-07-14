import SwiftUI
import SwiftData

struct NoticesView: View {
    let notices: NoticeService
    let viewModel: LibraryViewModel
    let onOpenSeries: (String) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            NoticesHeader(notices: notices)
            Divider().opacity(0.3)

            if let reason = gatingReason {
                NoticesGatingBanner(reason: reason)
            } else if notices.lastCheckFailed {
                NoticesFailureBanner(notices: notices)
            }

            if notices.notices.isEmpty {
                NoticesEmptyState(
                    notices: notices,
                    releaseCheckAvailable: gatingReason == nil
                )
            } else {
                NoticesList(
                    items: notices.notices,
                    notices: notices,
                    viewModel: viewModel,
                    onOpenSeries: onOpenSeries
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemedBackground())
        .navigationTitle(theme.usesTerminalCopy ? Text(verbatim: "") : Text("Updates"))
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

// MARK: - Content

private struct NoticesList: View {
    let items: [LibraryNotice]
    let notices: NoticeService
    let viewModel: LibraryViewModel
    let onOpenSeries: (String) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        List(items) { notice in
            NoticeRow(
                notice: notice,
                notices: notices,
                viewModel: viewModel,
                onOpenSeries: onOpenSeries
            )
            .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(theme.borderSubtle)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

private struct NoticesEmptyState: View {
    let notices: NoticeService
    let releaseCheckAvailable: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        ContentUnavailableView {
            if theme.usesTerminalCopy {
                Label { Text(verbatim: "no_new_updates") } icon: { Image(systemName: "bell") }
            } else {
                Label("You’re all caught up", systemImage: "bell")
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
                    theme.styledText(terminal: "check_now", native: "Check Now")
                }
                .buttonStyle(.borderedProminent)
                .disabled(notices.isChecking)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Header

private struct NoticesHeader: View {
    let notices: NoticeService

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .foregroundStyle(theme.accent)
            theme.styledText(terminal: "// updates", native: "Updates")
                .font(theme.display(size: 22, weight: .heavy))
                .foregroundStyle(theme.textPrimary)
            if notices.unreadCount > 0 {
                NoticesUnreadBadge(count: notices.unreadCount)
            }
            Spacer()
            Button {
                notices.markAllRead()
            } label: {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(notices.unreadCount > 0 ? theme.textSecondary : theme.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(notices.unreadCount == 0)
            .help(theme.styledText(terminal: "mark_all_read", native: "Mark all as read"))

            Button {
                Task { await notices.checkForNewReleases() }
            } label: {
                if notices.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(notices.releaseCheckAvailable ? theme.textSecondary : theme.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!notices.releaseCheckAvailable || notices.isChecking)
            .help(theme.styledText(terminal: "check_for_new_releases", native: "Check for new releases"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

private struct NoticesUnreadBadge: View {
    let count: Int

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if theme.usesTerminalCopy {
                Text(verbatim: "\(count) unread")
            } else {
                Text("\(count) unread")
            }
        }
        .font(theme.label(size: 11, weight: .semibold))
        .foregroundStyle(theme.background)
        .monospacedDigit()
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(theme.accent, in: Capsule())
    }
}

// MARK: - Gating & failure banners

private struct NoticesGatingBanner: View {
    enum Reason {
        case onlineDisabled
        case tokenMissing
        case checkDisabled
    }

    let reason: Reason

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(theme.textSecondary)
            message
                .font(theme.body(size: 12))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            SettingsLink {
                theme.styledText(terminal: "settings", native: "Open Settings")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 8)
        .padding(.horizontal, 20)
        .padding(.top, 12)
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
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.destructive)
            theme.styledText(
                terminal: "release_check_failed",
                native: "The last check for new releases failed."
            )
            .font(theme.body(size: 12))
            .foregroundStyle(theme.textSecondary)
            Spacer()
            Button {
                Task { await notices.checkForNewReleases() }
            } label: {
                theme.styledText(terminal: "retry", native: "Try Again")
            }
            .controlSize(.small)
            .disabled(notices.isChecking)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 8)
        .padding(.horizontal, 20)
        .padding(.top, 12)
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

    let release = LibraryNotice(dedupeKey: "release:1", kind: .newRelease, bookTitle: "Třetí díl")
    release.seriesName = "Kroniky"
    release.author = "Jana Nováková"
    release.hardcoverBookID = "1"
    release.hardcoverURLString = "https://hardcover.app/books/treti-dil"
    release.releaseDateRaw = "2026-05-14"
    context.insert(release)

    let next = LibraryNotice(dedupeKey: "next:\(book.uuid)", kind: .nextInSeries, bookTitle: "První díl")
    next.seriesName = "Kroniky"
    next.author = "Jana Nováková"
    next.bookUUID = book.uuid
    next.readAt = .now
    context.insert(next)

    let rate = LibraryNotice(dedupeKey: "rate:\(book.uuid)", kind: .ratingPrompt, bookTitle: "První díl")
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
        .frame(width: 700, height: 500)
}

#Preview("Purple") {
    let (viewModel, container) = makePreviewModel(theme: .purple)
    NoticesView(notices: viewModel.notices, viewModel: viewModel, onOpenSeries: { _ in })
        .modelContainer(container)
        .environment(AppSettings())
        .environment(ToastCenter())
        .environment(\.theme, .purple)
        .frame(width: 700, height: 500)
}

#Preview("White") {
    let (viewModel, container) = makePreviewModel(theme: .white)
    NoticesView(notices: viewModel.notices, viewModel: viewModel, onOpenSeries: { _ in })
        .modelContainer(container)
        .environment(AppSettings())
        .environment(ToastCenter())
        .environment(\.theme, .white)
        .frame(width: 700, height: 500)
}
#endif
