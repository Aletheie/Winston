import Foundation

nonisolated enum LibraryRelativeDateFilter {
    static let recentlyAddedInterval: TimeInterval = 14 * 24 * 3_600

    static func recentlyAddedCutoff(relativeTo now: Date) -> Date {
        now.addingTimeInterval(-recentlyAddedInterval)
    }
}

nonisolated struct LibraryNormalizedStrings: Equatable, Sendable {
    let title: String
    let author: String
    let tags: [String]
    let series: String
    let notes: String
    let translator: String
    let language: String
    let format: String
    let shelf: String
    let year: Int?
    let normalizedLanguage: NormalizedLanguage

    init(
        title: String,
        author: String,
        tags: [String] = [],
        series: String? = nil,
        notes: String? = nil,
        translator: String? = nil,
        language: String? = nil,
        format: String,
        shelf: String? = nil,
        year: Int? = nil
    ) {
        self.title = Self.normalize(title)
        self.author = Self.normalize(author)
        self.tags = tags.map(MetadataNormalizer.tagComparisonKey)
        self.series = Self.normalize(series)
        self.notes = Self.normalize(notes)
        self.translator = Self.normalize(translator)
        normalizedLanguage = MetadataNormalizer.language(language)
        self.language = MetadataNormalizer.languageSearchText(language)
        self.format = MetadataNormalizer.formatFilterKey(format)
        self.shelf = Self.normalize(shelf)
        self.year = year
    }

    func matches(_ query: LibraryQuery.NormalizedQuery) -> Bool {
        if !query.freeText.isEmpty {
            let value = query.freeText
            let hit = title.contains(value)
                || author.contains(value)
                || tags.contains(where: { $0.contains(value) })
                || series.contains(value)
                || notes.contains(value)
                || translator.contains(value)
                || language.contains(value)
                || shelf.contains(value)
            if !hit { return false }
        }
        if !query.authors.allSatisfy(author.contains) { return false }
        if !query.tags.allSatisfy({ requested in
            tags.contains { $0.contains(requested) }
        }) { return false }
        if !query.series.allSatisfy(series.contains) { return false }
        if !query.titles.allSatisfy(title.contains) { return false }
        if !query.formats.allSatisfy({ format == $0 }) { return false }
        if !query.languages.allSatisfy({
            MetadataNormalizer.languageMatches(
                actual: normalizedLanguage,
                operand: $0
            )
        }) { return false }
        if !query.translators.allSatisfy(translator.contains) { return false }
        if let constraint = query.year {
            guard let year else { return false }
            switch constraint.op {
            case .equal: if year != constraint.value { return false }
            case .lessThan: if year >= constraint.value { return false }
            case .greaterThan: if year <= constraint.value { return false }
            }
        }
        return true
    }

    static func normalize(_ value: String?) -> String {
        MetadataNormalizer.searchKey(value)
    }
}

nonisolated struct LibraryDisplaySort: Hashable, Sendable {
    enum Field: Hashable, Sendable {
        case source
        case title
        case author
        case dateAdded
        case rating
    }

    let field: Field
    let ascending: Bool

    static let sourceOrder = LibraryDisplaySort(field: .source, ascending: true)
}

nonisolated struct LibraryQuerySpec: Hashable, Sendable {
    let filter: LibraryFilter
    let searchText: String
    let sort: LibraryDisplaySort
    let savedSearch: String?
    let smartShelf: SmartShelfDefinition?
    let deviceFileNames: Set<String>
    let deviceIsConnected: Bool
    let kindlePresenceFilter: KindlePresenceFilter
}

/// The rebuildable, immutable library projection shared by display, search, facets,
/// smart shelves, plugins, and Kindle planning. SwiftData models never leave MainActor.
nonisolated struct LibraryBookRecord: Equatable, Sendable {
    let id: UUID
    /// Capture-time hint for standalone reference queries. The live read model owns
    /// source order separately, so membership changes do not rewrite every record.
    let sourceOrdinal: Int
    let displayTitle: String
    let displayAuthor: String
    let title: String?
    let author: String?
    let publisher: String?
    let language: String?
    let isbn: String?
    let translator: String?
    let canonicalLanguageTag: String?
    let baseLanguageCode: String?
    let languageScriptCode: String?
    let languageRegionCode: String?
    let languageNormalizationStatus: MetadataLanguageNormalizationStatus
    let canonicalISBN13: String?
    let dateAdded: Date
    let rating: Int
    let userRating: Int?
    let readingStatus: ReadingStatus
    let format: String
    let tags: [String]
    let series: String?
    let seriesIndex: Double
    let pageCount: Int?
    let collectionIDs: [UUID]
    let normalized: LibraryNormalizedStrings
    let hasHighlights: Bool
    let drmProtected: Bool
    let elevenReaderReady: Bool
    let deviceMatchKeys: Set<String>
    let hasMissingMetadata: Bool
    let pluginBook: PluginBookDTO?
    let kindleCandidate: KindleSyncCandidate?
    let kindleTransferDescriptor: KindleSendDescriptor?

    init(
        id: UUID,
        sourceOrdinal: Int,
        displayTitle: String,
        displayAuthor: String,
        title: String? = nil,
        author: String? = nil,
        publisher: String? = nil,
        language: String? = nil,
        isbn: String? = nil,
        translator: String? = nil,
        dateAdded: Date,
        rating: Int,
        userRating: Int? = nil,
        readingStatus: ReadingStatus,
        format: String,
        tags: [String],
        series: String?,
        seriesIndex: Double,
        pageCount: Int? = nil,
        collectionIDs: [UUID],
        normalized: LibraryNormalizedStrings? = nil,
        hasHighlights: Bool = false,
        drmProtected: Bool = false,
        elevenReaderReady: Bool = false,
        deviceMatchKeys: Set<String> = [],
        hasMissingMetadata: Bool = false,
        pluginBook: PluginBookDTO? = nil,
        kindleCandidate: KindleSyncCandidate? = nil,
        kindleTransferDescriptor: KindleSendDescriptor? = nil
    ) {
        self.id = id
        self.sourceOrdinal = sourceOrdinal
        self.displayTitle = displayTitle
        self.displayAuthor = displayAuthor
        self.title = title
        self.author = author
        self.publisher = publisher
        self.language = language
        self.isbn = isbn
        self.translator = translator
        let normalizedLanguage = MetadataNormalizer.language(language)
        canonicalLanguageTag = normalizedLanguage.canonicalTag
        baseLanguageCode = normalizedLanguage.baseLanguageCode
        languageScriptCode = normalizedLanguage.scriptCode
        languageRegionCode = normalizedLanguage.regionCode
        languageNormalizationStatus = normalizedLanguage.status
        canonicalISBN13 = MetadataNormalizer.canonicalISBN13(isbn)
        self.dateAdded = dateAdded
        self.rating = rating
        self.userRating = userRating
        self.readingStatus = readingStatus
        self.format = format
        self.tags = tags
        self.series = series
        self.seriesIndex = seriesIndex
        self.pageCount = pageCount
        self.collectionIDs = collectionIDs
        self.normalized = normalized ?? LibraryNormalizedStrings(
            title: displayTitle,
            author: author ?? displayAuthor,
            tags: tags,
            series: series,
            translator: translator,
            language: language,
            format: format
        )
        self.hasHighlights = hasHighlights
        self.drmProtected = drmProtected
        self.elevenReaderReady = elevenReaderReady
        self.deviceMatchKeys = deviceMatchKeys
        self.hasMissingMetadata = hasMissingMetadata
        self.pluginBook = pluginBook
        self.kindleCandidate = kindleCandidate
        self.kindleTransferDescriptor = kindleTransferDescriptor
    }

    @MainActor init(
        _ book: Book,
        sourceOrdinal: Int,
        includeCollections: Bool,
        includeHighlights: Bool
    ) {
        let hasDigitalFile = book.hasCatalogDigitalFile
        let kindleSnapshot = KindleSendPreparation.snapshot(for: book)
        let catalogFormat = book.format
        let deviceMatchKeys: Set<String> = [
            Book.catalogDeviceMatchKey(
                originalFileName: book.originalFileName,
                ownerID: book.uuid,
                hasDigitalFile: hasDigitalFile
            ),
            Book.catalogAllocatedDeviceMatchKey(
                originalFileName: book.originalFileName,
                ownerID: book.uuid,
                hasDigitalFile: hasDigitalFile
            ),
        ]
        id = book.uuid
        self.sourceOrdinal = sourceOrdinal
        displayTitle = book.displayTitle
        displayAuthor = book.sortAuthor
        title = book.title
        author = book.displayAuthor
        publisher = book.publisher
        language = book.language
        isbn = book.isbn
        translator = book.translator
        let normalizedLanguage = MetadataNormalizer.language(book.language)
        canonicalLanguageTag = normalizedLanguage.canonicalTag
        baseLanguageCode = normalizedLanguage.baseLanguageCode
        languageScriptCode = normalizedLanguage.scriptCode
        languageRegionCode = normalizedLanguage.regionCode
        languageNormalizationStatus = normalizedLanguage.status
        canonicalISBN13 = MetadataNormalizer.canonicalISBN13(book.isbn)
        dateAdded = book.dateAdded
        rating = book.sortRating
        userRating = book.rating
        readingStatus = book.readingStatus
        format = catalogFormat
        tags = book.tags
        series = book.series
        seriesIndex = book.seriesIndex.flatMap(Double.init) ?? .greatestFiniteMagnitude
        pageCount = book.pageCount
        collectionIDs = includeCollections
            ? book.collections.map(\.id).sorted { $0.uuidString < $1.uuidString }
            : []
        normalized = LibraryNormalizedStrings(
            title: book.displayTitle,
            author: book.displayAuthor ?? "",
            tags: book.tags,
            series: book.series,
            notes: book.notes,
            translator: book.translator,
            language: book.language,
            format: catalogFormat,
            shelf: book.shelfLocation,
            year: book.year.flatMap { Int($0.prefix(4)) }
        )
        hasHighlights = includeHighlights && !book.highlights.isEmpty
        drmProtected = book.primaryDRMProtected == true
        elevenReaderReady = ElevenReaderHandoff.file(for: book) != nil
        self.deviceMatchKeys = deviceMatchKeys
        hasMissingMetadata = Self.isBlank(book.title)
            || Self.isBlank(book.author)
            || Self.isBlank(book.language)
        pluginBook = PluginBookDTO(book)
        kindleCandidate = KindleSendPreparation.candidate(for: kindleSnapshot)
        kindleTransferDescriptor = KindleSendPreparation.descriptor(
            for: kindleSnapshot
        )
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.displayTitle == rhs.displayTitle
            && lhs.displayAuthor == rhs.displayAuthor
            && lhs.title == rhs.title
            && lhs.author == rhs.author
            && lhs.publisher == rhs.publisher
            && lhs.language == rhs.language
            && lhs.isbn == rhs.isbn
            && lhs.translator == rhs.translator
            && lhs.canonicalLanguageTag == rhs.canonicalLanguageTag
            && lhs.baseLanguageCode == rhs.baseLanguageCode
            && lhs.languageScriptCode == rhs.languageScriptCode
            && lhs.languageRegionCode == rhs.languageRegionCode
            && lhs.languageNormalizationStatus == rhs.languageNormalizationStatus
            && lhs.canonicalISBN13 == rhs.canonicalISBN13
            && lhs.dateAdded == rhs.dateAdded
            && lhs.rating == rhs.rating
            && lhs.userRating == rhs.userRating
            && lhs.readingStatus == rhs.readingStatus
            && lhs.format == rhs.format
            && lhs.tags == rhs.tags
            && lhs.series == rhs.series
            && lhs.seriesIndex == rhs.seriesIndex
            && lhs.pageCount == rhs.pageCount
            && lhs.collectionIDs == rhs.collectionIDs
            && lhs.normalized == rhs.normalized
            && lhs.hasHighlights == rhs.hasHighlights
            && lhs.drmProtected == rhs.drmProtected
            && lhs.elevenReaderReady == rhs.elevenReaderReady
            && lhs.deviceMatchKeys == rhs.deviceMatchKeys
            && lhs.hasMissingMetadata == rhs.hasMissingMetadata
            && lhs.pluginBook == rhs.pluginBook
            && lhs.kindleCandidate == rhs.kindleCandidate
            && lhs.kindleTransferDescriptor == rhs.kindleTransferDescriptor
    }
}

enum LibraryQuery {
    /// Compile once per query, including incremental display batches.
    nonisolated struct Matcher: Sendable {
        private let spec: LibraryQuerySpec
        private let visibleQuery: NormalizedQuery
        private let savedQuery: NormalizedQuery?
        private let smartShelf: CompiledSmartShelfDefinition?
        private let recentCutoff: Date
        private let facetKey: String?

        init(_ spec: LibraryQuerySpec, now: Date = .now) {
            self.spec = spec
            visibleQuery = NormalizedQuery(SearchQuery.parse(spec.searchText))
            savedQuery = spec.savedSearch.map { NormalizedQuery(SearchQuery.parse($0)) }
            smartShelf = spec.smartShelf?.compiled
            recentCutoff = LibraryRelativeDateFilter.recentlyAddedCutoff(relativeTo: now)
            facetKey = switch spec.filter {
            case .format(let value): MetadataNormalizer.formatFilterKey(value)
            case .tag(let value): MetadataNormalizer.tagComparisonKey(value)
            default: nil
            }
        }

        func matches(_ book: LibraryBookRecord) -> Bool {
            let belongs: Bool
            if let smartShelf {
                belongs = smartShelf.matches(
                    book,
                    deviceFileNames: spec.deviceFileNames,
                    deviceIsConnected: spec.deviceIsConnected
                )
            } else if let savedQuery {
                belongs = book.normalized.matches(savedQuery)
            } else {
                belongs = switch spec.filter {
                case .all: true
                case .recentlyAdded: book.dateAdded > recentCutoff
                case .status(let status): book.readingStatus == status
                case .collection(let id): book.collectionIDs.contains(id)
                case .format: book.normalized.format == facetKey
                case .author(let author): book.displayAuthor == author
                case .series(let series): book.series == series
                case .tag: book.normalized.tags.contains { $0 == facetKey }
                case .rated: book.rating > 0
                case .elevenReader: book.elevenReaderReady
                }
            }
            return belongs
                && book.normalized.matches(visibleQuery)
                && spec.kindlePresenceFilter.includes(
                    deviceMatchKeys: book.deviceMatchKeys,
                    deviceFileNames: spec.deviceFileNames,
                    deviceIsConnected: spec.deviceIsConnected
                )
        }
    }

    static func apply(to books: [Book],
                      filter: LibraryFilter,
                      searchText: String,
                      sort: LibraryDisplaySort,
                      now: Date = .now) -> [Book] {
        let records = books.enumerated().map {
            LibraryBookRecord(
                $0.element,
                sourceOrdinal: $0.offset,
                includeCollections: true,
                includeHighlights: false
            )
        }
        let ids = displayIDs(
            for: records,
            filter: filter,
            searchText: searchText,
            sort: sort,
            savedSearch: nil,
            smartShelf: nil,
            deviceFileNames: [],
            deviceIsConnected: false,
            now: now
        )
        let booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.uuid, $0) })
        return ids.compactMap { booksByID[$0] }
    }

    static func applySmartShelf(
        to books: [Book],
        definition: SmartShelfDefinition,
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool,
        sort: LibraryDisplaySort
    ) -> [Book] {
        let includeHighlights = definition.compiled.requiresHighlights
        let records = books.enumerated().map {
            LibraryBookRecord(
                $0.element,
                sourceOrdinal: $0.offset,
                includeCollections: false,
                includeHighlights: includeHighlights
            )
        }
        let ids = displayIDs(
            for: records,
            filter: .all,
            searchText: "",
            sort: sort,
            savedSearch: nil,
            smartShelf: definition,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected
        )
        let booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.uuid, $0) })
        return ids.compactMap { booksByID[$0] }
    }

    nonisolated static func displayIDs(
        for books: [LibraryBookRecord],
        filter: LibraryFilter,
        searchText: String,
        sort: LibraryDisplaySort,
        savedSearch: String?,
        smartShelf: SmartShelfDefinition?,
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool,
        kindlePresenceFilter: KindlePresenceFilter = .all,
        now: Date = .now
    ) -> [UUID] {
        let matcher = Matcher(LibraryQuerySpec(
            filter: filter,
            searchText: searchText,
            sort: sort,
            savedSearch: savedSearch,
            smartShelf: smartShelf,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected,
            kindlePresenceFilter: kindlePresenceFilter
        ), now: now)
        var matching: [LibraryBookRecord] = []
        matching.reserveCapacity(books.count)

        for book in books {
            guard !Task.isCancelled else { return [] }
            guard matcher.matches(book) else { continue }
            matching.append(book)
        }

        guard !Task.isCancelled else { return [] }
        if case .series = filter {
            matching.sort {
                if $0.seriesIndex == $1.seriesIndex {
                    return $0.sourceOrdinal < $1.sourceOrdinal
                }
                return $0.seriesIndex < $1.seriesIndex
            }
        } else if sort.field != .source {
            matching.sort { ordered($0, before: $1, by: sort) }
        }
        return matching.map(\.id)
    }

    nonisolated static func displayIDs(
        for books: [LibraryBookRecord],
        query: LibraryQuerySpec,
        now: Date = .now
    ) -> [UUID] {
        displayIDs(
            for: books,
            filter: query.filter,
            searchText: query.searchText,
            sort: query.sort,
            savedSearch: query.savedSearch,
            smartShelf: query.smartShelf,
            deviceFileNames: query.deviceFileNames,
            deviceIsConnected: query.deviceIsConnected,
            kindlePresenceFilter: query.kindlePresenceFilter,
            now: now
        )
    }

    nonisolated static func displayOrderingChanged(
        from old: LibraryBookRecord,
        to new: LibraryBookRecord,
        query: LibraryQuerySpec
    ) -> Bool {
        if case .series = query.filter {
            return old.seriesIndex != new.seriesIndex
                || old.sourceOrdinal != new.sourceOrdinal
        }
        switch query.sort.field {
        case .source:
            return old.sourceOrdinal != new.sourceOrdinal
        case .title:
            return old.displayTitle != new.displayTitle
                || old.sourceOrdinal != new.sourceOrdinal
        case .author:
            return old.displayAuthor != new.displayAuthor
                || old.sourceOrdinal != new.sourceOrdinal
        case .dateAdded:
            return old.dateAdded != new.dateAdded
                || old.sourceOrdinal != new.sourceOrdinal
        case .rating:
            return old.rating != new.rating
                || old.sourceOrdinal != new.sourceOrdinal
        }
    }

    nonisolated static func displayOrdered(
        _ lhs: LibraryBookRecord,
        before rhs: LibraryBookRecord,
        query: LibraryQuerySpec,
        sourceOrdinals: (Int, Int)? = nil
    ) -> Bool {
        let (leftOrdinal, rightOrdinal) = sourceOrdinals ?? (lhs.sourceOrdinal, rhs.sourceOrdinal)
        if case .series = query.filter {
            if lhs.seriesIndex == rhs.seriesIndex {
                return leftOrdinal < rightOrdinal
            }
            return lhs.seriesIndex < rhs.seriesIndex
        }
        if query.sort.field == .source {
            return leftOrdinal < rightOrdinal
        }
        return ordered(lhs, before: rhs, by: query.sort, sourceOrdinals: sourceOrdinals)
    }

    private nonisolated static func ordered(
        _ lhs: LibraryBookRecord,
        before rhs: LibraryBookRecord,
        by sort: LibraryDisplaySort,
        sourceOrdinals: (Int, Int)? = nil
    ) -> Bool {
        let comparison: ComparisonResult
        switch sort.field {
        case .source:
            comparison = lhs.sourceOrdinal == rhs.sourceOrdinal
                ? .orderedSame
                : (lhs.sourceOrdinal < rhs.sourceOrdinal ? .orderedAscending : .orderedDescending)
        case .title:
            comparison = lhs.displayTitle.compare(rhs.displayTitle)
        case .author:
            comparison = lhs.displayAuthor.compare(rhs.displayAuthor)
        case .dateAdded:
            comparison = lhs.dateAdded == rhs.dateAdded
                ? .orderedSame
                : (lhs.dateAdded < rhs.dateAdded ? .orderedAscending : .orderedDescending)
        case .rating:
            comparison = lhs.rating == rhs.rating
                ? .orderedSame
                : (lhs.rating < rhs.rating ? .orderedAscending : .orderedDescending)
        }

        if comparison == .orderedSame {
            let (left, right) = sourceOrdinals ?? (lhs.sourceOrdinal, rhs.sourceOrdinal)
            return left < right
        }
        return sort.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    static func smartCounts(for books: [Book], searches: [(UUID, String)]) -> [UUID: Int] {
        guard !searches.isEmpty else { return [:] }
        return smartCounts(
            for: books.map(SearchSnapshot.init),
            searches: searches
        )
    }

    static func smartShelfCounts(
        for books: [Book],
        shelves: [(UUID, SmartShelfDefinition)],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) -> [UUID: Int] {
        let compiledShelves = shelves.map { ($0.0, $0.1.compiled) }
        let includeHighlights = compiledShelves.contains {
            $0.1.requiresHighlights
        }
        return smartShelfCounts(
            for: books.map {
                SmartShelfBookSnapshot($0, includeHighlights: includeHighlights)
            },
            compiledShelves: compiledShelves,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected
        )
    }

    nonisolated static func smartShelfCounts(
        for books: [SmartShelfBookSnapshot],
        shelves: [(UUID, SmartShelfDefinition)],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) -> [UUID: Int] {
        smartShelfCounts(
            for: books,
            compiledShelves: shelves.map { ($0.0, $0.1.compiled) },
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected
        )
    }

    private nonisolated static func smartShelfCounts(
        for books: [SmartShelfBookSnapshot],
        compiledShelves: [(UUID, CompiledSmartShelfDefinition)],
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool
    ) -> [UUID: Int] {
        guard !compiledShelves.isEmpty else { return [:] }
        var counts: [UUID: Int] = [:]
        for book in books {
            guard !Task.isCancelled else { return counts }
            for (id, definition) in compiledShelves
            where definition.matches(
                book,
                deviceFileNames: deviceFileNames,
                deviceIsConnected: deviceIsConnected
            ) {
                counts[id, default: 0] += 1
            }
        }
        return counts
    }

    nonisolated static func smartCounts(
        for books: [SearchSnapshot], searches: [(UUID, String)]
    ) -> [UUID: Int] {
        let queries = searches.map { ($0.0, NormalizedQuery(SearchQuery.parse($0.1))) }
        return smartCounts(for: books, queries: queries)
    }

    private nonisolated static func smartCounts(
        for books: [SearchSnapshot], queries: [(UUID, NormalizedQuery)]
    ) -> [UUID: Int] {
        guard !queries.isEmpty else { return [:] }
        var counts: [UUID: Int] = [:]
        for book in books {
            guard !Task.isCancelled else { return counts }
            for (id, query) in queries where book.matches(query) {
                counts[id, default: 0] += 1
            }
        }
        return counts
    }

    nonisolated struct NormalizedQuery: Equatable, Sendable {
        let freeText: String
        let authors: [String]
        let tags: [String]
        let series: [String]
        let titles: [String]
        let formats: [String]
        let languages: [NormalizedLanguage]
        let translators: [String]
        let year: SearchQuery.YearConstraint?

        init(_ query: SearchQuery) {
            freeText = LibraryNormalizedStrings.normalize(query.freeText)
            authors = query.authors.map(LibraryNormalizedStrings.normalize)
            tags = query.tags.map(MetadataNormalizer.tagComparisonKey)
            series = query.series.map(LibraryNormalizedStrings.normalize)
            titles = query.titles.map(LibraryNormalizedStrings.normalize)
            formats = query.formats.map(MetadataNormalizer.formatFilterKey)
            languages = query.languages.map(MetadataNormalizer.language)
            translators = query.translators.map(LibraryNormalizedStrings.normalize)
            year = query.year
        }
    }

    nonisolated struct SearchSnapshot: Equatable, Sendable {
        let normalized: LibraryNormalizedStrings

        init(
            title: String,
            author: String,
            tags: [String] = [],
            series: String = "",
            notes: String = "",
            translator: String = "",
            language: String = "",
            format: String,
            shelf: String = "",
            year: Int? = nil
        ) {
            normalized = LibraryNormalizedStrings(
                title: title,
                author: author,
                tags: tags,
                series: series,
                notes: notes,
                translator: translator,
                language: language,
                format: format,
                shelf: shelf,
                year: year
            )
        }

        @MainActor init(_ book: Book) {
            self.init(book, format: book.format)
        }

        @MainActor init(_ book: Book, format: String) {
            normalized = LibraryNormalizedStrings(
                title: book.displayTitle,
                author: book.displayAuthor ?? "",
                tags: book.tags,
                series: book.series,
                notes: book.notes,
                translator: book.translator,
                language: book.language,
                format: format,
                shelf: book.shelfLocation,
                year: book.year.flatMap { Int($0.prefix(4)) }
            )
        }

        func matches(_ query: NormalizedQuery) -> Bool {
            normalized.matches(query)
        }
    }
}
