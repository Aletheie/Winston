import AppKit
import UniformTypeIdentifiers

@MainActor
private final class ImportDropBatch {
    private let viewModel: LibraryViewModel
    private var remainingCount: Int
    private var sources: [ImportSource?]

    init(providerCount: Int, viewModel: LibraryViewModel) {
        self.viewModel = viewModel
        remainingCount = providerCount
        sources = Array(repeating: nil, count: providerCount)
    }

    func receive(_ url: URL?, at index: Int) {
        if let url {
            sources[index] = .external(url)
        }
        remainingCount -= 1
        guard remainingCount == 0 else { return }
        let batch = sources.compactMap { $0 }
        if !batch.isEmpty {
            viewModel.reviewAndAddBooks(from: batch)
        }
    }
}

@MainActor
enum LibraryExternalActions {

    static func openInReader(_ book: Book, toasts: ToastCenter) {
        guard let url = book.primaryFileURL else {
            postUnavailableFile(for: book, toasts: toasts)
            return
        }
        openInReader(url)
    }

    static func openInReader(_ url: URL) {
        let booksReadable = ["epub", "pdf"].contains(url.pathExtension.lowercased())
        if booksReadable,
           let books = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iBooksX") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: books, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func share(_ url: URL) {
        guard let anchor = NSApp.keyWindow?.contentView else { return }
        NSSharingServicePicker(items: [url]).show(
            relativeTo: anchor.bounds,
            of: anchor,
            preferredEdge: .minY
        )
    }

    static func postUnavailableFile(for book: Book, toasts: ToastCenter) {
        if book.hasCatalogDigitalFile {
            toasts.post(
                String(
                    localized: "The file for “\(book.displayTitle)” is missing. Relink it to continue."
                ),
                style: .error,
                action: .relinkBook(book.uuid)
            )
        } else {
            toasts.post(
                String(
                    localized: "“\(book.displayTitle)” has no available digital file. Attach one to continue."
                ),
                style: .error,
                action: .attachDigitalFile(book.uuid)
            )
        }
    }

    static func exportLibrary(via viewModel: LibraryViewModel) async {
        guard let folder = await FilePanel.chooseFolder(
            message: String(localized: "Choose a folder where Winston should create a new library export."),
            prompt: String(localized: "Export")
        ) else { return }
        viewModel.exportLibrary(to: folder)
    }

    static func relink(_ book: Book, via viewModel: LibraryViewModel) async {
        guard let url = await FilePanel.chooseFile(
            message: String(localized: "Choose the file to link to this book.")
        ) else { return }
        await viewModel.relink(book, from: url)
    }

    static func importFromCalibre(via viewModel: LibraryViewModel) async {
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Calibre Library")
        let directory = FileManager.default.fileExists(atPath: defaultDir.path(percentEncoded: false))
            ? defaultDir : nil
        guard let folder = await FilePanel.chooseFolder(
            message: String(localized: "Choose your Calibre library folder (the one containing metadata.db)."),
            prompt: String(localized: "Import"),
            directory: directory
        ) else { return }
        viewModel.importCalibreLibrary(at: folder)
    }

    static func chooseReadingHistoryExport() async -> URL? {
        await FilePanel.chooseFile(
            message: String(localized: "Choose a Goodreads, StoryGraph, or Hardcover CSV export."),
            allowedContentTypes: [.commaSeparatedText, .plainText]
        )
    }

    static func handleDrop(providers: [NSItemProvider], viewModel: LibraryViewModel) {
        guard !providers.isEmpty else { return }
        let batch = ImportDropBatch(
            providerCount: providers.count,
            viewModel: viewModel
        )
        for (index, provider) in providers.enumerated() {
            _ = provider.loadObject(ofClass: NSURL.self) { reading, _ in
                let url = reading as? URL
                Task { @MainActor in
                    batch.receive(url, at: index)
                }
            }
        }
    }
}
