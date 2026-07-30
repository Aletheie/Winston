import SwiftUI
import OSLog

struct DeviceView: View {
    var books: [Book]
    let readModel: LibraryReadModel
    var viewModel: LibraryViewModel

    @Environment(\.theme) private var theme
    @Environment(DeviceMonitor.self) private var monitor
    @Environment(TransferQueue.self) private var transferQueue
    @Environment(ToastCenter.self) private var toasts
    @State private var selectedDeviceBooks: Set<DeviceBook.ID> = []
    @State private var activeOperation: DeviceOperation?
    @State private var sidecarCleanupTask: Task<Void, Never>?
    @State private var sidecarSummary: String?
    @State private var projection = DeviceProjection.unbuilt
    @State private var showsSyncPlan = false

    private struct DeviceProjection {
        let rows: [DeviceBookRow]
        let authors: [String]
        let deviceOnlyBooks: [DeviceBook]
        let authorByDeviceKey: [String: String]
        let revision: DeviceProjectionRevision?

        static let unbuilt = DeviceProjection(
            rows: [],
            authors: [],
            deviceOnlyBooks: [],
            authorByDeviceKey: [:],
            revision: nil
        )
    }

    private enum DeviceOperation: Equatable {
        case refreshing
        case copyingToLibrary
        case importingHighlights
        case cleaningSidecars
        case deleting
        case ejecting
    }

    private var projectionRevision: DeviceProjectionRevision {
        DeviceProjectionRevision(
            catalog: readModel.generation,
            readModelIsReady: readModel.isReady,
            device: monitor.booksRevision
        )
    }

    var body: some View {
        Group {
            if let info = monitor.info {
                connectedBody(info: info)
            } else {
                DeviceDisconnectedState()
            }
        }
        .background { ThemedBackground() }
        .navigationTitle(monitor.info.map { "On \($0.name)" } ?? "Device")
        .task(id: projectionRevision) {
            let revision = projectionRevision
            let deviceBooks = monitor.books
            let libraryBooks = books
            if projection.revision != nil {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
            }
            await rebuildProjection(
                revision: revision,
                deviceBooks: deviceBooks,
                libraryBooks: libraryBooks
            )
        }
        .task(id: monitor.info?.identifier) {
            guard monitor.info != nil else { return }
            await monitor.refreshBooks()
            await transferQueue.resumePending(via: monitor)
        }
        .sheet(isPresented: $showsSyncPlan) {
            KindleSyncPlanSheet(books: books, readModel: readModel)
        }
        .onChange(of: monitor.info?.identifier) {
            cancelSidecarCleanup()
        }
        .onDisappear {
            cancelSidecarCleanup()
        }
    }

    private func rebuildProjection(
        revision: DeviceProjectionRevision,
        deviceBooks: [DeviceBook],
        libraryBooks: [Book]
    ) async {
        let metadata: LibraryDeviceMetadataSnapshot?
        if deviceBooks.isEmpty || !revision.readModelIsReady {
            metadata = nil
        } else {
            metadata = await readModel.deviceMetadata()
            guard metadata?.generation == revision.catalog else { return }
        }

        let authorMap = metadata?.authorByDeviceKey ?? Dictionary(
            libraryBooks.flatMap { book in
                book.displayAuthor.map { author in
                    book.deviceMatchKeys.map { ($0, author) }
                } ?? []
            },
            uniquingKeysWith: { first, _ in first }
        )
        let libraryKeys = metadata?.libraryKeys
            ?? Set(libraryBooks.flatMap(\.deviceMatchKeys))
        let rows = DeviceTableQuery.rows(
            books: deviceBooks,
            authorByMatchKey: authorMap
        )
        let value = DeviceProjection(
            rows: rows,
            authors: DeviceTableQuery.authors(in: rows),
            deviceOnlyBooks: deviceBooks.filter {
                !libraryKeys.contains($0.matchKey)
            },
            authorByDeviceKey: authorMap,
            revision: revision
        )
        guard DeviceProjectionPublicationPolicy.shouldPublish(
            captured: revision,
            current: projectionRevision,
            isCancelled: Task.isCancelled
        ) else { return }

        projection = value
        selectedDeviceBooks = DeviceProjectionPublicationPolicy.pruneSelection(
            selectedDeviceBooks,
            to: value.rows
        )
    }

    @ViewBuilder
    private func connectedBody(info: DeviceInfo) -> some View {
        VStack(spacing: 0) {
            DeviceHeader(
                info: info,
                bookCount: monitor.books.count,
                deviceOnlyCount: projection.deviceOnlyBooks.count,
                isBusy: isDeviceBusy,
                isImportingHighlights: viewModel.isImportingHighlights,
                isCleaningSidecars: activeOperation == .cleaningSidecars,
                isEjecting: activeOperation == .ejecting || monitor.isEjecting,
                onPlan: { showsSyncPlan = true },
                onImport: importAllFromDevice,
                onRefresh: refreshDevice,
                onImportHighlights: importHighlights,
                onCleanSidecars: info.kind == .massStorage ? { cleanSidecars() } : nil,
                onDisconnect: ejectDevice
            )
            .padding(16)
            .background(.ultraThinMaterial)

            if let summary = viewModel.highlightImportSummary ?? sidecarSummary {
                Text(summary)
                    .font(theme.label(size: 10))
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            Divider()

            if monitor.books.isEmpty {
                DeviceEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DeviceLibrarySection(
                    rows: projection.rows,
                    authors: projection.authors,
                    selection: $selectedDeviceBooks,
                    onCopy: copyToLibrary,
                    onDelete: deleteFromDevice,
                    onDeleteByAuthor: deleteByAuthor
                )
            }
        }
    }

    // MARK: - Actions

    private var isDeviceBusy: Bool {
        activeOperation != nil
            || transferQueue.isTransferring
            || viewModel.isImportingHighlights
            || monitor.isEjecting
    }

    private func begin(_ operation: DeviceOperation) -> Bool {
        guard !isDeviceBusy else { return false }
        activeOperation = operation
        return true
    }

    private func finish(_ operation: DeviceOperation) {
        if activeOperation == operation {
            activeOperation = nil
        }
    }

    private func importAllFromDevice() {
        copyToLibrary(Set(projection.deviceOnlyBooks.map(\.id)))
    }

    private func deleteByAuthor(_ author: String) {
        let ids = Set(monitor.books.filter {
            projection.authorByDeviceKey[$0.matchKey] == author
        }.map(\.id))
        deleteFromDevice(ids)
    }

    private func copyToLibrary(_ ids: Set<DeviceBook.ID>) {
        let books = monitor.books.filter { ids.contains($0.id) }
        guard !books.isEmpty else { return }
        Task {
            guard begin(.copyingToLibrary) else { return }
            defer { finish(.copyingToLibrary) }
            for book in books {
                guard let lease = await transferQueue.copyToLibrary(book, via: monitor) else { break }
                viewModel.addBooks(from: [.winstonOwned(lease)])
            }
        }
    }

    private func refreshDevice() {
        Task {
            guard begin(.refreshing) else { return }
            defer { finish(.refreshing) }
            await monitor.refreshBooks()
            await monitor.refreshInfo()
        }
    }

    private func importHighlights() {
        Task {
            guard begin(.importingHighlights) else { return }
            defer { finish(.importingHighlights) }
            await viewModel.importHighlights(via: monitor)
        }
    }

    private func cleanSidecars() {
        if activeOperation == .cleaningSidecars {
            cancelSidecarCleanup()
            return
        }
        guard let connection = monitor.connection else { return }
        guard begin(.cleaningSidecars) else { return }
        sidecarSummary = nil
        sidecarCleanupTask = Task {
            defer {
                sidecarCleanupTask = nil
                finish(.cleaningSidecars)
            }
            do {
                let removed = try await connection.removeAppleDoubleSidecars()
                sidecarSummary = removed == 0
                    ? String(localized: "No hidden macOS files found")
                    : String(localized: "Removed \(removed) hidden macOS files")
            } catch is CancellationError {
                sidecarSummary = nil
            } catch {
                sidecarSummary = error.localizedDescription
            }
        }
    }

    private func cancelSidecarCleanup() {
        sidecarCleanupTask?.cancel()
        sidecarCleanupTask = nil
        finish(.cleaningSidecars)
    }

    private func ejectDevice() {
        Task {
            guard begin(.ejecting) else { return }
            defer { finish(.ejecting) }
            do {
                try await monitor.userDisconnect()
            } catch {
                toasts.error(String(
                    localized: "Couldn’t eject the Kindle. \(error.localizedDescription)"
                ))
            }
        }
    }

    private func deleteFromDevice(_ ids: Set<DeviceBook.ID>) {
        Task {
            guard begin(.deleting) else { return }
            defer { finish(.deleting) }
            let result = await monitor.removeFromDevice(ids: ids)
            let deleted = Set(result.appliedTargetIDs.compactMap(\.deviceBookID))
            if result.completion == .failed || result.conflictCount > 0 {
                toasts.error(String(
                    localized: "Some books couldn\u{2019}t be deleted from the Kindle (\(result.conflictCount + result.pendingTargetIDs.count))."
                ))
            }
            selectedDeviceBooks.subtract(deleted)
        }
    }
}

// MARK: - Header

private struct DeviceHeader: View {
    let info: DeviceInfo
    let bookCount: Int
    let deviceOnlyCount: Int
    let isBusy: Bool
    let isImportingHighlights: Bool
    let isCleaningSidecars: Bool
    let isEjecting: Bool
    let onPlan: () -> Void
    let onImport: () -> Void
    let onRefresh: () -> Void
    let onImportHighlights: () -> Void
    let onCleanSidecars: (() -> Void)?
    let onDisconnect: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "ipad.landscape")
                .font(.system(size: 30, weight: .thin))
                .foregroundStyle(theme.success)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(info.name)
                        .font(theme.body(size: 16, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Text(info.kind == .mtp ? "MTP" : "USB")
                        .font(theme.label(size: 9, weight: .semibold))
                        .foregroundStyle(theme.accentSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: WinstonLayout.cornerSmall)
                                .fill(theme.accentSecondary.opacity(0.15))
                        )
                    Text("\(bookCount) books")
                        .font(theme.label(size: 10, weight: .regular))
                        .foregroundStyle(theme.textTertiary)
                }

                DeviceStorageBar(info: info)
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: onPlan) {
                    Label("Review Sync Plan", systemImage: "list.bullet.clipboard")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isBusy)
                .help("Preview additions, updates, cover repairs, unchanged books, and optional removals before changing the Kindle.")

                Button(action: onImport) {
                    Label("Import \(deviceOnlyCount) to Library", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(deviceOnlyCount == 0 || isBusy)
                .help("Copies books on the Kindle that aren\u{2019}t in your library yet into your library.")

                if isImportingHighlights {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: onImportHighlights) {
                        Image(systemName: "quote.bubble")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isBusy)
                    .help("Import highlights & notes from this device")
                    .accessibilityLabel("Import highlights & notes from this device")
                }
                if let onCleanSidecars {
                    if isCleaningSidecars {
                        Button(action: onCleanSidecars) {
                            ProgressView().controlSize(.small)
                        }
                        .buttonStyle(.borderless)
                        .help("Cancel")
                        .accessibilityLabel("Cancel")
                    } else {
                        Button(action: onCleanSidecars) {
                            Image(systemName: "wand.and.sparkles")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .disabled(isBusy)
                        .help("Remove hidden macOS files that can confuse the Kindle indexer")
                        .accessibilityLabel("Remove hidden macOS files that can confuse the Kindle indexer")
                    }
                }
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .help("Refresh device contents")
                .accessibilityLabel("Refresh device contents")

                if isEjecting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Ejecting the Kindle")
                } else {
                    Button(action: onDisconnect) {
                        Image(systemName: "eject")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(isBusy)
                    .help("Disconnect (eject) the Kindle so it re-indexes sideloaded books")
                    .accessibilityLabel("Disconnect (eject) the Kindle so it re-indexes sideloaded books")
                }
            }
        }
    }
}

private struct DeviceStorageBar: View {
    let info: DeviceInfo

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: usedFraction)
                .tint(theme.accent)
                .frame(maxWidth: 360)
            storageText
                .font(theme.label(size: 9, weight: .regular))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var usedFraction: Double {
        guard info.totalBytes > 0 else { return 0 }
        return Double(info.usedBytes) / Double(info.totalBytes)
    }

    private var storageText: Text {
        let free = ByteCountFormatter.string(fromByteCount: Int64(info.freeBytes), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(info.totalBytes), countStyle: .file)
        return Text(
            "\(free) free of \(total)",
            comment: "Device storage: the first value is free space and the second is total capacity."
        )
    }
}

// MARK: - Empty states

private struct DeviceEmptyState: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ContentUnavailableView {
            Label(theme.usesTerminalCopy ? "// device_empty" : "No books on this device",
                  systemImage: "books.vertical")
        } description: {
            Text(theme.usesTerminalCopy ? "send books from your library" : "Send books from your library to get started")
                .font(theme.label(size: 11))
        }
    }
}

private struct DeviceDisconnectedState: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ContentUnavailableView {
            Label(theme.usesTerminalCopy ? "// no_device_connected" : "No device connected",
                  systemImage: "cable.connector")
        } description: {
            Text(theme.usesTerminalCopy ? "connect a kindle via usb" : "Connect a Kindle with a USB cable")
                .font(theme.label(size: 11))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
