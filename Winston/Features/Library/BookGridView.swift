import SwiftUI
import SwiftData
import OSLog

struct BookGridView: View {
    let books: [Book]
    let selection: BookSelectionModel
    var deviceFileNames: Set<String> = []
    let conversion: ConversionService
    let health: LibraryHealthService
    var collections: [BookCollection] = []
    let actions: BookActions
    let onClick: (Book) -> Void
    @Binding var scrollTarget: Book.ID?

    @Environment(AppSettings.self) private var settings

    private var convertingUUIDs: Set<UUID> { conversion.convertingUUIDs }
    private var missingUUIDs: Set<UUID> { health.missingFileUUIDs }

    private var columns: [GridItem] { WinstonLayout.coverGridColumns(zoom: settings.gridZoom) }

    private var convertibleInSelection: Int {
        books.filter { selection.isSelected($0) && EbookConverter.needsConversion(format: $0.format) }.count
    }

    private var onDeviceInSelection: Int {
        books.filter { selection.isSelected($0) && deviceFileNames.contains($0.deviceMatchKey) }.count
    }

    var body: some View {
        ScrollViewReader { proxy in
            scrollContent
                .onChange(of: scrollTarget) {
                    guard let target = scrollTarget else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    scrollTarget = nil
                }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(books) { book in
                    BookCardView(
                        book: book,
                        isSelected: selection.isSelected(book),
                        isOnDevice: deviceFileNames.contains(book.deviceMatchKey),
                        isConverting: convertingUUIDs.contains(book.uuid),
                        isMissing: missingUUIDs.contains(book.uuid),
                        onDelete: { actions.delete(book) }
                    )
                    .onTapGesture { onClick(book) }
                    .onDrag { NSItemProvider(contentsOf: book.fileURL) ?? NSItemProvider() }
                    .contextMenu {
                        BookContextMenu(
                            book: book,
                            selectionCount: selection.count,
                            isInSelection: selection.isSelected(book),
                            convertibleInSelection: convertibleInSelection,
                            collections: collections,
                            isOnDevice: deviceFileNames.contains(book.deviceMatchKey),
                            onDeviceInSelection: onDeviceInSelection,
                            actions: actions
                        )
                    }
                    .accessibilityLabel("\(book.displayTitle), \(book.displayAuthor ?? "unknown author"), \(book.format)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
    }
}
