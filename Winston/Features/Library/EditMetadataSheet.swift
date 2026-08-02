import SwiftUI
import SwiftData

struct EditMetadataSheet: View {
    let book: Book
    let viewModel: LibraryViewModel

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var author: String = ""
    @State private var publisher: String = ""
    @State private var year: String = ""
    @State private var series: String = ""
    @State private var seriesIndex: String = ""
    @State private var language: String = ""
    @State private var translator: String = ""
    @State private var isbn: String = ""
    @State private var tags: String = ""
    @State private var bookDescription: String = ""
    @State private var shelfLocation: String = ""
    @State private var seriesSuggestions: [String] = []
    @State private var identityScope: EditionIdentityScope = .editionOnly

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(theme.copy.editMetadataTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(book.format)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)

            VStack(spacing: 12) {
                MetaField(label: theme.styledText(terminal: "TITLE", native: "Title"), text: $title)
                MetaField(label: theme.styledText(terminal: "AUTHOR", native: "Author"), text: $author)
                if book.work != nil {
                    VStack(alignment: .leading, spacing: 5) {
                        Picker("Identity scope", selection: $identityScope) {
                            Text("This edition").tag(EditionIdentityScope.editionOnly)
                            Text("Work").tag(EditionIdentityScope.workIdentity)
                            Text("All editions").tag(EditionIdentityScope.allEditions)
                        }
                        .pickerStyle(.segmented)

                        Text(identityScopeHelp)
                            .font(theme.label(size: 9))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                MetaField(label: theme.styledText(terminal: "PUBLISHER", native: "Publisher"), text: $publisher)
                MetaField(label: theme.styledText(terminal: "PREKLAD", native: "Translator"), text: $translator)

                HStack(spacing: 12) {
                    MetaField(label: theme.styledText(terminal: "YEAR", native: "Year"), text: $year)
                        .frame(width: 100)
                    MetaField(label: theme.styledText(terminal: "SERIES", native: "Series"), text: $series,
                              suggestions: seriesSuggestions, showsSuggestionMenu: true)
                    MetaField(label: theme.styledText(terminal: "NO.", native: "No."), text: $seriesIndex)
                        .frame(width: 60)
                }

                HStack(spacing: 12) {
                    LanguageMetadataField(
                        label: theme.styledText(
                            terminal: "LANGUAGE",
                            native: "Language"
                        ),
                        text: $language
                    )
                    .frame(width: 190)
                    ISBNMetadataField(
                        label: theme.styledText(terminal: "ISBN", native: "ISBN"),
                        text: $isbn
                    )
                }

                MetaField(label: theme.styledText(terminal: "TAGS", native: "Tags"), text: $tags,
                          hint: "comma separated")

                if book.hasPhysicalCopy {
                    MetaField(label: theme.styledText(terminal: "POLICE", native: "Shelf"), text: $shelfLocation)
                }

                VStack(alignment: .leading, spacing: 4) {
                    theme.styledText(terminal: "DESCRIPTION", native: "Description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $bookDescription)
                        .font(.body)
                        .frame(height: 72)
                }
            }

            Spacer().frame(height: 20)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    if viewModel.updateMetadata(
                        for: book,
                        title: title.isEmpty ? nil : title,
                        author: author.isEmpty ? nil : author,
                        publisher: publisher.isEmpty ? nil : publisher,
                        year: year.isEmpty ? nil : year,
                        series: series.isEmpty ? nil : series,
                        seriesIndex: seriesIndex.isEmpty ? nil : seriesIndex,
                        language: language.isEmpty ? nil : language,
                        translator: translator.isEmpty ? nil : translator,
                        isbn: isbn.isEmpty ? nil : isbn,
                        description: bookDescription.isEmpty ? nil : bookDescription,
                        tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                        shelfLocation: shelfLocation.isEmpty ? nil : shelfLocation,
                        identityScope: identityScope
                    ) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 600)
        .background(.background)
        .onAppear {
            title = book.title ?? ""
            author = book.author ?? ""
            publisher = book.publisher ?? ""
            year = book.year ?? ""
            series = book.series ?? ""
            seriesIndex = book.seriesIndex ?? ""
            language = book.language ?? ""
            translator = book.translator ?? ""
            isbn = book.isbn ?? ""
            tags = book.tags.joined(separator: ", ")
            bookDescription = book.bookDescription ?? ""
            shelfLocation = book.shelfLocation ?? ""
            if let work = book.work {
                identityScope = work.editions.count <= 1
                    ? .workIdentity
                    : .editionOnly
            } else {
                identityScope = .editionOnly
            }
        }
        .task {
            let suggestions = await viewModel.seriesSuggestions()
            guard !Task.isCancelled else { return }
            seriesSuggestions = suggestions
        }
    }

    private var identityScopeHelp: String {
        switch identityScope {
        case .editionOnly:
            String(localized: "Title, author, and ISBN change only on this edition.")
        case .workIdentity:
            String(localized: "Title and author also update the shared work identity.")
        case .allEditions:
            String(localized: "Title and author update the work and every grouped edition.")
        }
    }
}

struct LanguageMetadataField: View {
    let label: Text?
    @Binding var text: String

    @Environment(\.locale) private var locale

    init(label: Text? = nil, text: Binding<String>) {
        self.label = label
        _text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                label
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                TextField("Language", text: $text)
                    .textFieldStyle(.roundedBorder)

                Menu {
                    ForEach(filteredSuggestions.prefix(18)) { suggestion in
                        Button(suggestion.label) {
                            text = suggestion.tag
                        }
                    }
                    if filteredSuggestions.isEmpty {
                        Text("No matching language suggestions")
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Language suggestions")
                .accessibilityLabel("Language suggestions")
            }

            if showsUnrecognizedWarning {
                Label(
                    "This language value is unrecognized. It will still be saved as entered.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            } else if shouldOfferCanonicalTag, let canonicalTag = normalized.canonicalTag {
                Button("Use canonical tag \(canonicalTag)") {
                    text = canonicalTag
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private var normalized: NormalizedLanguage {
        MetadataNormalizer.language(text)
    }

    private var showsUnrecognizedWarning: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && normalized.status == .unrecognized
    }

    private var shouldOfferCanonicalTag: Bool {
        guard let canonicalTag = normalized.canonicalTag else { return false }
        return canonicalTag != text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayLocaleIdentifier: String {
        locale.language.languageCode?.identifier == "cs" ? "cs" : "en"
    }

    private var filteredSuggestions: [MetadataLanguageSuggestion] {
        let suggestions = MetadataNormalizer.languageSuggestions(
            displayLocaleIdentifier: displayLocaleIdentifier
        )
        let query = MetadataNormalizer.searchKey(text)
        guard !query.isEmpty else { return suggestions }
        return suggestions.filter {
            MetadataNormalizer.searchKey($0.label).contains(query)
        }
    }
}

private struct ISBNMetadataField: View {
    let label: Text
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MetaField(label: label, text: $text)
            if normalized.status == .invalid {
                Label(
                    "This ISBN has an invalid checksum. It will still be saved as entered.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var normalized: NormalizedISBN {
        MetadataNormalizer.isbn(text)
    }
}

struct MetaField: View {
    let label: Text
    @Binding var text: String
    var hint: LocalizedStringKey? = nil
    var suggestions: [String] = []
    var showsSuggestionMenu = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                label
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 6) {
                TextField("", text: $text)
                    .seriesAutocomplete(text: $text, suggestions: suggestions)
                    .textFieldStyle(.roundedBorder)

                if showsSuggestionMenu {
                    SeriesSuggestionMenu(text: $text, suggestions: suggestions)
                }
            }
        }
    }
}
