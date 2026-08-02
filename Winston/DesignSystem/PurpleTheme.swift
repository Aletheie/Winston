import SwiftUI

extension Theme {
    static let purple = Theme(
        colorScheme: .dark,
        fontStyle: .retro,

        background:    Color(hex: 0x0A0118),
        backgroundAlt: Color(hex: 0x14082E),
        surface:       Color(hex: 0x1F0A3D),
        surfaceGlass:  Color(hex: 0x2D1B5E),

        accent:          Color(hex: 0xFF2E97),
        accentSecondary: Color(hex: 0x00F0FF),
        accentTertiary:  Color(hex: 0xB026FF),
        highlight:       Color(hex: 0xFFE600),
        success:         Color(red: 0.18, green: 0.88, blue: 0.40),
        destructive:     Color(hex: 0xFF2E97),

        textPrimary:   Color(hex: 0xF8F0FF),
        textSecondary: Color(hex: 0x9D8AC7),
        textTertiary:  Color(hex: 0x5A4A7A),

        borderSubtle: Color(hex: 0xFF2E97, opacity: 0.15),
        borderActive: Color(hex: 0xFF2E97),

        structure: ThemeStructuralRoles(
            content: Color(hex: 0x0A0118),
            sidebar: Color(hex: 0x14082E),
            toolbar: Color(hex: 0x1F0A3D),
            inspector: Color(hex: 0x14082E),
            floating: Color(hex: 0x1F0A3D),
            sheetAction: Color(hex: 0x14082E),
            usesNativeMaterials: false
        ),
        interaction: ThemeInteractionRoles(
            selection: Color(hex: 0x00F0FF, opacity: 0.16),
            focus: Color(hex: 0x00F0FF),
            hover: Color(hex: 0xFF2E97, opacity: 0.11),
            pressed: Color(hex: 0xFF2E97, opacity: 0.22),
            disabled: Color(hex: 0x9D8AC7, opacity: 0.44),
            warning: Color(hex: 0xFFE600),
            information: Color(hex: 0x00F0FF)
        ),

        coverPalettes: [
            ColorPair(primary: Color(hex: 0xFF2E97), secondary: Color(hex: 0xB026FF)),
            ColorPair(primary: Color(hex: 0x00F0FF), secondary: Color(hex: 0xB026FF)),
            ColorPair(primary: Color(hex: 0xB026FF), secondary: Color(hex: 0x00F0FF)),
        ],

        showsNeonGlow: true,
        showsMeshBackground: true,
        usesTerminalCopy: true,

        copy: Microcopy(
            dropIdle: String(localized: "// drop_books_here \u{00B7} epub \u{00B7} mobi \u{00B7} azw3 \u{00B7} pdf", comment: "Retro terminal style; keep the snake_case tone"),
            dropActive: String(localized: "// release_to_upload", comment: "Retro terminal style"),
            dropFormats: "epub \u{00B7} mobi \u{00B7} azw3 \u{00B7} pdf",
            addFiles: String(localized: "ADD_FILES", comment: "Retro terminal style"),
            transmit: String(localized: "TRANSMIT >>", comment: "Retro terminal style"),
            emptyLibrary: String(localized: "// library_empty", comment: "Retro terminal style"),
            selectABook: String(localized: "// select_a_book", comment: "Retro terminal style"),
            noMatches: String(localized: "// no_matches", comment: "Retro terminal style"),
            showAll: String(localized: "SHOW_ALL", comment: "Retro terminal style"),
            clearSearch: String(localized: "CLEAR_SEARCH", comment: "Retro terminal style"),
            searchPlaceholder: String(localized: "search_library", comment: "Retro terminal style"),
            editMetadataTitle: String(localized: "// EDIT_METADATA", comment: "Retro terminal style"),
            extractingFormat: String(localized: "extracting metadata... %d remaining", comment: "Retro terminal style; %d is the remaining count"),
            noResultsFormat: String(localized: "// no_results_for \u{201C}%@\u{201D}", comment: "Retro terminal style; %@ is the query")
        )
    )
}
