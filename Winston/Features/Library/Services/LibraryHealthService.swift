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
    private var cachedMetadataAnalysis: MetadataFixAnalysis?
    private var cachedMetadataAnalysisRevision = -1
    private var metadataAnalysisTask: (revision: Int, task: Task<MetadataFixAnalysis, Never>)?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func isMissing(_ book: Book) -> Bool { missingFileUUIDs.contains(book.uuid) }

    func metadataFixes() async -> [MetadataFix] {
        await metadataAnalysis().fixes
    }

    func seriesSuggestions() async -> [String] {
        await metadataAnalysis().seriesSuggestions
    }

    private func metadataAnalysis() async -> MetadataFixAnalysis {
        while true {
            let revision = LibraryMutationLog.shared.revision
            if cachedMetadataAnalysisRevision == revision, let cachedMetadataAnalysis {
                return cachedMetadataAnalysis
            }

            let task: Task<MetadataFixAnalysis, Never>
            if let inFlight = metadataAnalysisTask, inFlight.revision == revision {
                task = inFlight.task
            } else {
                let rows = modelContext.allBooks().map {
                    MetadataFixRow(
                        bookID: $0.uuid,
                        title: $0.displayTitle,
                        originalFileName: $0.originalFileName,
                        author: $0.displayAuthor,
                        series: $0.series,
                        seriesIndex: $0.seriesIndex
                    )
                }
                task = Task { await Self.computeMetadataAnalysis(rows: rows) }
                metadataAnalysisTask = (revision, task)
            }

            let analysis = await task.value
            if metadataAnalysisTask?.revision == revision {
                metadataAnalysisTask = nil
            }
            guard LibraryMutationLog.shared.revision == revision else { continue }

            cachedMetadataAnalysis = analysis
            cachedMetadataAnalysisRevision = revision
            return analysis
        }
    }

    @concurrent
    private static func computeMetadataAnalysis(rows: [MetadataFixRow]) async -> MetadataFixAnalysis {
        MetadataFixFinder.analysis(rows: rows)
    }

    @discardableResult
    func scanForMissingFiles() async -> Int {
        let books = modelContext.allBooks()
        let primaryEntries = books.map { (uuid: $0.uuid, fileName: $0.fileName) }
        let assets = books.flatMap(\.assets)
        let assetEntries = assets.map { (uuid: $0.uuid, fileName: $0.fileName) }
        let result = await Task.detached(priority: .utility) {
            var missingBooks: Set<UUID> = []
            var assetStatus: [UUID: AssetValidation] = [:]
            for entry in primaryEntries {
                let path = BookFileStore.url(for: entry.fileName).path(percentEncoded: false)
                if !FileManager.default.fileExists(atPath: path) { missingBooks.insert(entry.uuid) }
            }
            for entry in assetEntries {
                let path = BookFileStore.url(for: entry.fileName).path(percentEncoded: false)
                assetStatus[entry.uuid] = FileManager.default.fileExists(atPath: path) ? .ok : .missing
            }
            return (missingBooks, assetStatus)
        }.value
        missingFileUUIDs = result.0
        var changed = false
        for asset in assets {
            guard let status = result.1[asset.uuid] else { continue }
            if status == .missing {
                if asset.validationStatus != .missing {
                    asset.validationStatus = .missing
                    changed = true
                }
            } else if asset.validationStatus == nil || asset.validationStatus == .missing {
                asset.validationStatus = .ok
                changed = true
            }
        }
        if changed { modelContext.saveQuietly() }
        return result.0.count
    }

    func relink(_ book: Book, from url: URL) async {
        guard book.modelContext != nil else { return }
        let oldFileName = book.fileName
        let asset = book.assets.first { $0.fileName == oldFileName }
            ?? book.assets.first { $0.uuid == book.uuid }
        guard let fileName = try? BookFileStore.importCopy(of: url, uuid: asset?.uuid ?? book.uuid) else { return }
        let replacementDate = Date()
        if fileName != oldFileName { BookFileStore.delete(fileName: oldFileName) }
        book.fileName = fileName
        book.fileSizeBytes = BookFileStore.size(of: fileName)
        book.drmProtected = nil
        book.coverVersion += 1
        missingFileUUIDs.remove(book.uuid)

        let updatedAsset: BookAsset
        if let asset {
            asset.fileName = fileName
            asset.sizeBytes = book.fileSizeBytes
            asset.contentHash = nil
            asset.generatedFromContentHash = nil
            asset.origin = .imported
            asset.validationStatus = .ok
            asset.dateAdded = replacementDate
            updatedAsset = asset
        } else {
            let asset = BookAsset(
                uuid: book.uuid,
                fileName: fileName,
                origin: .original,
                sizeBytes: book.fileSizeBytes,
                dateAdded: replacementDate,
                validationStatus: .ok,
                book: book
            )
            modelContext.insert(asset)
            updatedAsset = asset
        }
        modelContext.saveQuietly()

        let managedURL = BookFileStore.url(for: fileName)
        let analysis = await Task.detached(priority: .utility) {
            (
                try? ContentHasher.sha256(of: managedURL),
                DRMDetector.isProtected(url: managedURL)
            )
        }.value
        guard book.modelContext != nil,
              updatedAsset.modelContext != nil,
              updatedAsset.fileName == fileName,
              updatedAsset.dateAdded == replacementDate else { return }
        updatedAsset.contentHash = analysis.0
        if book.fileName == fileName { book.drmProtected = analysis.1 }
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
        let candidates = books.map { book in
            let retainedAssets = book.assets.filter {
                $0.validationStatus != .missing && $0.validationStatus != .corrupt
            }
            let bestRetainedFormat = retainedAssets
                .map { $0.format.lowercased() }
                .max { Self.kindleFormatScore($0) < Self.kindleFormatScore($1) }
            let retainedBytes: Int64
            if book.assets.isEmpty {
                retainedBytes = book.fileSizeBytes
            } else {
                retainedBytes = retainedAssets.reduce(0) { total, asset in
                    if asset.sizeBytes > 0 { return total + asset.sizeBytes }
                    return total + (asset.fileName == book.fileName ? book.fileSizeBytes : 0)
                }
            }
            let quality = DuplicateQualityCandidate(
                uuid: book.uuid,
                format: bestRetainedFormat ?? book.format.lowercased(),
                fileSizeBytes: retainedBytes,
                metadataRichness: Self.metadataRichness(of: book),
                drmProtected: book.drmProtected == true,
                isMissing: book.assets.isEmpty
                    ? missingFileUUIDs.contains(book.uuid)
                    : retainedAssets.isEmpty,
                dateAdded: book.dateAdded
            )
            return DupeCandidate(
                uuid: book.uuid,
                storedTitle: book.title,
                originalFileName: book.originalFileName,
                author: book.displayAuthor,
                fileSizeBytes: book.fileSizeBytes,
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
