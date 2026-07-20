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
    @State private var seriesSuggestions: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(theme.copy.editMetadataTitle)
                    .font(theme.label(size: 14, weight: .bold))
                    .foregroundStyle(theme.usesTerminalCopy ? theme.accentSecondary : theme.textPrimary)
                Spacer()
                Text(book.format)
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: WinstonLayout.cornerSmall, style: .continuous)
                            .fill(theme.accent.opacity(0.15))
                    )
            }
            .padding(.bottom, 16)

            VStack(spacing: 12) {
                MetaField(label: theme.styledText(terminal: "TITLE", native: "Title"), text: $title)
                MetaField(label: theme.styledText(terminal: "AUTHOR", native: "Author"), text: $author)
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
                    MetaField(label: theme.styledText(terminal: "LANGUAGE", native: "Language"), text: $language)
                        .frame(width: 120)
                    MetaField(label: theme.styledText(terminal: "ISBN", native: "ISBN"), text: $isbn)
                }

                MetaField(label: theme.styledText(terminal: "TAGS", native: "Tags"), text: $tags,
                          hint: "comma separated")

                VStack(alignment: .leading, spacing: 4) {
                    theme.styledText(terminal: "DESCRIPTION", native: "Description")
                        .font(theme.label(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                    TextEditor(text: $bookDescription)
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

                Button("Save") {
                    viewModel.updateMetadata(
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
                        tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    )
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(theme.label(size: 12, weight: .bold))
                .foregroundStyle(saveLabelColor)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: WinstonLayout.cornerMedium, style: .continuous)
                        .fill(saveBackground)
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 600)
        .background(theme.backgroundAlt)
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
        }
        .task {
            let suggestions = await viewModel.seriesSuggestions()
            guard !Task.isCancelled else { return }
            seriesSuggestions = suggestions
        }
    }

    private var saveBackground: Color {
        theme.usesTerminalCopy ? theme.accentSecondary : theme.accent
    }

    private var saveLabelColor: Color {
        theme.colorScheme == .dark ? theme.background : .white
    }
}

private struct MetaField: View {
    let label: Text
    @Binding var text: String
    var hint: LocalizedStringKey? = nil
    var suggestions: [String] = []
    var showsSuggestionMenu = false

    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                label
                    .font(theme.label(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                if let hint {
                    Text(hint)
                        .font(theme.label(size: 8, weight: .regular))
                        .foregroundStyle(theme.textTertiary.opacity(0.6))
                }
            }
            HStack(spacing: 0) {
                TextField("", text: $text)
                    .seriesAutocomplete(text: $text, suggestions: suggestions)
                    .font(theme.label(size: 12, weight: .regular))
                    .textFieldStyle(.plain)
                    .focused($isFocused)

                if showsSuggestionMenu {
                    Rectangle()
                        .fill(theme.borderSubtle)
                        .frame(width: 1, height: 16)
                    SeriesSuggestionMenu(text: $text, suggestions: suggestions)
                        .padding(.leading, 2)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, showsSuggestionMenu ? 3 : 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.surface.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(isFocused ? focusBorder : theme.borderSubtle, lineWidth: 1)
            )
        }
    }

    private var focusBorder: Color {
        (theme.usesTerminalCopy ? theme.accentSecondary : theme.accent).opacity(0.5)
    }
}
