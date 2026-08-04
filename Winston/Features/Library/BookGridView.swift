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
        if book.hasCatalogDigitalFile {
            content.draggable(BookDragItem(bookID: book.uuid, fileURL: book.fileURL))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedBookID: Book.ID?

    private var convertingUUIDs: Set<UUID> { conversion.convertingUUIDs }
    private var missingUUIDs: Set<UUID> { health.missingFileUUIDs }

    private var columns: [GridItem] { WinstonLayout.coverGridColumns(zoom: settings.gridZoom) }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                scrollContent(
                    availableWidth: geometry.size.width,
                    scrollProxy: proxy
                )
                    .onChange(of: scrollTarget) {
                        guard let target = scrollTarget else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                        scrollTarget = nil
                    }
            }
        }
    }

    private func scrollContent(
        availableWidth: CGFloat,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(books) { book in
                    BookCardView(
                        book: book,
                        isSelected: selection.isSelected(book),
                        isFocused: focusedBookID == book.id,
                        isOnDevice: book.isOnDevice(fileNames: deviceFileNames),
                        isConverting: convertingUUIDs.contains(book.uuid),
                        isMissing: missingUUIDs.contains(book.uuid),
                        editionCount: editions.editionCounts[book.uuid] ?? 1,
                        onDelete: { actions.delete(book) }
                    )
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
                        moveFocus(
                            from: book,
                            direction: direction,
                            availableWidth: availableWidth,
                            scrollProxy: scrollProxy
                        )
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
                            availability: actionAvailability(for: book),
                            isInSelection: selection.isSelected(book),
                            collections: collections,
                            isOnDevice: book.isOnDevice(fileNames: deviceFileNames),
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
                    .accessibilityHint(book.hasCatalogDigitalFile
                        ? "Press Return to open in Reader"
                        : "Physical copy without a digital file")
                }
            }
            .padding(.horizontal, WinstonLayout.coverGridHorizontalPadding)
            .padding(.vertical, 14)
        }
    }

    private func moveFocus(
        from book: Book,
        direction: MoveCommandDirection,
        availableWidth: CGFloat,
        scrollProxy: ScrollViewProxy
    ) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        guard let navigationDirection = GridKeyboardDirection(direction),
              let destination = GridKeyboardNavigation.destinationIndex(
                  from: index,
                  itemCount: books.count,
                  columnCount: WinstonLayout.coverGridColumnCount(
                      containerWidth: availableWidth,
                      zoom: settings.gridZoom
                  ),
                  direction: navigationDirection
              ) else { return }
        focusedBookID = books[destination].id
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            scrollProxy.scrollTo(books[destination].id, anchor: .center)
        }
    }

    private func actionAvailability(for book: Book) -> BookActionAvailability {
        let targets = selection.count > 1 && selection.isSelected(book)
            ? books.filter { selection.isSelected($0) }
            : [book]
        return BookActionAvailability(
            selectionCount: targets.count,
            hasPrimarySelection: true,
            primaryHasPersistedDigitalFile: book.hasCatalogDigitalFile,
            persistedDigitalFileCount: targets.filter(\.hasCatalogDigitalFile).count,
            sendableDigitalFileCount: targets.filter {
                $0.hasCatalogDigitalFile && $0.primaryDRMProtected != true
            }.count,
            drmProtectedDigitalFileCount: targets.filter {
                $0.hasCatalogDigitalFile && $0.primaryDRMProtected == true
            }.count,
            conversionEligibleCount: targets.filter {
                $0.hasCatalogDigitalFile
                    && $0.primaryDRMProtected != true
                    && EbookConverter.needsConversion(format: $0.format)
                    && conversion.canConvertForKindle($0.format)
            }.count,
            calibreAvailable: conversion.isCalibreAvailable,
            onlineMetadataEnabled: settings.onlineMetadataEnabled,
            onDeviceSelectionCount: targets.filter {
                $0.isOnDevice(fileNames: deviceFileNames)
            }.count
        )
    }
}

private extension GridKeyboardDirection {
    init?(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        @unknown default: return nil
        }
    }
}
