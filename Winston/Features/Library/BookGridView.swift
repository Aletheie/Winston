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
        ProxyRepresentation(exporting: { item throws -> URL in
            try item.validatedFileURL()
        })
    }

    // Validate only when the transfer framework actually requests the URL,
    // never while constructing a row. Keep the native URL representations.
    nonisolated func validatedFileURL() throws -> URL {
        try Task.checkCancellation()
        guard let validated = BookFileStore.validatedURL(
            for: fileURL.lastPathComponent, in: fileURL.deletingLastPathComponent()
        ), validated == fileURL.standardizedFileURL else {
            throw CocoaError(.fileReadNoPermission)
        }
        return validated
    }
}

private struct BookFileDragModifier: ViewModifier {
    let book: Book

    @ViewBuilder
    func body(content: Content) -> some View {
        if book.hasCatalogDigitalFile,
           let url = BookFileStore.catalogURL(for: book.primaryAsset?.fileName ?? book.fileName) {
            content.draggable(BookDragItem(bookID: book.uuid, fileURL: url))
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
                ForEach(books.enumerated(), id: \.element.id) { index, book in
                    BookGridCell(
                        book: book,
                        selection: selection,
                        deviceFileNames: deviceFileNames,
                        conversion: conversion,
                        health: health,
                        editions: editions,
                        collections: collections,
                        actions: actions,
                        focusedBookID: $focusedBookID,
                        onClick: onClick,
                        onMove: { direction in
                            moveFocus(
                                from: index,
                                direction: direction,
                                availableWidth: availableWidth,
                                scrollProxy: scrollProxy
                            )
                        },
                        availability: { actionAvailability(for: book) }
                    )
                }
            }
            .padding(.horizontal, WinstonLayout.coverGridHorizontalPadding)
            .padding(.vertical, 14)
        }
        .accessibilityIdentifier("library.grid")
    }

    private func moveFocus(
        from index: Int,
        direction: MoveCommandDirection,
        availableWidth: CGFloat,
        scrollProxy: ScrollViewProxy
    ) {
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
        return BookActionAvailability.forBooks(
            targets,
            primary: book,
            calibreAvailable: conversion.isCalibreAvailable,
            onlineMetadataEnabled: settings.onlineMetadataEnabled,
            deviceFileNames: deviceFileNames
        )
    }
}

/// Narrow direct observation of selection, focus and background operations to
/// cells. The library parent can still update for its inspector and toolbar.
private struct BookGridCell: View {
    let book: Book
    let selection: BookSelectionModel
    let deviceFileNames: Set<String>
    let conversion: ConversionService
    let health: LibraryHealthService
    let editions: CatalogReconciliationService
    let collections: [BookCollection]
    let actions: BookActions
    var focusedBookID: FocusState<Book.ID?>.Binding
    let onClick: (Book) -> Void
    let onMove: (MoveCommandDirection) -> Void
    let availability: () -> BookActionAvailability

    var body: some View {
        BookCardView(
            book: book,
            isSelected: selection.isSelected(book),
            isFocused: focusedBookID.wrappedValue == book.id,
            isOnDevice: book.isOnDevice(fileNames: deviceFileNames),
            isConverting: conversion.convertingUUIDs.contains(book.uuid),
            isMissing: health.missingFileUUIDs.contains(book.uuid),
            editionCount: editions.editionCounts[book.uuid] ?? 1,
            onDelete: { actions.delete(book) }
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            focusedBookID.wrappedValue = book.id
            actions.open(book)
        }
        .onTapGesture {
            focusedBookID.wrappedValue = book.id
            onClick(book)
        }
        .modifier(BookFileDragModifier(book: book))
        .focusable()
        .focusEffectDisabled()
        .focused(focusedBookID, equals: book.id)
        .onMoveCommand(perform: onMove)
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
                availability: availability(),
                isInSelection: selection.isSelected(book),
                collections: collections,
                isOnDevice: book.isOnDevice(fileNames: deviceFileNames),
                actions: actions
            )
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("library.book.\(book.uuid.uuidString)")
        .accessibilityAction { actions.open(book) }
        .accessibilityAction(named: Text("Delete")) { actions.delete(book) }
        .accessibilityHint(book.hasCatalogDigitalFile
            ? "Press Return to open in Reader"
            : "Physical copy without a digital file")
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
