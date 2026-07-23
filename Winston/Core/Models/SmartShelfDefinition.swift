import Foundation

nonisolated struct SmartShelfDefinition: Codable, Hashable, Sendable {
    enum MatchMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case all
        case any

        var id: Self { self }

        var label: LocalizedStringResource {
            switch self {
            case .all: "All"
            case .any: "Any"
            }
        }
    }

    var matchMode: MatchMode
    var rules: [SmartShelfRule]

    init(matchMode: MatchMode = .all, rules: [SmartShelfRule] = []) {
        self.matchMode = matchMode
        self.rules = rules
    }

    var isValid: Bool {
        !rules.isEmpty && rules.allSatisfy(\.isValid)
    }

    var requiresHighlights: Bool {
        rules.contains { $0.field == .highlights }
    }

    func matches(
        _ book: SmartShelfBookSnapshot,
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) -> Bool {
        guard !rules.isEmpty else { return false }
        switch matchMode {
        case .all:
            return rules.allSatisfy {
                $0.matches(
                    book,
                    deviceFileNames: deviceFileNames,
                    deviceIsConnected: deviceIsConnected
                )
            }
        case .any:
            return rules.contains {
                $0.matches(
                    book,
                    deviceFileNames: deviceFileNames,
                    deviceIsConnected: deviceIsConnected
                )
            }
        }
    }
}

nonisolated struct SmartShelfRule: Codable, Hashable, Identifiable, Sendable {
    enum Field: String, Codable, CaseIterable, Identifiable, Sendable {
        case readingStatus
        case language
        case pageCount
        case format
        case rating
        case translator
        case tag
        case author
        case title
        case series
        case publisher
        case highlights
        case drmProtected
        case onDevice
        case missingMetadata

        var id: Self { self }

        var label: LocalizedStringResource {
            switch self {
            case .readingStatus: "Reading status"
            case .language: "Language"
            case .pageCount: "Page count"
            case .format: "Format"
            case .rating: "Rating"
            case .translator: "Translator"
            case .tag: "Tag"
            case .author: "Author"
            case .title: "Title"
            case .series: "Series"
            case .publisher: "Publisher"
            case .highlights: "Highlights"
            case .drmProtected: "DRM protection"
            case .onDevice: "On Kindle"
            case .missingMetadata: "Metadata"
            }
        }

        var systemImage: String {
            switch self {
            case .readingStatus: "book"
            case .language: "character.book.closed"
            case .pageCount: "doc.text"
            case .format: "doc"
            case .rating: "star"
            case .translator: "person.text.rectangle"
            case .tag: "tag"
            case .author: "person"
            case .title: "text.book.closed"
            case .series: "books.vertical"
            case .publisher: "building.2"
            case .highlights: "highlighter"
            case .drmProtected: "lock"
            case .onDevice: "ipad.landscape"
            case .missingMetadata: "exclamationmark.circle"
            }
        }

        var comparisons: [Comparison] {
            switch self {
            case .readingStatus, .format:
                [.isEqual, .isNotEqual]
            case .language:
                [.isEqual, .isNotEqual, .contains, .doesNotContain, .isMissing, .isPresent]
            case .pageCount:
                [.lessThan, .greaterThan, .isEqual, .isMissing, .isPresent]
            case .rating:
                [.atLeast, .atMost, .isEqual, .isMissing, .isPresent]
            case .translator, .tag, .author, .title, .series, .publisher:
                [.contains, .doesNotContain, .isEqual, .isNotEqual, .isMissing, .isPresent]
            case .highlights, .drmProtected, .onDevice, .missingMetadata:
                [.isTrue, .isFalse]
            }
        }

        var defaultComparison: Comparison {
            switch self {
            case .readingStatus, .language, .format: .isEqual
            case .pageCount: .lessThan
            case .rating: .atLeast
            case .translator, .tag, .author, .title, .series, .publisher: .contains
            case .highlights, .drmProtected, .onDevice, .missingMetadata: .isTrue
            }
        }

        var defaultValue: String {
            switch self {
            case .readingStatus: ReadingStatus.unread.rawValue
            case .pageCount: "300"
            case .format: "EPUB"
            case .rating: "4"
            default: ""
            }
        }

        var usesNumberValue: Bool { self == .pageCount || self == .rating }
        var usesFormatValue: Bool { self == .format }
        var usesStatusValue: Bool { self == .readingStatus }
    }

    enum Comparison: String, Codable, CaseIterable, Identifiable, Sendable {
        case contains
        case doesNotContain
        case isEqual
        case isNotEqual
        case lessThan
        case greaterThan
        case atLeast
        case atMost
        case isMissing
        case isPresent
        case isTrue
        case isFalse

        var id: Self { self }

        var requiresValue: Bool {
            switch self {
            case .isMissing, .isPresent, .isTrue, .isFalse: false
            default: true
            }
        }

        var label: LocalizedStringResource {
            switch self {
            case .contains: "contains"
            case .doesNotContain: "does not contain"
            case .isEqual: "is"
            case .isNotEqual: "is not"
            case .lessThan: "is less than"
            case .greaterThan: "is greater than"
            case .atLeast: "is at least"
            case .atMost: "is at most"
            case .isMissing: "is missing"
            case .isPresent: "is present"
            case .isTrue: "yes"
            case .isFalse: "no"
            }
        }
    }

    var id: UUID
    var field: Field
    var comparison: Comparison
    var value: String

    init(
        id: UUID = UUID(),
        field: Field = .readingStatus,
        comparison: Comparison? = nil,
        value: String? = nil
    ) {
        self.id = id
        self.field = field
        self.comparison = comparison ?? field.defaultComparison
        self.value = value ?? field.defaultValue
    }

    var isValid: Bool {
        guard field.comparisons.contains(comparison) else { return false }
        guard comparison.requiresValue else { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if field == .pageCount { return Int(trimmed).map { $0 > 0 } == true }
        if field == .rating { return Int(trimmed).map { (0...5).contains($0) } == true }
        if field == .readingStatus { return ReadingStatus(rawValue: trimmed) != nil }
        return true
    }

    mutating func reset(for newField: Field) {
        field = newField
        comparison = newField.defaultComparison
        value = newField.defaultValue
    }

    func matches(
        _ book: SmartShelfBookSnapshot,
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) -> Bool {
        switch field {
        case .readingStatus:
            return stringMatches(book.readingStatusRaw)
        case .language:
            return stringMatches(book.language)
        case .pageCount:
            return numberMatches(book.pageCount)
        case .format:
            return stringMatches(book.format)
        case .rating:
            return numberMatches(book.rating)
        case .translator:
            return stringMatches(book.translator)
        case .tag:
            return stringsMatch(book.tags)
        case .author:
            return stringMatches(book.author)
        case .title:
            return stringMatches(book.title)
        case .series:
            return stringMatches(book.series)
        case .publisher:
            return stringMatches(book.publisher)
        case .highlights:
            return booleanMatches(book.hasHighlights)
        case .drmProtected:
            return booleanMatches(book.drmProtected)
        case .onDevice:
            return booleanMatches(
                deviceIsConnected
                    ? !book.deviceMatchKeys.isDisjoint(with: deviceFileNames)
                    : nil
            )
        case .missingMetadata:
            return booleanMatches(book.hasMissingMetadata)
        }
    }

    private func stringMatches(_ actual: String?) -> Bool {
        let actual = actual?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch comparison {
        case .isMissing:
            return actual?.isEmpty != false
        case .isPresent:
            return actual?.isEmpty == false
        default:
            guard let actual, !actual.isEmpty else {
                return comparison == .doesNotContain || comparison == .isNotEqual
            }
            let normalizedActual = Self.normalized(actual)
            let expected = Self.normalized(value)
            guard !expected.isEmpty else { return false }
            switch comparison {
            case .contains: return normalizedActual.contains(expected)
            case .doesNotContain: return !normalizedActual.contains(expected)
            case .isEqual: return normalizedActual == expected
            case .isNotEqual: return normalizedActual != expected
            default: return false
            }
        }
    }

    private func stringsMatch(_ actual: [String]) -> Bool {
        switch comparison {
        case .isMissing: return actual.isEmpty
        case .isPresent: return !actual.isEmpty
        default:
            let expected = Self.normalized(value)
            guard !expected.isEmpty else { return false }
            let normalized = actual.map(Self.normalized)
            switch comparison {
            case .contains: return normalized.contains { $0.contains(expected) }
            case .doesNotContain: return !normalized.contains { $0.contains(expected) }
            case .isEqual: return normalized.contains(expected)
            case .isNotEqual: return !normalized.contains(expected)
            default: return false
            }
        }
    }

    private func numberMatches(_ actual: Int?) -> Bool {
        switch comparison {
        case .isMissing: return actual == nil
        case .isPresent: return actual != nil
        default:
            guard let actual, let expected = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return false
            }
            switch comparison {
            case .isEqual: return actual == expected
            case .lessThan: return actual < expected
            case .greaterThan: return actual > expected
            case .atLeast: return actual >= expected
            case .atMost: return actual <= expected
            default: return false
            }
        }
    }

    private func booleanMatches(_ actual: Bool?) -> Bool {
        guard let actual else { return false }
        return switch comparison {
        case .isTrue: actual
        case .isFalse: !actual
        default: false
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

nonisolated struct SmartShelfBookSnapshot: Equatable, Sendable {
    let id: UUID
    let title: String?
    let author: String?
    let publisher: String?
    let language: String?
    let translator: String?
    let tags: [String]
    let series: String?
    let pageCount: Int?
    let format: String
    let rating: Int?
    let readingStatusRaw: String
    let hasHighlights: Bool
    let drmProtected: Bool
    let deviceMatchKeys: Set<String>
    let hasMissingMetadata: Bool

    init(
        id: UUID,
        title: String? = nil,
        author: String? = nil,
        publisher: String? = nil,
        language: String? = nil,
        translator: String? = nil,
        tags: [String] = [],
        series: String? = nil,
        pageCount: Int? = nil,
        format: String,
        rating: Int? = nil,
        readingStatusRaw: String = ReadingStatus.unread.rawValue,
        hasHighlights: Bool = false,
        drmProtected: Bool = false,
        deviceMatchKeys: Set<String> = [],
        hasMissingMetadata: Bool = false
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.publisher = publisher
        self.language = language
        self.translator = translator
        self.tags = tags
        self.series = series
        self.pageCount = pageCount
        self.format = format
        self.rating = rating
        self.readingStatusRaw = readingStatusRaw
        self.hasHighlights = hasHighlights
        self.drmProtected = drmProtected
        self.deviceMatchKeys = deviceMatchKeys
        self.hasMissingMetadata = hasMissingMetadata
    }

    @MainActor init(_ book: Book) {
        self.init(book, includeHighlights: true)
    }

    @MainActor init(
        _ book: Book,
        includeHighlights: Bool,
        format: String? = nil,
        deviceMatchKeys: Set<String>? = nil
    ) {
        id = book.uuid
        title = book.title
        author = book.displayAuthor
        publisher = book.publisher
        language = book.language
        translator = book.translator
        tags = book.tags
        series = book.series
        pageCount = book.pageCount
        self.format = format ?? book.format
        rating = book.rating
        readingStatusRaw = book.readingStatus.rawValue
        hasHighlights = includeHighlights && !book.highlights.isEmpty
        drmProtected = book.drmProtected == true
        self.deviceMatchKeys = deviceMatchKeys ?? book.deviceMatchKeys
        hasMissingMetadata = Self.isBlank(book.title)
            || Self.isBlank(book.author)
            || Self.isBlank(book.language)
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }
}

nonisolated enum SmartShelfPreset: String, CaseIterable, Identifiable, Sendable {
    case unread
    case shortUnread
    case notOnKindle
    case missingMetadata
    case czechUnread

    var id: Self { self }

    var label: LocalizedStringResource {
        switch self {
        case .unread: "Unread books"
        case .shortUnread: "Short unread books"
        case .notOnKindle: "Not on Kindle"
        case .missingMetadata: "Missing metadata"
        case .czechUnread: "Unread in Czech"
        }
    }

    var systemImage: String {
        switch self {
        case .unread: "book.closed"
        case .shortUnread: "clock"
        case .notOnKindle: "ipad.landscape.badge.minus"
        case .missingMetadata: "exclamationmark.circle"
        case .czechUnread: "character.book.closed"
        }
    }

    var definition: SmartShelfDefinition {
        switch self {
        case .unread:
            SmartShelfDefinition(rules: [
                SmartShelfRule(field: .readingStatus, value: ReadingStatus.unread.rawValue),
            ])
        case .shortUnread:
            SmartShelfDefinition(rules: [
                SmartShelfRule(field: .readingStatus, value: ReadingStatus.unread.rawValue),
                SmartShelfRule(field: .pageCount, comparison: .lessThan, value: "300"),
            ])
        case .notOnKindle:
            SmartShelfDefinition(rules: [
                SmartShelfRule(field: .onDevice, comparison: .isFalse),
            ])
        case .missingMetadata:
            SmartShelfDefinition(rules: [
                SmartShelfRule(field: .missingMetadata, comparison: .isTrue),
            ])
        case .czechUnread:
            SmartShelfDefinition(rules: [
                SmartShelfRule(field: .readingStatus, value: ReadingStatus.unread.rawValue),
                SmartShelfRule(field: .language, comparison: .isEqual, value: "cs"),
            ])
        }
    }
}
