import SwiftUI

@MainActor
enum SeriesSuggestions {
    static func ranked(from books: [Book]) -> [String] {
        var counts: [String: Int] = [:]
        for book in books {
            guard let series = book.series, !series.isEmpty else { continue }
            counts[series, default: 0] += 1
        }
        return ranked(counts: counts)
    }

    nonisolated static func ranked(counts: [String: Int]) -> [String] {
        counts.keys.sorted {
            let left = counts[$0] ?? 0
            let right = counts[$1] ?? 0
            if left != right { return left > right }
            let order = $0.localizedCaseInsensitiveCompare($1)
            if order != .orderedSame { return order == .orderedAscending }
            return $0 < $1
        }
    }

    // Common wrappers do not make a distinct series ("Mistborn" vs "Mistborn Trilogy").
    nonisolated static func unificationTips(counts: [String: Int]) -> [(original: String, suggestion: String)] {
        let groups = Dictionary(grouping: counts.keys, by: familyMatchKey)
        var tips: [(original: String, suggestion: String)] = []
        for (key, variants) in groups where variants.count > 1 && !key.isEmpty {
            guard let canonical = canonicalName(in: variants, counts: counts) else { continue }
            for variant in variants where variant != canonical {
                tips.append((original: variant, suggestion: canonical))
            }
        }
        return tips.sorted {
            let order = $0.original.localizedCaseInsensitiveCompare($1.original)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.original < $1.original
        }
    }

    nonisolated static func canonicalNamesByMatchKey(counts: [String: Int]) -> [String: String] {
        let groups = Dictionary(grouping: counts.keys, by: familyMatchKey)
        return groups.reduce(into: [:]) { result, group in
            guard !group.key.isEmpty,
                  let canonical = canonicalName(in: group.value, counts: counts) else { return }
            result[group.key] = canonical
        }
    }

    nonisolated static func familyMatchKey(_ name: String) -> String {
        var words = name
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        if words.first == "the" { words.removeFirst() }

        var removedSuffix = true
        while removedSuffix, !words.isEmpty {
            removedSuffix = false
            if words.count >= 2, words.suffix(2).elementsEqual(["publication", "order"]) {
                words.removeLast(2)
                removedSuffix = true
                continue
            }
            switch words.last {
            case "series", "saga", "trilogy", "mystery", "mysteries", "publication":
                words.removeLast()
                removedSuffix = true
            default:
                break
            }
        }

        let key = words.joined()
        return key.isEmpty ? name.normalizedMatchKey : key
    }

    nonisolated private static func canonicalName(
        in variants: [String],
        counts: [String: Int]
    ) -> String? {
        variants.sorted { lhs, rhs in
            let left = counts[lhs] ?? 0
            let right = counts[rhs] ?? 0
            if left != right { return left > right }

            let leftAccents = lhs.unicodeScalars.count { !$0.isASCII }
            let rightAccents = rhs.unicodeScalars.count { !$0.isASCII }
            if leftAccents != rightAccents { return leftAccents > rightAccents }
            if lhs.count != rhs.count { return lhs.count > rhs.count }

            let order = lhs.localizedCaseInsensitiveCompare(rhs)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs < rhs
        }.first
    }
}

private struct SeriesAutocompleteModifier: ViewModifier {
    @Binding var text: String
    let suggestions: [String]
    @State private var matches: [String] = []

    func body(content: Content) -> some View {
        content
            .textInputSuggestions {
                ForEach(matches, id: \.self) { name in
                    Text(verbatim: name)
                        .textInputCompletion(name)
                }
            }
            .onChange(of: text, initial: true) { recomputeMatches() }
            .onChange(of: suggestions, initial: true) { recomputeMatches() }
    }

    private func recomputeMatches() {
        guard !suggestions.isEmpty else {
            matches = []
            return
        }
        let query = text.normalizedMatchKey
        let filtered = query.isEmpty
            ? suggestions.filter { $0 != text }
            : suggestions.filter { $0.normalizedMatchKey.contains(query) && $0 != text }
        matches = Array(filtered.prefix(8))
    }
}

struct SeriesSuggestionMenu: View {
    @Binding var text: String
    let suggestions: [String]

    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            ForEach(suggestions, id: \.self) { name in
                Button {
                    text = name
                } label: {
                    Text(verbatim: name)
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(suggestions.isEmpty)
        .help(theme.styledText(terminal: "choose_series", native: "Choose Series"))
        .accessibilityLabel(theme.styledText(terminal: "choose_series", native: "Choose Series"))
    }
}

extension View {
    func seriesAutocomplete(text: Binding<String>, suggestions: [String]) -> some View {
        modifier(SeriesAutocompleteModifier(text: text, suggestions: suggestions))
    }
}
