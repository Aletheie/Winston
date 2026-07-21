import SwiftUI
import UniformTypeIdentifiers

struct AddPhysicalBookSheet: View {
    let viewModel: LibraryViewModel

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var author = ""
    @State private var publisher = ""
    @State private var year = ""
    @State private var isbn = ""
    @State private var shelfLocation = ""
    @State private var notes = ""
    @State private var readingStatus: ReadingStatus = .unread
    @State private var coverURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Add Physical Book", systemImage: "books.vertical")
                .font(theme.label(size: 14, weight: .bold))
                .foregroundStyle(theme.usesTerminalCopy ? theme.accentSecondary : theme.textPrimary)
                .padding(.bottom, 16)

            PhysicalBookFields(
                title: $title,
                author: $author,
                publisher: $publisher,
                year: $year,
                isbn: $isbn,
                shelfLocation: $shelfLocation,
                readingStatus: $readingStatus
            )

            PhysicalBookNotesField(notes: $notes)
                .padding(.top, 12)

            PhysicalBookCoverField(coverURL: $coverURL)
                .padding(.top, 12)

            Spacer().frame(height: 20)

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(theme.label(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .themedBorder(cornerRadius: WinstonLayout.cornerMedium)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add Book") { addBook() }
                    .buttonStyle(.plain)
                    .font(theme.label(size: 12, weight: .bold))
                    .foregroundStyle(theme.colorScheme == .dark ? theme.background : .white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: WinstonLayout.cornerMedium, style: .continuous)
                            .fill(theme.usesTerminalCopy ? theme.accentSecondary : theme.accent)
                    )
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 440, idealWidth: 500, maxWidth: 620)
        .background(theme.backgroundAlt)
    }

    private func addBook() {
        let draft = PhysicalBookDraft(
            title: title,
            author: author,
            publisher: publisher,
            year: year,
            isbn: isbn,
            shelfLocation: shelfLocation,
            notes: notes,
            readingStatus: readingStatus
        )
        guard let book = viewModel.addPhysicalBook(draft) else { return }
        if let coverURL { viewModel.setCustomCover(for: book, from: coverURL) }
        dismiss()
    }
}

private struct PhysicalBookFields: View {
    @Binding var title: String
    @Binding var author: String
    @Binding var publisher: String
    @Binding var year: String
    @Binding var isbn: String
    @Binding var shelfLocation: String
    @Binding var readingStatus: ReadingStatus

    var body: some View {
        VStack(spacing: 12) {
            MetaField(label: Text("Title"), text: $title)
            MetaField(label: Text("Author"), text: $author)
            MetaField(label: Text("Publisher"), text: $publisher)
            HStack(spacing: 12) {
                MetaField(label: Text("Year"), text: $year)
                    .frame(width: 100)
                MetaField(label: Text("ISBN"), text: $isbn)
            }
            HStack(alignment: .bottom, spacing: 12) {
                MetaField(label: Text("Shelf"), text: $shelfLocation)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reading Status")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Reading Status", selection: $readingStatus) {
                        ForEach(ReadingStatus.allCases) { status in
                            Text(status.label).tag(status)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct PhysicalBookNotesField: View {
    @Binding var notes: String

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes")
                .font(theme.label(size: 9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            TextEditor(text: $notes)
                .font(theme.label(size: 12, weight: .regular))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(height: 72)
                .background(
                    RoundedRectangle(cornerRadius: WinstonLayout.cornerSmall, style: .continuous)
                        .fill(theme.surface.opacity(0.5))
                )
                .themedBorder(cornerRadius: WinstonLayout.cornerSmall)
        }
    }
}

private struct PhysicalBookCoverField: View {
    @Binding var coverURL: URL?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Button("Choose Cover…") {
                Task {
                    coverURL = await FilePanel.chooseFile(
                        message: String(localized: "Choose a cover image."),
                        allowedContentTypes: [.image]
                    )
                }
            }
            if let coverURL {
                Text(coverURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(theme.textSecondary)
                Button("Remove", systemImage: "xmark.circle.fill") { self.coverURL = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
        }
        .font(theme.label(size: 11))
    }
}
