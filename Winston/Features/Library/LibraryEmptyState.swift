import SwiftUI

struct LibraryEmptyState: View {
    enum Kind {
        case emptyLibrary(
            onImport: () -> Void,
            onImportCalibre: () -> Void
        )
        case noSearchResults(query: String, onClear: () -> Void)
        case noFilterMatches(onShowAll: () -> Void)
    }

    let kind: Kind

    @Environment(\.theme) private var theme

    var body: some View {
        switch kind {
        case .emptyLibrary(
            let onImport,
            let onImportCalibre
        ):
            EmptyLibraryOnboarding(
                onImport: onImport,
                onImportCalibre: onImportCalibre
            )

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

private struct EmptyLibraryOnboarding: View {
    let onImport: () -> Void
    let onImportCalibre: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack {
            ContentUnavailableView {
                Label(theme.copy.emptyLibrary, systemImage: "books.vertical")
            } description: {
                Text("Drop book files here or choose files to begin.")
            } actions: {
                ImportSetupActions(
                    onImport: onImport,
                    onImportCalibre: onImportCalibre
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(WinstonLayout.space5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.onboarding")
    }
}

private struct ImportSetupActions: View {
    let onImport: () -> Void
    let onImportCalibre: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: WinstonLayout.space2) {
                actionButtons
            }
            VStack(alignment: .leading, spacing: WinstonLayout.space2) {
                actionButtons
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(action: onImport) {
            Label("Add Files", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("library.onboarding.addFiles")

        Button(action: onImportCalibre) {
            Text("Import from Calibre")
        }
        .accessibilityIdentifier("library.onboarding.importCalibre")
    }
}
