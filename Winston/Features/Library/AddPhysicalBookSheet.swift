import SwiftUI
import UniformTypeIdentifiers

struct AddPhysicalBookSheet: View {
    let viewModel: LibraryViewModel

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
                .font(.headline)
                .foregroundStyle(.primary)
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
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add Book") { addBook() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 440, idealWidth: 500, maxWidth: 620)
        .background(.background)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $notes)
                .font(.body)
                .frame(height: 72)
        }
    }
}

private struct PhysicalBookCoverField: View {
    @Binding var coverURL: URL?

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
                    .foregroundStyle(.secondary)
                Button("Remove", systemImage: "xmark.circle.fill") { self.coverURL = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
    }
}
