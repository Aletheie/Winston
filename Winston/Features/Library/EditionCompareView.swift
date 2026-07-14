import SwiftUI

struct EditionCompareView: View {
    let left: Book
    let right: Book

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            EditionCompareToolbar(onDone: { dismiss() })
            Divider()
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                    GridRow {
                        Text(verbatim: "")
                        EditionCompareHeader(book: left)
                        EditionCompareHeader(book: right)
                    }
                    ForEach(rows) { row in
                        GridRow {
                            theme.styledText(terminal: row.terminalLabel, native: row.nativeLabel)
                                .font(theme.label(size: 10, weight: .semibold))
                                .foregroundStyle(theme.textTertiary)
                            EditionCompareValue(value: row.left, differs: row.differs)
                            EditionCompareValue(value: row.right, differs: row.differs)
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 680, idealWidth: 780, minHeight: 540, idealHeight: 640)
    }

    private var rows: [CompareRow] {
        [
            row("TITLE", "Title", left.displayTitle, right.displayTitle),
            row("AUTHOR", "Author", left.displayAuthor, right.displayAuthor),
            row("PREKLAD", "Translator", left.translator, right.translator),
            row("LANGUAGE", "Language", left.language, right.language),
            row("PUBLISHER", "Publisher", left.publisher, right.publisher),
            row("YEAR", "Year", left.year, right.year),
            row("ISBN", "ISBN", left.isbn, right.isbn),
            row("EDITION", "Statement", left.editionStatement, right.editionStatement),
            row("PAGES", "Pages", left.pageCount?.formatted(), right.pageCount?.formatted()),
            row("SIZE", "Size", totalSize(left), totalSize(right)),
            row("FORMATS", "Formats", formats(left), formats(right)),
            row("HIGHLIGHTS", "Highlights", left.highlights.count.formatted(), right.highlights.count.formatted()),
            row(
                "RATING",
                "Rating",
                left.rating.map { "\($0.formatted())/5" },
                right.rating.map { "\($0.formatted())/5" }
            ),
        ]
    }

    private func row(
        _ terminalLabel: String,
        _ nativeLabel: LocalizedStringKey,
        _ left: String?,
        _ right: String?
    ) -> CompareRow {
        let left = displayValue(left)
        let right = displayValue(right)
        return CompareRow(
            terminalLabel: terminalLabel,
            nativeLabel: nativeLabel,
            left: left,
            right: right,
            differs: left != right
        )
    }

    private func formats(_ book: Book) -> String {
        book.assetFormats.formatted()
    }

    private func totalSize(_ book: Book) -> String {
        let total = book.assets.isEmpty
            ? book.fileSizeBytes
            : book.assets.filter { $0.validationStatus != .missing }.reduce(0) { $0 + $1.sizeBytes }
        return total > 0 ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : "\u{2014}"
    }

    private func displayValue(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return "\u{2014}"
        }
        return value
    }
}

private struct EditionCompareToolbar: View {
    let onDone: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Text(theme.usesTerminalCopy ? "// compare_editions" : "Compare Editions")
                .font(theme.body(size: 15, weight: .bold))
            Spacer()
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

private struct EditionCompareHeader: View {
    let book: Book

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            BookCoverImageView(book: book, tier: .thumb)
                .frame(width: 38, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(book.displayTitle)
                .font(theme.body(size: 12, weight: .bold))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }
}

private struct EditionCompareValue: View {
    let value: String
    let differs: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        Text(value)
            .font(theme.label(size: 11))
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(differs ? theme.highlight.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct CompareRow: Identifiable {
    let terminalLabel: String
    let nativeLabel: LocalizedStringKey
    let left: String
    let right: String
    let differs: Bool

    var id: String { terminalLabel }
}
