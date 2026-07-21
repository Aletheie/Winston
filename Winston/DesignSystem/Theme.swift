import SwiftUI

struct Theme: Equatable, Sendable {
    enum FontStyle: Equatable, Sendable {
        case retro
        case native
    }

    // MARK: Identity

    var colorScheme: ColorScheme
    var fontStyle: FontStyle
    var fontFamily: String? = nil

    // MARK: Colors

    var background: Color
    var backgroundAlt: Color
    var surface: Color
    var surfaceGlass: Color

    var accent: Color
    var accentSecondary: Color
    var accentTertiary: Color
    var highlight: Color
    var success: Color
    var destructive: Color

    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color

    var borderSubtle: Color
    var borderActive: Color

    var coverPalettes: [ColorPair]

    // MARK: Behavior flags

    var showsNeonGlow: Bool
    var showsMeshBackground: Bool
    var usesTerminalCopy: Bool

    // MARK: Microcopy

    var copy: Microcopy

    // MARK: Typography

    func display(size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        let textStyle = Self.textStyle(for: size)
        if let fontFamily {
            return .custom(fontFamily, size: size, relativeTo: textStyle).weight(weight)
        }
        switch fontStyle {
        case .retro:
            return .winstonDisplay(size: size, weight: weight, relativeTo: textStyle)
        case .native:
            return .system(textStyle, design: .rounded, weight: weight)
        }
    }

    func body(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        let textStyle = Self.textStyle(for: size)
        if let fontFamily {
            return .custom(fontFamily, size: size, relativeTo: textStyle).weight(weight)
        }
        switch fontStyle {
        case .retro:
            return .winstonBody(size: size, weight: weight, relativeTo: textStyle)
        case .native:
            return .system(textStyle, design: .default, weight: weight)
        }
    }

    func label(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        let textStyle = Self.textStyle(for: size)
        if let fontFamily {
            return .custom(fontFamily, size: size, relativeTo: textStyle).weight(weight)
        }
        switch fontStyle {
        case .retro:
            return .winstonMono(size: size, weight: weight, relativeTo: textStyle)
        case .native:
            return .system(textStyle, design: .default, weight: weight)
        }
    }

    private static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ...9:  .caption2
        case ...11: .caption
        case ...13: .footnote
        case ...15: .callout
        case ...18: .body
        case ...21: .title3
        case ...24: .title2
        case ...30: .title
        default:    .largeTitle
        }
    }

    // MARK: Helpers

    func coverAccents(for book: Book) -> ColorPair {
        let source = book.hasDigitalFile ? book.fileName : book.uuid.uuidString
        let hash = source.utf8.reduce(0) { $0 &+ Int($1) }
        return coverPalettes[abs(hash) % coverPalettes.count]
    }
}

struct ColorPair: Equatable, Sendable {
    var primary: Color
    var secondary: Color
}

struct Microcopy: Equatable, Sendable {
    var dropIdle: String
    var dropActive: String
    var dropFormats: String
    var addFiles: String
    var transmit: String
    var emptyLibrary: String
    var selectABook: String
    var noMatches: String
    var showAll: String
    var clearSearch: String
    var searchPlaceholder: String
    var editMetadataTitle: String
    var extractingFormat: String
    var noResultsFormat: String

    func noResults(for query: String) -> String {
        String(format: noResultsFormat, query)
    }

    func extracting(remaining: Int) -> String {
        String(format: extractingFormat, remaining)
    }
}

extension Microcopy {
    static let nativeCopy = Microcopy(
        dropIdle: String(localized: "Drop books here \u{2014} EPUB, MOBI, AZW3, PDF"),
        dropActive: String(localized: "Release to add to library"),
        dropFormats: "EPUB, MOBI, AZW3, PDF",
        addFiles: String(localized: "Add Files"),
        transmit: String(localized: "Send to Device"),
        emptyLibrary: String(localized: "Your library is empty"),
        selectABook: String(localized: "Select a book to see details"),
        noMatches: String(localized: "No books match this filter"),
        showAll: String(localized: "Show All"),
        clearSearch: String(localized: "Clear Search"),
        searchPlaceholder: String(localized: "Search"),
        editMetadataTitle: String(localized: "Edit Metadata"),
        extractingFormat: String(localized: "Extracting metadata\u{2026} %d remaining", comment: "%d is the number of books still being processed"),
        noResultsFormat: String(localized: "No results for \u{201C}%@\u{201D}", comment: "%@ is the search query")
    )
}

// MARK: - Localized copy

extension Theme {
    func styledText(terminal: String, native: LocalizedStringKey) -> Text {
        usesTerminalCopy ? Text(verbatim: terminal) : Text(native)
    }
}

// MARK: - Environment

extension EnvironmentValues {
    @Entry var theme: Theme = .purple
}
