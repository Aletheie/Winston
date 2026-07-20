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
        VStack(spacing: 10) {
            switch kind {
            case .emptyLibrary(let onImport, let onImportCalibre):
                Image(systemName: "books.vertical")
                    .font(.system(size: 32, weight: .thin))
                    .foregroundStyle(theme.textTertiary.opacity(0.5))
                Text(theme.copy.emptyLibrary)
                    .font(theme.label(size: 13))
                    .foregroundStyle(theme.textSecondary)
                Button(action: onImport) {
                    HStack(spacing: 4) {
                        if theme.usesTerminalCopy {
                            Text("[+]").foregroundStyle(theme.accent)
                        } else {
                            Image(systemName: "plus").foregroundStyle(theme.accent)
                        }
                        Text(theme.copy.addFiles).foregroundStyle(theme.textPrimary)
                    }
                    .font(theme.label(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .themedBorder(cornerRadius: WinstonLayout.cornerMedium)
                }
                .buttonStyle(.pressable)
                .padding(.top, 4)

                Button(action: onImportCalibre) {
                    theme.styledText(terminal: "import_calibre", native: "Import from Calibre")
                        .font(theme.label(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .themedBorder(cornerRadius: 5)
                }
                .buttonStyle(.pressable)

            case .noSearchResults(let query, let onClear):
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28, weight: .thin))
                    .foregroundStyle(theme.textTertiary.opacity(0.5))
                Text(theme.copy.noResults(for: query))
                    .font(theme.label(size: 12))
                    .foregroundStyle(theme.textSecondary)
                outlineButton(theme.copy.clearSearch, action: onClear)

            case .noFilterMatches(let onShowAll):
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 28, weight: .thin))
                    .foregroundStyle(theme.textTertiary.opacity(0.5))
                Text(theme.copy.noMatches)
                    .font(theme.label(size: 12))
                    .foregroundStyle(theme.textSecondary)
                outlineButton(theme.copy.showAll, action: onShowAll)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func outlineButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(theme.label(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .themedBorder(cornerRadius: 5)
        }
        .buttonStyle(.pressable)
    }
}
