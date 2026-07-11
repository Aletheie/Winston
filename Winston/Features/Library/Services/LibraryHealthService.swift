import Foundation
import SwiftData

nonisolated enum DuplicateRecommendationReason: Hashable, Sendable {
    case preferredKindleFormat(String)
    case richestMetadata
    case largestFile
    case drmFree
    case availableFile
    case bestOverall

    var label: LocalizedStringResource {
        switch self {
        case .preferredKindleFormat(let format): "Kindle-friendly \(format)"
        case .richestMetadata:                    "Richest metadata"
        case .largestFile:                        "Largest file"
        case .drmFree:                            "No DRM"
        case .availableFile:                      "File available"
        case .bestOverall:                        "Best overall copy"
        }
    }
}

nonisolated struct DuplicateRecommendation: Equatable, Sendable {
    let bookUUID: UUID
    let reasons: [DuplicateRecommendationReason]
}

struct DuplicateGroup: Identifiable {
    let books: [Book]
    let recommendation: DuplicateRecommendation

    var id: UUID { recommendation.bookUUID }
}

@MainActor
@Observable
final class LibraryHealthService {
    private let modelContext: ModelContext
    private(set) var missingFileUUIDs: Set<UUID> = []

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func isMissing(_ book: Book) -> Bool { missingFileUUIDs.contains(book.uuid) }

    @discardableResult
    func scanForMissingFiles() async -> Int {
        let entries: [(uuid: UUID, fileName: String)] = modelContext.allBooks().map { ($0.uuid, $0.fileName) }
        let missing = await Task.detached(priority: .utility) {
            var found: Set<UUID> = []
            for entry in entries {
                let path = BookFileStore.url(for: entry.fileName).path(percentEncoded: false)
                if !FileManager.default.fileExists(atPath: path) { found.insert(entry.uuid) }
            }
            return found
        }.value
        missingFileUUIDs = missing
        return missing.count
    }

    func relink(_ book: Book, from url: URL) {
        guard let fileName = try? BookFileStore.importCopy(of: url, uuid: book.uuid) else { return }
        if fileName != book.fileName {
            BookFileStore.delete(fileName: book.fileName)
            book.fileName = fileName
        }
        book.fileSizeBytes = BookFileStore.size(of: fileName)
        book.coverVersion += 1
        missingFileUUIDs.remove(book.uuid)
        modelContext.saveQuietly()
    }

    // MARK: - Duplicate detection

    nonisolated struct DuplicateQualityCandidate: Sendable {
        let uuid: UUID
        let format: String
        let fileSizeBytes: Int64
        let metadataRichness: Int
        let drmProtected: Bool
        let isMissing: Bool
        let dateAdded: Date
    }

    nonisolated private struct DupeCandidate: Sendable {
        let uuid: UUID
        let storedTitle: String?
        let originalFileName: String
        let author: String?
        let fileSizeBytes: Int64
        let quality: DuplicateQualityCandidate
    }

    nonisolated private struct RankedGroup: Sendable {
        let displayTitle: String
        let orderedUUIDs: [UUID]
        let recommendation: DuplicateRecommendation
    }

    func duplicateGroups() async -> [DuplicateGroup] {
        let books = modelContext.allBooks()
        let candidates = books.map {
            let quality = DuplicateQualityCandidate(
                uuid: $0.uuid,
                format: $0.format.lowercased(),
                fileSizeBytes: $0.fileSizeBytes,
                metadataRichness: Self.metadataRichness(of: $0),
                drmProtected: $0.drmProtected == true,
                isMissing: missingFileUUIDs.contains($0.uuid),
                dateAdded: $0.dateAdded
            )
            return DupeCandidate(
                uuid: $0.uuid,
                storedTitle: $0.title,
                originalFileName: $0.originalFileName,
                author: $0.displayAuthor,
                fileSizeBytes: $0.fileSizeBytes,
                quality: quality
            )
        }
        let rankedGroups = await Self.groupedDuplicates(candidates)
        let currentBooks = modelContext.allBooks()
        let byUUID = Dictionary(currentBooks.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        return rankedGroups.compactMap { ranked in
            let liveBooks = ranked.orderedUUIDs.compactMap { byUUID[$0] }
            guard liveBooks.count > 1,
                  byUUID[ranked.recommendation.bookUUID] != nil else { return nil }
            return DuplicateGroup(books: liveBooks, recommendation: ranked.recommendation)
        }
    }

    // Off-main — operates on snapshot rows, never on @Model objects.
    @concurrent
    private static func groupedDuplicates(_ candidates: [DupeCandidate]) async -> [RankedGroup] {
        struct Keyed {
            let uuid: UUID
            let displayTitle: String
            let quality: DuplicateQualityCandidate
        }
        var groups: [String: [Keyed]] = [:]
        for candidate in candidates {
            let displayTitle = Book.displayTitle(storedTitle: candidate.storedTitle,
                                                 originalFileName: candidate.originalFileName)
            let key = duplicateKey(title: displayTitle, author: candidate.author,
                                   fileSizeBytes: candidate.fileSizeBytes)
            groups[key, default: []].append(
                Keyed(uuid: candidate.uuid, displayTitle: displayTitle, quality: candidate.quality)
            )
        }
        return groups.values
            .filter { $0.count > 1 }
            .compactMap { group -> RankedGroup? in
                guard let recommendation = recommend(group.map(\.quality)) else { return nil }
                let qualities = group.map(\.quality)
                let ordered = group.sorted { lhs, rhs in
                    if lhs.uuid == rhs.uuid { return false }
                    if lhs.uuid == recommendation.bookUUID { return true }
                    if rhs.uuid == recommendation.bookUUID { return false }
                    return isBetter(lhs.quality, than: rhs.quality, in: qualities)
                }
                return RankedGroup(
                    displayTitle: ordered.first?.displayTitle ?? "",
                    orderedUUIDs: ordered.map(\.uuid),
                    recommendation: recommendation
                )
            }
            .sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
    }

    nonisolated static func recommend(
        _ candidates: [DuplicateQualityCandidate]
    ) -> DuplicateRecommendation? {
        guard let winner = candidates.sorted(by: {
            isBetter($0, than: $1, in: candidates)
        }).first else { return nil }

        let bestFormat = candidates.map { kindleFormatScore($0.format) }.max() ?? 0
        let richest = candidates.map(\.metadataRichness).max() ?? 0
        let largest = candidates.map(\.fileSizeBytes).max() ?? 0
        var reasons: [DuplicateRecommendationReason] = []
        if !winner.isMissing, candidates.contains(where: { $0.isMissing }) { reasons.append(.availableFile) }
        if !winner.drmProtected, candidates.contains(where: { $0.drmProtected }) { reasons.append(.drmFree) }
        let winnerFormatScore = kindleFormatScore(winner.format)
        if winnerFormatScore > 0,
           winnerFormatScore == bestFormat,
           candidates.contains(where: { kindleFormatScore($0.format) < winnerFormatScore }) {
            reasons.append(.preferredKindleFormat(winner.format.uppercased()))
        }
        if winner.metadataRichness > 0,
           winner.metadataRichness == richest,
           candidates.contains(where: { $0.metadataRichness < winner.metadataRichness }) {
            reasons.append(.richestMetadata)
        }
        if winner.fileSizeBytes > 0,
           winner.fileSizeBytes == largest,
           candidates.contains(where: { $0.fileSizeBytes < winner.fileSizeBytes }) {
            reasons.append(.largestFile)
        }
        if reasons.isEmpty { reasons = [.bestOverall] }
        return DuplicateRecommendation(bookUUID: winner.uuid, reasons: reasons)
    }

    nonisolated private static func isBetter(
        _ lhs: DuplicateQualityCandidate,
        than rhs: DuplicateQualityCandidate,
        in group: [DuplicateQualityCandidate]
    ) -> Bool {
        let lhsScore = qualityScore(lhs, in: group)
        let rhsScore = qualityScore(rhs, in: group)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        if lhs.metadataRichness != rhs.metadataRichness { return lhs.metadataRichness > rhs.metadataRichness }
        let lhsFormat = kindleFormatScore(lhs.format)
        let rhsFormat = kindleFormatScore(rhs.format)
        if lhsFormat != rhsFormat { return lhsFormat > rhsFormat }
        if lhs.fileSizeBytes != rhs.fileSizeBytes { return lhs.fileSizeBytes > rhs.fileSizeBytes }
        if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded < rhs.dateAdded }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    nonisolated private static func qualityScore(
        _ candidate: DuplicateQualityCandidate,
        in group: [DuplicateQualityCandidate]
    ) -> Int {
        let largest = max(group.map(\.fileSizeBytes).max() ?? 0, 1)
        let sizePoints = Int((Double(max(candidate.fileSizeBytes, 0)) / Double(largest) * 6).rounded())
        var score = kindleFormatScore(candidate.format) * 4
            + candidate.metadataRichness * 2
            + sizePoints
        if candidate.drmProtected { score -= 100 }
        if candidate.isMissing { score -= 1_000 }
        return score
    }

    nonisolated static func kindleFormatScore(_ format: String) -> Int {
        let preference = ["azw3", "mobi", "azw", "epub", "pdf", "txt"]
        guard let index = preference.firstIndex(of: format.lowercased()) else { return 0 }
        return preference.count - index
    }

    private static func metadataRichness(of book: Book) -> Int {
        let values = [
            book.title, book.author, book.publisher, book.year, book.language,
            book.isbn, book.series, book.seriesIndex, book.bookDescription, book.notes
        ]
        var score = values.reduce(0) { count, value in
            count + ((value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? 1 : 0)
        }
        if !book.tags.isEmpty { score += 1 }
        if book.rating != nil { score += 1 }
        if book.communityRating != nil { score += 1 }
        return score
    }

    static func duplicateKey(_ book: Book) -> String {
        duplicateKey(title: book.displayTitle, author: book.displayAuthor, fileSizeBytes: book.fileSizeBytes)
    }

    nonisolated static func duplicateKey(title: String, author: String?, fileSizeBytes: Int64) -> String {
        let title = title.normalizedMatchKey
        let author = (author ?? "")
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .sorted()
            .joined(separator: " ")
        return author.isEmpty ? "\(title)|\(fileSizeBytes)" : "\(title)|\(author)"
    }
}
