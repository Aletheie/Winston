import AppKit
import UniformTypeIdentifiers

@MainActor
enum LibraryExternalActions {

    static func openInReader(_ book: Book) {
        let url = book.fileURL
        let booksReadable = ["epub", "pdf"].contains(url.pathExtension.lowercased())
        if booksReadable,
           let books = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iBooksX") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: books, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func showInFinder(_ book: Book) {
        NSWorkspace.shared.activateFileViewerSelecting([book.fileURL])
    }

    static func exportLibrary(via viewModel: LibraryViewModel) async {
        guard let folder = await FilePanel.chooseFolder(
            message: String(localized: "Choose a folder to export the library into."),
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
        for provider in providers {
            _ = provider.loadObject(ofClass: NSURL.self) { reading, _ in
                guard let url = reading as? URL else { return }
                Task { @MainActor [viewModel] in viewModel.addBooks(from: [url]) }
            }
        }
    }
}
