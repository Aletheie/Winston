import SwiftUI

struct LibraryEmptyState: View {
    enum Kind {
        case emptyLibrary(onImport: () -> Void, onImportCalibre: () -> Void)
        case noSearchResults(query: String, onClear: () -> Void)
        case noFilterMatches(onShowAll: () -> Void)
    }

    let kind: Kind

    @Environment(\.theme) private var theme

    var body: some View {
        switch kind {
        case .emptyLibrary(let onImport, let onImportCalibre):
            ContentUnavailableView {
                Label(theme.copy.emptyLibrary, systemImage: "books.vertical")
            } description: {
                Text(theme.copy.dropIdle)
            } actions: {
                Button(action: onImport) {
                    Label(theme.copy.addFiles, systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button(action: onImportCalibre) {
                    theme.styledText(terminal: "import_calibre", native: "Import from Calibre")
                }
            }

        case .noSearchResults(let query, let onClear):
            ContentUnavailableView {
                Label(theme.copy.noResults(for: query), systemImage: "magnifyingglass")
            } description: {
                Text("Try a different search.")
            } actions: {
                Button(theme.copy.clearSearch, action: onClear)
            }

        case .noFilterMatches(let onShowAll):
            ContentUnavailableView {
                Label(theme.copy.noMatches, systemImage: "line.3.horizontal.decrease")
            } description: {
                Text("Change the filter or search to see more books.")
            } actions: {
                Button(theme.copy.showAll, action: onShowAll)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
