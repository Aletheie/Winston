import Foundation

nonisolated enum MetadataCleanupRisk: Int, CaseIterable, Sendable, Hashable {
    case safe
    case review
    case informational
}

nonisolated enum MetadataCleanupField: String, CaseIterable, Sendable, Hashable {
    case title
    case author
    case publisher
    case language
    case isbn
    case series
    case seriesIndex
    case tags
}

nonisolated enum MetadataCleanupValue: Sendable, Equatable, Hashable {
    case text(String?)
    case tags([String])

    var displayText: String {
        switch self {
        case .text(let value):
            value ?? String(localized: "Empty")
        case .tags(let values):
            values.joined(separator: ", ")
        }
    }
}

nonisolated struct MetadataCleanupChange: Sendable, Equatable, Hashable, Identifiable {
    let bookID: UUID
    let bookTitle: String
    let field: MetadataCleanupField
    let before: MetadataCleanupValue
    let after: MetadataCleanupValue

    var id: String {
        "\(bookID.uuidString):\(field.rawValue):\(before.displayText):\(after.displayText)"
    }

    var inverse: MetadataCleanupChange {
        MetadataCleanupChange(
            bookID: bookID,
            bookTitle: bookTitle,
            field: field,
            before: after,
            after: before
        )
    }
}

nonisolated struct MetadataCleanupGroup: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let risk: MetadataCleanupRisk
    let changes: [MetadataCleanupChange]

    var affectedBookIDs: Set<UUID> {
        Set(changes.map(\.bookID))
    }

    var isApplicable: Bool {
        risk != .informational && changes.contains { $0.before != $0.after }
    }

    func replacingPreferredText(_ value: String) -> MetadataCleanupGroup {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement: MetadataCleanupValue = .text(
            trimmed.isEmpty ? nil : value
        )
        return MetadataCleanupGroup(
            id: id,
            title: title,
            detail: detail,
            risk: risk,
            changes: changes.map {
                guard case .text = $0.after else { return $0 }
                return MetadataCleanupChange(
                    bookID: $0.bookID,
                    bookTitle: $0.bookTitle,
                    field: $0.field,
                    before: $0.before,
                    after: replacement
                )
            }
        )
    }
}

nonisolated enum MetadataCleanupScope: Sendable, Equatable, Hashable {
    case wholeLibrary
    case books(ids: Set<UUID>, label: String)

    var label: String {
        switch self {
        case .wholeLibrary:
            String(localized: "Whole Library")
        case .books(_, let label):
            label
        }
    }
}

nonisolated struct MetadataCleanupAnalysis: Sendable, Equatable {
    let scope: MetadataCleanupScope
    let scannedBookCount: Int
    let groups: [MetadataCleanupGroup]

    var changeCount: Int {
        groups.reduce(0) { $0 + $1.changes.count }
    }
}

nonisolated struct MetadataCleanupProgress: Sendable, Equatable {
    let completedCount: Int
    let totalCount: Int

    var fraction: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }
}

nonisolated struct MetadataCleanupConflict: Sendable, Equatable, Identifiable {
    let change: MetadataCleanupChange
    let currentValue: MetadataCleanupValue?

    var id: String { change.id }
}

nonisolated struct MetadataCleanupApplyResult: Sendable, Equatable {
    let requestedChangeCount: Int
    let appliedChanges: [MetadataCleanupChange]
    let conflicts: [MetadataCleanupConflict]
    let missingBookIDs: Set<UUID>

    var appliedBookIDs: Set<UUID> {
        Set(appliedChanges.map(\.bookID))
    }

    var appliedCount: Int { appliedChanges.count }
    var conflictCount: Int { conflicts.count + missingBookIDs.count }
}

nonisolated enum MetadataCleanupFinder {
    static func analysis(
        rows: [MetadataFixRow],
        scope: MetadataCleanupScope
    ) -> MetadataCleanupAnalysis {
        var groups: [MetadataCleanupGroup] = []
        var changesByKey: [GroupKey: [MetadataCleanupChange]] = [:]
        let reviewSuggestionGroups = reviewGroups(rows: rows)
        let publisherSuggestionGroups = publisherVariantGroups(rows: rows)
        let reviewedFields = Set(
            (reviewSuggestionGroups + publisherSuggestionGroups)
                .flatMap(\.changes)
                .map { BookFieldKey(bookID: $0.bookID, field: $0.field) }
        )

        for row in rows {
            guard !Task.isCancelled else {
                return MetadataCleanupAnalysis(
                    scope: scope,
                    scannedBookCount: 0,
                    groups: []
                )
            }
            guard let bookID = row.bookID else { continue }
            let bookTitle = row.title?.nonemptyCleanupValue
                ?? row.originalFileName
                ?? String(localized: "Untitled")

            appendTextNormalization(
                row.storedTitle,
                field: .title,
                bookID: bookID,
                bookTitle: bookTitle,
                into: &changesByKey
            )
            if !reviewedFields.contains(BookFieldKey(bookID: bookID, field: .author)) {
                appendTextNormalization(
                    row.storedAuthor,
                    field: .author,
                    bookID: bookID,
                    bookTitle: bookTitle,
                    into: &changesByKey
                )
            }
            if !reviewedFields.contains(BookFieldKey(bookID: bookID, field: .publisher)) {
                appendTextNormalization(
                    row.publisher,
                    field: .publisher,
                    bookID: bookID,
                    bookTitle: bookTitle,
                    into: &changesByKey
                )
            }
            if !reviewedFields.contains(BookFieldKey(bookID: bookID, field: .series)) {
                appendTextNormalization(
                    row.series,
                    field: .series,
                    bookID: bookID,
                    bookTitle: bookTitle,
                    into: &changesByKey
                )
            }

            if let language = row.language?.nonemptyCleanupValue {
                let normalized = MetadataNormalizer.language(language)
                if normalized.status == .recognized,
                   let canonical = normalized.canonicalTag,
                   canonical != language {
                    append(
                        MetadataCleanupChange(
                            bookID: bookID,
                            bookTitle: bookTitle,
                            field: .language,
                            before: .text(row.language),
                            after: .text(canonical)
                        ),
                        risk: .safe,
                        title: String(localized: "Canonical language tags"),
                        detail: String(localized: "Replace recognized language names and aliases with canonical BCP 47 tags."),
                        into: &changesByKey
                    )
                } else if normalized.status == .unrecognized {
                    groups.append(informationalGroup(
                        id: "language:\(bookID.uuidString)",
                        title: String(localized: "Unrecognized language"),
                        detail: String(localized: "Review “\(language)” for \(bookTitle)."),
                        change: MetadataCleanupChange(
                            bookID: bookID,
                            bookTitle: bookTitle,
                            field: .language,
                            before: .text(row.language),
                            after: .text(row.language)
                        )
                    ))
                }
            }

            if let isbn = row.isbn?.nonemptyCleanupValue {
                let normalized = MetadataNormalizer.isbn(isbn)
                if normalized.status == .valid,
                   let canonical = normalized.canonicalISBN13,
                   canonical != isbn {
                    append(
                        MetadataCleanupChange(
                            bookID: bookID,
                            bookTitle: bookTitle,
                            field: .isbn,
                            before: .text(row.isbn),
                            after: .text(canonical)
                        ),
                        risk: .safe,
                        title: String(localized: "Canonical ISBNs"),
                        detail: String(localized: "Store valid ISBN-10 and formatted ISBN values as ISBN-13 digits."),
                        into: &changesByKey
                    )
                } else if normalized.status == .invalid {
                    groups.append(informationalGroup(
                        id: "isbn:\(bookID.uuidString)",
                        title: String(localized: "Invalid ISBN"),
                        detail: String(localized: "Review “\(isbn)” for \(bookTitle)."),
                        change: MetadataCleanupChange(
                            bookID: bookID,
                            bookTitle: bookTitle,
                            field: .isbn,
                            before: .text(row.isbn),
                            after: .text(row.isbn)
                        )
                    ))
                }
            }

            let normalizedTags = normalizedTags(row.tags)
            if normalizedTags != row.tags {
                append(
                    MetadataCleanupChange(
                        bookID: bookID,
                        bookTitle: bookTitle,
                        field: .tags,
                        before: .tags(row.tags),
                        after: .tags(normalizedTags)
                    ),
                    risk: .safe,
                    title: String(localized: "Clean up tags"),
                    detail: String(localized: "Trim Unicode whitespace, normalize text, remove empty tags, and combine duplicates."),
                    into: &changesByKey
                )
            }
        }

        groups.append(contentsOf: changesByKey.map { key, changes in
            MetadataCleanupGroup(
                id: key.id,
                title: key.title,
                detail: key.detail,
                risk: key.risk,
                changes: changes.sorted(by: changeOrder)
            )
        })
        groups.append(contentsOf: reviewSuggestionGroups)
        groups.append(contentsOf: publisherSuggestionGroups)
        groups.sort {
            if $0.risk != $1.risk { return $0.risk.rawValue < $1.risk.rawValue }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return MetadataCleanupAnalysis(
            scope: scope,
            scannedBookCount: rows.count,
            groups: groups
        )
    }

    private struct GroupKey: Hashable {
        let id: String
        let title: String
        let detail: String
        let risk: MetadataCleanupRisk
    }

    private struct BookFieldKey: Hashable {
        let bookID: UUID
        let field: MetadataCleanupField
    }

    private static func appendTextNormalization(
        _ value: String?,
        field: MetadataCleanupField,
        bookID: UUID,
        bookTitle: String,
        into groups: inout [GroupKey: [MetadataCleanupChange]]
    ) {
        guard let value else { return }
        let normalized = normalizedText(value)
        guard normalized != value else { return }
        append(
            MetadataCleanupChange(
                bookID: bookID,
                bookTitle: bookTitle,
                field: field,
                before: .text(value),
                after: .text(normalized.nonemptyCleanupValue)
            ),
            risk: .safe,
            title: String(localized: "Normalize \(field.localizedName)"),
            detail: String(localized: "Normalize Unicode and collapse unnecessary whitespace."),
            into: &groups
        )
    }

    private static func append(
        _ change: MetadataCleanupChange,
        risk: MetadataCleanupRisk,
        title: String,
        detail: String,
        into groups: inout [GroupKey: [MetadataCleanupChange]]
    ) {
        let key = GroupKey(
            id: "\(risk.rawValue):\(change.field.rawValue):\(change.before.displayText):\(change.after.displayText)",
            title: title,
            detail: detail,
            risk: risk
        )
        groups[key, default: []].append(change)
    }

    private static func reviewGroups(
        rows: [MetadataFixRow]
    ) -> [MetadataCleanupGroup] {
        MetadataFixFinder.analysis(rows: rows).fixes.compactMap { fix in
            let changes: [MetadataCleanupChange]
            switch fix.kind {
            case .author:
                changes = rows.compactMap { row in
                    guard let bookID = row.bookID,
                          row.author?.nonemptyCleanupValue == fix.original else {
                        return nil
                    }
                    return MetadataCleanupChange(
                        bookID: bookID,
                        bookTitle: row.title ?? row.originalFileName ?? fix.original,
                        field: .author,
                        before: .text(row.author),
                        after: .text(fix.suggestion)
                    )
                }
            case .series:
                changes = rows.compactMap { row in
                    guard let bookID = row.bookID,
                          row.series == fix.original else { return nil }
                    return MetadataCleanupChange(
                        bookID: bookID,
                        bookTitle: row.title ?? row.originalFileName ?? fix.original,
                        field: .series,
                        before: .text(row.series),
                        after: .text(fix.suggestion)
                    )
                }
            case .seriesAssignment:
                changes = rows.compactMap { row -> [MetadataCleanupChange]? in
                    guard row.bookID == fix.bookID, let bookID = row.bookID else {
                        return nil
                    }
                    var result = [
                        MetadataCleanupChange(
                            bookID: bookID,
                            bookTitle: row.title ?? row.originalFileName ?? fix.original,
                            field: .series,
                            before: .text(row.series),
                            after: .text(fix.suggestion)
                        )
                    ]
                    if row.seriesIndex?.nonemptyCleanupValue == nil,
                       let index = fix.seriesIndex {
                        result.append(MetadataCleanupChange(
                            bookID: bookID,
                            bookTitle: row.title ?? row.originalFileName ?? fix.original,
                            field: .seriesIndex,
                            before: .text(row.seriesIndex),
                            after: .text(index)
                        ))
                    }
                    return result
                }.flatMap { $0 }
            }
            guard !changes.isEmpty else { return nil }
            return MetadataCleanupGroup(
                id: "review:\(fix.id)",
                title: fix.kind.cleanupTitle,
                detail: String(
                    localized: "Review \(fix.original) → \(fix.suggestion) before applying."
                ),
                risk: .review,
                changes: changes.sorted(by: changeOrder)
            )
        }
    }

    private static func publisherVariantGroups(
        rows: [MetadataFixRow]
    ) -> [MetadataCleanupGroup] {
        struct Candidate {
            let row: MetadataFixRow
            let rawValue: String
            let normalizedValue: String
        }

        var populated: [Candidate] = []
        populated.reserveCapacity(rows.count)
        for row in rows {
            guard !Task.isCancelled else { return [] }
            guard let rawValue = row.publisher,
                  let normalizedValue = normalizedText(rawValue).nonemptyCleanupValue else {
                continue
            }
            populated.append(Candidate(
                row: row,
                rawValue: rawValue,
                normalizedValue: normalizedValue
            ))
        }
        let families = Dictionary(grouping: populated) {
            MetadataNormalizer.comparisonKey($0.normalizedValue)
        }
        return families.compactMap { element -> MetadataCleanupGroup? in
            let key = element.key
            let members = element.value
            let counts = Dictionary(grouping: members, by: \.normalizedValue)
                .mapValues(\.count)
            guard counts.count > 1,
                  let preferred = counts.max(by: {
                      if $0.value != $1.value { return $0.value < $1.value }
                      return $0.key > $1.key
                  })?.key else { return nil }
            let changes: [MetadataCleanupChange] = members.compactMap {
                member -> MetadataCleanupChange? in
                let row = member.row
                guard member.rawValue != preferred, let bookID = row.bookID else {
                    return nil
                }
                return MetadataCleanupChange(
                    bookID: bookID,
                    bookTitle: row.title ?? row.originalFileName ?? member.rawValue,
                    field: .publisher,
                    before: .text(row.publisher),
                    after: .text(preferred)
                )
            }
            guard !changes.isEmpty else { return nil }
            return MetadataCleanupGroup(
                id: "publisher:\(key)",
                title: String(localized: "Unify publisher variants"),
                detail: String(localized: "Prefer “\(preferred)” for equivalent publisher names."),
                risk: .review,
                changes: changes.sorted(by: changeOrder)
            )
        }
    }

    private static func informationalGroup(
        id: String,
        title: String,
        detail: String,
        change: MetadataCleanupChange
    ) -> MetadataCleanupGroup {
        MetadataCleanupGroup(
            id: "info:\(id)",
            title: title,
            detail: detail,
            risk: .informational,
            changes: [change]
        )
    }

    private static func normalizedText(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.compactMap { raw in
            let value = normalizedText(raw)
            guard !value.isEmpty else { return nil }
            let key = MetadataNormalizer.tagComparisonKey(value)
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

    private static func changeOrder(
        _ lhs: MetadataCleanupChange,
        _ rhs: MetadataCleanupChange
    ) -> Bool {
        if lhs.bookTitle != rhs.bookTitle {
            return lhs.bookTitle.localizedStandardCompare(rhs.bookTitle)
                == .orderedAscending
        }
        return lhs.field.rawValue < rhs.field.rawValue
    }
}

extension MetadataCleanupField {
    nonisolated var localizedName: String {
        switch self {
        case .title: String(localized: "titles")
        case .author: String(localized: "authors")
        case .publisher: String(localized: "publishers")
        case .language: String(localized: "languages")
        case .isbn: String(localized: "ISBNs")
        case .series: String(localized: "series names")
        case .seriesIndex: String(localized: "series indexes")
        case .tags: String(localized: "tags")
        }
    }
}

private extension MetadataFix.Kind {
    nonisolated var cleanupTitle: String {
        switch self {
        case .author: String(localized: "Reorder author names")
        case .series: String(localized: "Unify series variants")
        case .seriesAssignment: String(localized: "Assign inferred series")
        }
    }
}

private extension String {
    nonisolated var nonemptyCleanupValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
