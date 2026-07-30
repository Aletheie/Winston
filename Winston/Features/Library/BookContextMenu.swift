import SwiftUI

struct BookActions {
    var open: (Book) -> Void
    var openWork: (Work) -> Void
    var openSeries: (String) -> Void
    var showAuthorInLibrary: (String) -> Void
    var quickLook: (Book) -> Void
    var showInFinder: (Book) -> Void
    var share: (Book) -> Void
    var edit: (Book) -> Void
    var editSelection: () -> Void
    var fetchMetadata: (Book) -> Void
    var fetchMetadataSelection: () -> Void
    var reviewMetadataCleanup: (Book) -> Void
    var setStatus: (Book, ReadingStatus) -> Void
    var readingHistory: (Book) -> Void
    var addToCollection: (Book, BookCollection) -> Void
    var newCollection: (Book) -> Void
    var setCover: (Book, URL) -> Void
    var setCoverData: (Book, Data) -> Void
    var resetCover: (Book) -> Void
    var relink: (Book) -> Void
    var inspect: (Book) -> Void
    var convert: (Book) -> Void
    var convertTo: (Book, EbookConverter.OutputFormat) -> Void
    var convertSelection: () -> Void
    var convertSelectionTo: (EbookConverter.OutputFormat) -> Void
    var delete: (Book) -> Void
    var deleteSelection: () -> Void
    var removeFromDevice: (Book) -> Void
    var removeSelectionFromDevice: () -> Void
}

struct BookContextMenu: View {
    let book: Book
    let availability: BookActionAvailability
    let isInSelection: Bool
    let collections: [BookCollection]
    let isOnDevice: Bool
    let actions: BookActions

    private var isMultiSelection: Bool { availability.selectionCount > 1 && isInSelection }
    private var manualCollections: [BookCollection] { collections.filter { !$0.isSmart } }

    var body: some View {
        if availability.primaryHasPersistedDigitalFile {
            Button { actions.open(book) } label: {
                Label("Open in Books", systemImage: "book")
            }
        }
        if let work = book.work {
            Button { actions.openWork(work) } label: {
                Label("Open Work", systemImage: "books.vertical")
            }
        }
        if availability.primaryHasPersistedDigitalFile {
            Button { actions.quickLook(book) } label: {
                Label("Quick Look", systemImage: "eye")
            }
            Button { actions.showInFinder(book) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Button { actions.share(book) } label: {
                Label("Share\u{2026}", systemImage: "square.and.arrow.up")
            }
            Button { actions.relink(book) } label: {
                Label("Replace File\u{2026}", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
            }
            Button { actions.inspect(book) } label: {
                Label("Inspect with Book Doctor…", systemImage: "stethoscope")
            }
        } else {
            Button { actions.relink(book) } label: {
                Label("Attach Digital File…", systemImage: "doc.badge.plus")
            }
        }
        Divider()

        Menu {
            ForEach(ReadingStatus.allCases) { status in
                Button { actions.setStatus(book, status) } label: {
                    if book.readingStatus == status {
                        Label(status.label, systemImage: "checkmark")
                    } else {
                        Text(status.label)
                    }
                }
            }
        } label: {
            Label("Reading Status", systemImage: "bookmark")
        }
        Button { actions.readingHistory(book) } label: {
            Label("Reading History\u{2026}", systemImage: "clock.arrow.circlepath")
        }

        Menu {
            ForEach(manualCollections) { collection in
                Button(collection.name) { actions.addToCollection(book, collection) }
            }
            if !manualCollections.isEmpty { Divider() }
            Button("New Collection\u{2026}") { actions.newCollection(book) }
        } label: {
            Label("Add to Collection", systemImage: "tray.full")
        }

        Divider()
        if isMultiSelection {
            Button { actions.editSelection() } label: {
                Label("Edit Metadata for \(availability.selectionCount)\u{2026}", systemImage: "pencil")
            }
        } else {
            Button { actions.edit(book) } label: {
                Label("Edit Metadata\u{2026}", systemImage: "pencil")
            }
        }

        if availability.canFetchMetadata {
            if isMultiSelection {
                Button { actions.fetchMetadataSelection() } label: {
                    Label("Fetch Metadata for \(availability.selectionCount)", systemImage: "globe")
                }
            } else {
                Button { actions.fetchMetadata(book) } label: {
                    Label("Fetch Metadata Online", systemImage: "globe")
                }
            }
        }

        Button { actions.reviewMetadataCleanup(book) } label: {
            Label(
                isMultiSelection
                    ? "Review Metadata Cleanup for \(availability.selectionCount)…"
                    : "Review Metadata Cleanup…",
                systemImage: "wand.and.sparkles"
            )
        }

        if isMultiSelection {
            if availability.canConvertForKindle && availability.calibreAvailable {
                Menu {
                    ForEach(EbookConverter.OutputFormat.allCases) { format in
                        Button(format.label) { actions.convertSelectionTo(format) }
                    }
                } label: {
                    Label(
                        "Convert \(availability.conversionEligibleCount) to",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
            }
        } else if availability.canUsePrimaryFile && hasAvailableConversionFormat {
            Menu {
                ForEach(EbookConverter.OutputFormat.allCases.filter { $0.ext != book.format.lowercased() }) { format in
                    Button(format.label) { actions.convertTo(book, format) }
                        .disabled(!EbookConverter.canConvert(
                            from: book.format,
                            to: format,
                            calibreAvailable: availability.calibreAvailable
                        ))
                }
            } label: {
                Label("Convert to", systemImage: "arrow.triangle.2.circlepath")
            }
        }

        if isMultiSelection {
            if availability.canRemoveFromDevice {
                Button(role: .destructive) { actions.removeSelectionFromDevice() } label: {
                    Label(
                        "Remove \(availability.onDeviceSelectionCount) from Kindle",
                        systemImage: "externaldrive.badge.minus"
                    )
                }
            }
        } else if isOnDevice {
            Button(role: .destructive) { actions.removeFromDevice(book) } label: {
                Label("Remove from Kindle", systemImage: "externaldrive.badge.minus")
            }
        }

        Divider()
        if isMultiSelection {
            Button(role: .destructive) { actions.deleteSelection() } label: {
                Label("Delete \(availability.selectionCount) Books", systemImage: "trash")
            }
        } else {
            Button(role: .destructive) { actions.delete(book) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var hasAvailableConversionFormat: Bool {
        EbookConverter.OutputFormat.allCases.contains { format in
            EbookConverter.canConvert(
                from: book.format,
                to: format,
                calibreAvailable: availability.calibreAvailable
            )
        }
    }
}
