import SwiftUI
import SwiftData
import OSLog
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let winstonBookReference = UTType(exportedAs: "cz.annajung.Winston.book-reference")
}

struct BookDragItem: Codable, Sendable, Transferable {
    let bookID: UUID
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .winstonBookReference)
        ProxyRepresentation(exporting: \.fileURL)
    }
}

private struct BookFileDragModifier: ViewModifier {
    let book: Book

    @ViewBuilder
    func body(content: Content) -> some View {
        if let fileURL = book.primaryFileURL {
            content.draggable(BookDragItem(bookID: book.uuid, fileURL: fileURL))
        } else {
            content
        }
    }
}

struct BookGridView: View {
    let books: [Book]
    let selection: BookSelectionModel
    var deviceFileNames: Set<String> = []
    let conversion: ConversionService
    let health: LibraryHealthService
    let editions: CatalogReconciliationService
    var collections: [BookCollection] = []
    let actions: BookActions
    let onClick: (Book) -> Void
    @Binding var scrollTarget: Book.ID?

    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedBookID: Book.ID?

    private var convertingUUIDs: Set<UUID> { conversion.convertingUUIDs }
    private var missingUUIDs: Set<UUID> { health.missingFileUUIDs }

    private var columns: [GridItem] { WinstonLayout.coverGridColumns(zoom: settings.gridZoom) }

    private var convertibleInSelection: Int {
        books.filter { selection.isSelected($0) && EbookConverter.needsConversion(format: $0.format) }.count
    }

    private var onDeviceInSelection: Int {
        books.filter { selection.isSelected($0) && $0.isOnDevice(fileNames: deviceFileNames) }.count
    }

    var body: some View {
        ScrollViewReader { proxy in
            scrollContent
                .onChange(of: scrollTarget) {
                    guard let target = scrollTarget else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
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
                        isOnDevice: book.isOnDevice(fileNames: deviceFileNames),
                        isConverting: convertingUUIDs.contains(book.uuid),
                        isMissing: missingUUIDs.contains(book.uuid),
                        editionCount: editions.editionCounts[book.uuid] ?? 1,
                        onDelete: { actions.delete(book) }
                    )
                    .overlay {
                        if focusedBookID == book.id {
                            RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge + 2, style: .continuous)
                                .stroke(theme.accent, lineWidth: 2)
                                .padding(1)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        focusedBookID = book.id
                        actions.open(book)
                    }
                    .onTapGesture {
                        focusedBookID = book.id
                        onClick(book)
                    }
                    .modifier(BookFileDragModifier(book: book))
                    .focusable()
                    .focused($focusedBookID, equals: book.id)
                    .onMoveCommand { direction in
                        moveFocus(from: book, direction: direction)
                    }
                    .onKeyPress(.return) {
                        actions.open(book)
                        return .handled
                    }
                    .onKeyPress(.space) {
                        onClick(book)
                        return .handled
                    }
                    .contextMenu {
                        BookContextMenu(
                            book: book,
                            selectionCount: selection.count,
                            isInSelection: selection.isSelected(book),
                            convertibleInSelection: convertibleInSelection,
                            collections: collections,
                            isOnDevice: book.isOnDevice(fileNames: deviceFileNames),
                            onDeviceInSelection: onDeviceInSelection,
                            actions: actions
                        )
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        actions.open(book)
                    }
                    .accessibilityAction(named: Text("Delete")) {
                        actions.delete(book)
                    }
                    .accessibilityHint(book.hasDigitalFile
                        ? "Press Return to open in Reader"
                        : "Physical copy without a digital file")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
    }

    private func moveFocus(from book: Book, direction: MoveCommandDirection) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        let offset: Int
        switch direction {
        case .left, .up:
            offset = -1
        case .right, .down:
            offset = 1
        @unknown default:
            return
        }
        let destination = min(max(index + offset, books.startIndex), books.index(before: books.endIndex))
        focusedBookID = books[destination].id
    }
}
