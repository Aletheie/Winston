import Foundation

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
        self.tags = tags.map(Self.normalize)
        self.series = Self.normalize(series)
        self.notes = Self.normalize(notes)
        self.translator = Self.normalize(translator)
        self.language = Self.normalize(language)
        self.format = Self.normalize(format)
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
        if !query.formats.allSatisfy({ format == Self.normalize($0) }) { return false }
        if !query.languages.allSatisfy({ language == Self.normalize($0) }) { return false }
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
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ) ?? ""
    }
}

nonisolated struct SmartShelfPreviewResult: Equatable, Sendable {
    let matchCount: Int
    let leadingBookIDs: [UUID]
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
    let translator: String?
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
        self.translator = translator
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
        let catalogFormat = Book.catalogFormat(
            fileName: book.primaryAsset?.fileName ?? book.fileName,
            hasDigitalFile: hasDigitalFile,
            hasPhysicalCopy: book.hasPhysicalCopy
        )
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
        translator = book.translator
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
            && lhs.translator == rhs.translator
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
            && lhs.deviceMatchKeys == rhs.deviceMatchKeys
            && lhs.hasMissingMetadata == rhs.hasMissingMetadata
            && lhs.pluginBook == rhs.pluginBook
            && lhs.kindleCandidate == rhs.kindleCandidate
            && lhs.kindleTransferDescriptor == rhs.kindleTransferDescriptor
    }
}

enum LibraryQuery {
    static func apply(to books: [Book],
                      filter: LibraryFilter,
                      searchText: String,
                      sort: [KeyPathComparator<Book>],
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
            sort: displaySort(for: sort),
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
        sort: [KeyPathComparator<Book>]
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
            sort: displaySort(for: sort),
            savedSearch: nil,
            smartShelf: definition,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected
        )
        let booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.uuid, $0) })
        return ids.compactMap { booksByID[$0] }
    }

    nonisolated static func smartShelfPreview(
        for books: [SmartShelfBookSnapshot],
        definition: SmartShelfDefinition,
        deviceFileNames: Set<String>,
        deviceIsConnected: Bool,
        maximumBookCount: Int = 10
    ) -> SmartShelfPreviewResult {
        let limit = max(0, maximumBookCount)
        let compiledDefinition = definition.compiled
        var matchCount = 0
        var leadingBookIDs: [UUID] = []
        leadingBookIDs.reserveCapacity(min(limit, books.count))

        for book in books {
            guard !Task.isCancelled else { break }
            guard compiledDefinition.matches(
                book,
                deviceFileNames: deviceFileNames,
                deviceIsConnected: deviceIsConnected
            ) else { continue }

            matchCount += 1
            if leadingBookIDs.count < limit {
                leadingBookIDs.append(book.id)
            }
        }

        return SmartShelfPreviewResult(
            matchCount: matchCount,
            leadingBookIDs: leadingBookIDs
        )
    }

    @MainActor
    static func displaySort(
        for comparators: [KeyPathComparator<Book>]
    ) -> LibraryDisplaySort {
        guard let first = comparators.first else { return .sourceOrder }
        let ascending = first.order == .forward
        if first == BookSort.title.comparator(ascending: ascending) {
            return LibraryDisplaySort(field: .title, ascending: ascending)
        }
        if first == BookSort.author.comparator(ascending: ascending) {
            return LibraryDisplaySort(field: .author, ascending: ascending)
        }
        if first == BookSort.dateAdded.comparator(ascending: ascending) {
            return LibraryDisplaySort(field: .dateAdded, ascending: ascending)
        }
        if first == BookSort.rating.comparator(ascending: ascending) {
            return LibraryDisplaySort(field: .rating, ascending: ascending)
        }
        return .sourceOrder
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
        let savedQuery = savedSearch.map { NormalizedQuery(SearchQuery.parse($0)) }
        let visibleQuery = NormalizedQuery(SearchQuery.parse(searchText))
        let compiledSmartShelf = smartShelf?.compiled
        let recentCutoff = now.addingTimeInterval(-14 * 24 * 3600)
        var matching: [LibraryBookRecord] = []
        matching.reserveCapacity(books.count)

        for book in books {
            guard !Task.isCancelled else { return [] }
            let belongs: Bool
            if let compiledSmartShelf {
                belongs = compiledSmartShelf.matches(
                    book,
                    deviceFileNames: deviceFileNames,
                    deviceIsConnected: deviceIsConnected
                )
            } else if let savedQuery {
                belongs = book.normalized.matches(savedQuery)
            } else {
                belongs = matches(book, filter: filter, recentCutoff: recentCutoff)
            }

            guard belongs,
                  book.normalized.matches(visibleQuery),
                  kindlePresenceFilter.includes(
                    deviceMatchKeys: book.deviceMatchKeys,
                    deviceFileNames: deviceFileNames,
                    deviceIsConnected: deviceIsConnected
                  ) else { continue }
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

    @concurrent
    static func displayIDsConcurrently(
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
    ) async -> [UUID] {
        displayIDs(
            for: books,
            filter: filter,
            searchText: searchText,
            sort: sort,
            savedSearch: savedSearch,
            smartShelf: smartShelf,
            deviceFileNames: deviceFileNames,
            deviceIsConnected: deviceIsConnected,
            kindlePresenceFilter: kindlePresenceFilter,
            now: now
        )
    }

    nonisolated static func displayMatches(
        _ book: LibraryBookRecord,
        query: LibraryQuerySpec,
        now: Date = .now
    ) -> Bool {
        let belongs: Bool
        if let compiledSmartShelf = query.smartShelf?.compiled {
            belongs = compiledSmartShelf.matches(
                book,
                deviceFileNames: query.deviceFileNames,
                deviceIsConnected: query.deviceIsConnected
            )
        } else if let savedSearch = query.savedSearch {
            belongs = book.normalized.matches(
                NormalizedQuery(SearchQuery.parse(savedSearch))
            )
        } else {
            belongs = matches(
                book,
                filter: query.filter,
                recentCutoff: now.addingTimeInterval(-14 * 24 * 3600)
            )
        }
        return belongs
            && book.normalized.matches(NormalizedQuery(SearchQuery.parse(query.searchText)))
            && query.kindlePresenceFilter.includes(
                deviceMatchKeys: book.deviceMatchKeys,
                deviceFileNames: query.deviceFileNames,
                deviceIsConnected: query.deviceIsConnected
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
        query: LibraryQuerySpec
    ) -> Bool {
        if case .series = query.filter {
            if lhs.seriesIndex == rhs.seriesIndex {
                return lhs.sourceOrdinal < rhs.sourceOrdinal
            }
            return lhs.seriesIndex < rhs.seriesIndex
        }
        if query.sort.field == .source {
            return lhs.sourceOrdinal < rhs.sourceOrdinal
        }
        return ordered(lhs, before: rhs, by: query.sort)
    }

    private nonisolated static func matches(
        _ book: LibraryBookRecord,
        filter: LibraryFilter,
        recentCutoff: Date
    ) -> Bool {
        switch filter {
        case .all:
            true
        case .recentlyAdded:
            book.dateAdded > recentCutoff
        case .status(let status):
            book.readingStatus == status
        case .collection(let id):
            book.collectionIDs.contains(id)
        case .format(let format):
            book.format == format
        case .author(let author):
            book.displayAuthor == author
        case .series(let series):
            book.series == series
        case .tag(let tag):
            book.tags.contains(tag)
        case .rated:
            book.rating > 0
        }
    }

    private nonisolated static func ordered(
        _ lhs: LibraryBookRecord,
        before rhs: LibraryBookRecord,
        by sort: LibraryDisplaySort
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
            return lhs.sourceOrdinal < rhs.sourceOrdinal
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
        let languages: [String]
        let translators: [String]
        let year: SearchQuery.YearConstraint?

        init(_ query: SearchQuery) {
            freeText = LibraryNormalizedStrings.normalize(query.freeText)
            authors = query.authors.map(LibraryNormalizedStrings.normalize)
            tags = query.tags.map(LibraryNormalizedStrings.normalize)
            series = query.series.map(LibraryNormalizedStrings.normalize)
            titles = query.titles.map(LibraryNormalizedStrings.normalize)
            formats = query.formats.map(LibraryNormalizedStrings.normalize)
            languages = query.languages.map(LibraryNormalizedStrings.normalize)
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
