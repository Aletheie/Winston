import SwiftUI
import OSLog

struct DeviceView: View {
    var books: [Book]
    var viewModel: LibraryViewModel

    @Environment(\.theme) private var theme
    @Environment(DeviceMonitor.self) private var monitor
    @Environment(TransferQueue.self) private var transferQueue
    @Environment(ToastCenter.self) private var toasts
    @State private var selectedDeviceBooks: Set<DeviceBook.ID> = []
    @State private var isCleaningSidecars = false
    @State private var sidecarSummary: String?
    @State private var deviceRows: [DeviceBookRow] = []
    @State private var deviceAuthors: [String] = []
    @State private var showsSyncPlan = false

    private var deviceOnlyBooks: [DeviceBook] {
        let libraryKeys = Set(books.map(\.deviceMatchKey))
        return monitor.books.filter { !libraryKeys.contains($0.matchKey) }
    }

    private func authorByDeviceKey() -> [String: String] {
        Dictionary(
            books.compactMap { book in book.displayAuthor.map { (book.deviceMatchKey, $0) } },
            uniquingKeysWith: { first, _ in first }
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
        .onChange(of: LibraryMutationLog.shared.revision, initial: true) { rebuildRows() }
        .onChange(of: monitor.books) { rebuildRows() }
        .sheet(isPresented: $showsSyncPlan) {
            KindleSyncPlanSheet(books: books)
        }
    }

    private func rebuildRows() {
        let rows = DeviceTableQuery.rows(books: monitor.books, authorByMatchKey: authorByDeviceKey())
        deviceRows = rows
        deviceAuthors = DeviceTableQuery.authors(in: rows)
    }

    @ViewBuilder
    private func connectedBody(info: DeviceInfo) -> some View {
        VStack(spacing: 0) {
            DeviceHeader(
                info: info,
                bookCount: monitor.books.count,
                deviceOnlyCount: deviceOnlyBooks.count,
                isBusy: transferQueue.isTransferring,
                isImportingHighlights: viewModel.isImportingHighlights,
                isCleaningSidecars: isCleaningSidecars,
                onPlan: { showsSyncPlan = true },
                onImport: importAllFromDevice,
                onRefresh: { Task { await monitor.refreshBooks(); await monitor.refreshInfo() } },
                onImportHighlights: { viewModel.importHighlights(via: monitor) },
                onCleanSidecars: info.kind == .massStorage ? { cleanSidecars() } : nil,
                onDisconnect: { Task { await monitor.userDisconnect() } }
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
                    rows: deviceRows,
                    authors: deviceAuthors,
                    selection: $selectedDeviceBooks,
                    onCopy: copyToLibrary,
                    onDelete: deleteFromDevice,
                    onDeleteByAuthor: deleteByAuthor
                )
            }
        }
    }

    // MARK: - Actions

    private func importAllFromDevice() {
        copyToLibrary(Set(deviceOnlyBooks.map(\.id)))
    }

    private func deleteByAuthor(_ author: String) {
        let authorByKey = authorByDeviceKey()
        let ids = Set(monitor.books.filter { authorByKey[$0.matchKey] == author }.map(\.id))
        deleteFromDevice(ids)
    }

    private func copyToLibrary(_ ids: Set<DeviceBook.ID>) {
        let books = monitor.books.filter { ids.contains($0.id) }
        Task {
            for book in books {
                guard let url = await transferQueue.copyToLibrary(book, via: monitor) else { break }
                viewModel.addBooks(from: [url])
            }
        }
    }

    private func cleanSidecars() {
        guard let connection = monitor.connection, !isCleaningSidecars else { return }
        isCleaningSidecars = true
        Task {
            defer { isCleaningSidecars = false }
            do {
                let removed = try await connection.removeAppleDoubleSidecars()
                sidecarSummary = removed == 0
                    ? String(localized: "No hidden macOS files found")
                    : String(localized: "Removed \(removed) hidden macOS files")
            } catch {
                sidecarSummary = error.localizedDescription
            }
        }
    }

    private func deleteFromDevice(_ ids: Set<DeviceBook.ID>) {
        let books = monitor.books.filter { ids.contains($0.id) }
        Task {
            guard let connection = monitor.connection else { return }
            var deleted: Set<DeviceBook.ID> = []
            var failed = 0
            for book in books {
                do {
                    try await connection.delete(book)
                    deleted.insert(book.id)
                } catch {
                    failed += 1
                    Log.device.error("Delete from device failed for \(book.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if failed > 0 {
                toasts.error(String(localized: "Some books couldn\u{2019}t be deleted from the Kindle (\(failed))."))
            }
            selectedDeviceBooks.subtract(deleted)
            monitor.removeBooksLocally(deleted)
            await monitor.refreshInfo()
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
                        .background(RoundedRectangle(cornerRadius: 3).fill(theme.accentSecondary.opacity(0.15)))
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
                    .help("Import highlights & notes from this device")
                }
                if let onCleanSidecars {
                    if isCleaningSidecars {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(action: onCleanSidecars) {
                            Image(systemName: "wand.and.sparkles")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .help("Remove hidden macOS files that can confuse the Kindle indexer")
                    }
                }
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("Refresh device contents")

                Button(action: onDisconnect) {
                    Image(systemName: "eject")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("Disconnect (eject) the Kindle so it re-indexes sideloaded books")
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
            Text(storageText)
                .font(theme.label(size: 9, weight: .regular))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var usedFraction: Double {
        guard info.totalBytes > 0 else { return 0 }
        return Double(info.usedBytes) / Double(info.totalBytes)
    }

    private var storageText: String {
        let free = ByteCountFormatter.string(fromByteCount: Int64(info.freeBytes), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(info.totalBytes), countStyle: .file)
        return "\(free) free of \(total)"
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
