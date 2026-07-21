import SwiftUI

struct WorkEditionCard: View {
    let book: Book
    let work: Work
    let isPreferred: Bool
    let compact: Bool
    @Binding var selectedEditionUUIDs: Set<UUID>
    let service: EditionService
    let onShowInLibrary: (Book) -> Void
    let onDelete: (Book) -> Void

    @Environment(\.theme) private var theme

    private var isCompared: Bool {
        selectedEditionUUIDs.contains(book.uuid)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: comparisonBinding) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(
                    isCompared ? Text("Remove from comparison") : Text("Select for comparison")
                )
            BookCoverImageView(book: book, tier: .thumb)
                .frame(width: compact ? 38 : 54, height: compact ? 54 : 78)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.22), radius: 3, y: 2)
            WorkEditionDetails(book: book, isPreferred: isPreferred)
            Spacer()
            WorkEditionMenu(
                book: book,
                work: work,
                isPreferred: isPreferred,
                service: service,
                onShowInLibrary: onShowInLibrary,
                onDelete: onDelete
            )
        }
        .padding(12)
        .glassCard(cornerRadius: 10, tintOpacity: isCompared ? 0.7 : 0.4)
        .overlay {
            if isCompared {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.accent, lineWidth: 1.5)
            }
        }
    }

    private var comparisonBinding: Binding<Bool> {
        Binding(
            get: { selectedEditionUUIDs.contains(book.uuid) },
            set: { isOn in
                if isOn {
                    selectedEditionUUIDs.insert(book.uuid)
                } else {
                    selectedEditionUUIDs.remove(book.uuid)
                }
            }
        )
    }
}

private struct WorkEditionDetails: View {
    let book: Book
    let isPreferred: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(book.displayTitle)
                    .font(theme.body(size: 13, weight: .semibold))
                    .lineLimit(2)
                if isPreferred {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(theme.highlight)
                        .accessibilityLabel("Preferred edition")
                }
            }
            if let language = nonempty(book.language) {
                Text(language)
                    .foregroundStyle(theme.textSecondary)
            }
            if let translator = nonempty(book.translator) {
                theme.styledText(terminal: "preklad: \(translator)", native: "Translation: \(translator)")
                    .foregroundStyle(theme.textSecondary)
            }
            if let publication = publicationDescription {
                Text(publication)
                    .foregroundStyle(theme.textTertiary)
            }
            HStack(spacing: 4) {
                ForEach(book.assetFormats, id: \.self) { format in
                    Text(format)
                        .font(theme.label(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.accent.opacity(0.12), in: Capsule())
                }
            }
            .padding(.top, 1)
        }
        .font(theme.label(size: 11))
    }

    private var publicationDescription: String? {
        let values = [nonempty(book.publisher), nonempty(book.year)].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct WorkEditionMenu: View {
    let book: Book
    let work: Work
    let isPreferred: Bool
    let service: EditionService
    let onShowInLibrary: (Book) -> Void
    let onDelete: (Book) -> Void

    var body: some View {
        Menu {
            if book.hasDigitalFile {
                Button("Open") { LibraryExternalActions.openInReader(book) }
            }
            Button("Show in Library") { onShowInLibrary(book) }
            Button("Make Preferred") { service.setPreferred(book, in: work) }
                .disabled(isPreferred)
            Divider()
            Button("Remove from This Work") { _ = service.detach(book) }
                .disabled(work.editions.count <= 1)
            Button("Delete Edition…", role: .destructive) { onDelete(book) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("Edition actions")
    }
}
