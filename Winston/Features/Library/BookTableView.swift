import SwiftUI
import SwiftData

struct BookTableView: View {
    let books: [Book]
    @Bindable var selection: BookSelectionModel
    var deviceFileNames: Set<String>
    let conversion: ConversionService
    let editions: EditionService
    var collections: [BookCollection] = []
    let actions: BookActions
    @Binding var sortOrder: [KeyPathComparator<Book>]

    @Environment(\.theme) private var theme
    @AppStorage("bookTableColumnCustomization") private var columnCustomization = TableColumnCustomization<Book>()

    private var convertingUUIDs: Set<UUID> { conversion.convertingUUIDs }

    var body: some View {
        Table(
            books,
            selection: $selection.selectedBookIDs,
            sortOrder: $sortOrder,
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
                    if deviceFileNames.contains(book.deviceMatchKey) {
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
        let convertible = chosen.filter { $0.hasDigitalFile && EbookConverter.needsConversion(format: $0.format) }.count
        let onDevice = chosen.filter { deviceFileNames.contains($0.deviceMatchKey) }.count
        if chosen.count == 1, let book = chosen.first {
            BookContextMenu(
                book: book,
                selectionCount: selection.count,
                isInSelection: selection.isSelected(book),
                convertibleInSelection: convertible,
                collections: collections,
                isOnDevice: deviceFileNames.contains(book.deviceMatchKey),
                onDeviceInSelection: onDevice,
                actions: actions
            )
        } else if chosen.count > 1 {
            if convertible > 0 {
                Button { actions.convertSelection() } label: {
                    Label("Convert \(convertible) for Kindle", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
            }
            if onDevice > 0 {
                Button(role: .destructive) { actions.removeSelectionFromDevice() } label: {
                    Label("Remove \(onDevice) from Kindle", systemImage: "externaldrive.badge.minus")
                }
            }
            Button(role: .destructive) { actions.deleteSelection() } label: {
                Label("Delete \(chosen.count) Books", systemImage: "trash")
            }
        }
    }

    private func columnTitle(_ native: LocalizedStringKey, terminal: String) -> LocalizedStringKey {
        theme.usesTerminalCopy ? LocalizedStringKey(stringLiteral: terminal) : native
    }
}
