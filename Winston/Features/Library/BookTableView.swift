import SwiftUI
import SwiftData

struct BookTableView: View {
    let books: [Book]
    @Bindable var selection: BookSelectionModel
    var deviceFileNames: Set<String>
    let conversion: ConversionService
    let editions: CatalogReconciliationService
    var collections: [BookCollection] = []
    let actions: BookActions
    @Binding var sortPreference: LibrarySortPreference

    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings
    @AppStorage("bookTableColumnCustomization") private var columnCustomization = TableColumnCustomization<Book>()

    private var convertingUUIDs: Set<UUID> { conversion.convertingUUIDs }

    var body: some View {
        Table(
            books,
            selection: tableSelection,
            sortOrder: tableSortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("") { book in
                BookCoverImageView(book: book, tier: .thumb)
                    .frame(width: 26, height: 38)
                    .clipShape(
                        RoundedRectangle(cornerRadius: WinstonLayout.cornerSmall, style: .continuous)
                    )
            }
            .width(34)
            .customizationID("cover")

            TableColumn(columnTitle("Title", terminal: "title"), value: \.displayTitle) { book in
                HStack(spacing: 6) {
                    Text(book.displayTitle)
                        .font(theme.body(size: 12, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if convertingUUIDs.contains(book.uuid) {
                        ProgressView().controlSize(.small)
                    }
                    if book.isOnDevice(fileNames: deviceFileNames) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.success)
                            .help("On device")
                    }
                }
            }
            .width(min: 200, ideal: 420, max: 720)
            .customizationID("title")

            TableColumn(columnTitle("Author", terminal: "author"), value: \.sortAuthor) { book in
                Text(book.displayAuthor ?? "\u{2014}")
                    .font(theme.label(size: 11, weight: .regular))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 220, max: 360)
            .customizationID("author")

            TableColumn(columnTitle("Format", terminal: "fmt"), value: \.format) { book in
                Text(book.format.isEmpty ? "\u{2014}" : book.format)
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.accentSecondary)
            }
            .width(70)
            .customizationID("format")

            TableColumn(columnTitle("Shelf", terminal: "shelf")) { book in
                Text(book.shelfLocation ?? "\u{2014}")
                    .font(theme.label(size: 10, weight: .regular))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 120, max: 220)
            .defaultVisibility(.hidden)
            .customizationID("shelf")

            TableColumn(columnTitle("Editions", terminal: "editions")) { book in
                Text((editions.editionCounts[book.uuid] ?? 1).formatted())
                    .font(theme.label(size: 10, weight: .regular))
                    .foregroundStyle(theme.textSecondary)
            }
            .width(70)
            .defaultVisibility(.hidden)
            .customizationID("editions")

            TableColumn(columnTitle("Translator", terminal: "translator")) { book in
                Text(book.translator ?? "\u{2014}")
                    .font(theme.label(size: 10, weight: .regular))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 170, max: 280)
            .defaultVisibility(.hidden)
            .customizationID("translator")

            TableColumn(columnTitle("Size", terminal: "size")) { book in
                Text(book.fileSizeDisplay)
                    .font(theme.label(size: 10, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
            }
            .width(80)
            .customizationID("size")

            TableColumn(columnTitle("Added", terminal: "added"), value: \.dateAdded) { book in
                Text(book.dateAdded, format: .dateTime.day().month().year())
                    .font(theme.label(size: 10, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 110, max: 140)
            .customizationID("added")
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Book.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first, let book = books.first(where: { $0.id == id }) {
                actions.open(book)
            }
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<Book.ID>) -> some View {
        let chosen = books.filter { ids.contains($0.id) }
        if let book = primaryBook(in: chosen) {
            BookContextMenu(
                book: book,
                availability: actionAvailability(for: chosen, primary: book),
                isInSelection: selection.isSelected(book),
                collections: collections,
                isOnDevice: book.isOnDevice(fileNames: deviceFileNames),
                actions: actions
            )
        }
    }

    private var tableSelection: Binding<Set<Book.ID>> {
        Binding(
            get: { selection.selectedBookIDs },
            set: { newSelection in
                let added = newSelection.subtracting(selection.selectedBookIDs)
                selection.selectedBookIDs = newSelection
                if let addedID = added.first {
                    selection.lastClickedBookID = addedID
                } else if let lastClicked = selection.lastClickedBookID,
                          !newSelection.contains(lastClicked) {
                    selection.lastClickedBookID = newSelection.first
                }
            }
        )
    }

    /// SwiftUI's Table sorting API still speaks in comparators. Keep that bridge
    /// here so the rest of the library uses a stable, persistable preference.
    private var tableSortOrder: Binding<[KeyPathComparator<Book>]> {
        Binding(
            get: { [sortPreference.comparator] },
            set: { newOrder in
                guard let comparator = newOrder.first else { return }
                let ascending = comparator.order == .forward
                guard let field = BookSort.allCases.first(where: {
                    comparator == $0.comparator(ascending: ascending)
                }) else { return }
                sortPreference = LibrarySortPreference(field: field, ascending: ascending)
            }
        )
    }

    private func primaryBook(in books: [Book]) -> Book? {
        if let lastClicked = selection.lastClickedBookID,
           let primary = books.first(where: { $0.id == lastClicked }) {
            return primary
        }
        return books.first
    }

    private func actionAvailability(
        for books: [Book],
        primary: Book
    ) -> BookActionAvailability {
        BookActionAvailability(
            selectionCount: books.count,
            hasPrimarySelection: true,
            primaryHasPersistedDigitalFile: primary.hasCatalogDigitalFile,
            persistedDigitalFileCount: books.filter(\.hasCatalogDigitalFile).count,
            sendableDigitalFileCount: books.filter {
                $0.hasCatalogDigitalFile && $0.primaryDRMProtected != true
            }.count,
            drmProtectedDigitalFileCount: books.filter {
                $0.hasCatalogDigitalFile && $0.primaryDRMProtected == true
            }.count,
            conversionEligibleCount: books.filter {
                $0.hasCatalogDigitalFile
                    && $0.primaryDRMProtected != true
                    && EbookConverter.needsConversion(format: $0.format)
                    && conversion.canConvertForKindle($0.format)
            }.count,
            calibreAvailable: conversion.isCalibreAvailable,
            onlineMetadataEnabled: settings.onlineMetadataEnabled,
            onDeviceSelectionCount: books.filter {
                $0.isOnDevice(fileNames: deviceFileNames)
            }.count
        )
    }

    private func columnTitle(_ native: LocalizedStringKey, terminal: String) -> LocalizedStringKey {
        theme.usesTerminalCopy ? LocalizedStringKey(stringLiteral: terminal) : native
    }
}
