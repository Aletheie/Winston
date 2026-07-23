import Foundation
import SwiftData

@MainActor
@Observable
final class LibraryHealthService {
    private let modelContext: ModelContext
    private let analysisCoordinator: CatalogAnalysisCoordinator
    private(set) var missingFileUUIDs: Set<UUID> = []
    private var cachedMetadataAnalysis: MetadataFixAnalysis?
    private var cachedMetadataAnalysisRevision = -1
    private var metadataAnalysisTask: (revision: Int, task: Task<MetadataFixAnalysis, Never>)?

    init(
        modelContext: ModelContext,
        analysisCoordinator: CatalogAnalysisCoordinator = CatalogAnalysisCoordinator()
    ) {
        self.modelContext = modelContext
        self.analysisCoordinator = analysisCoordinator
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
            let revision = LibraryMutationLog.shared.catalogRevision
            if cachedMetadataAnalysisRevision == revision, let cachedMetadataAnalysis {
                return cachedMetadataAnalysis
            }

            let task: Task<MetadataFixAnalysis, Never>
            if let inFlight = metadataAnalysisTask, inFlight.revision == revision {
                task = inFlight.task
            } else {
                let books = modelContext.allBooks()
                var rows: [MetadataFixRow] = []
                rows.reserveCapacity(books.count)
                for (index, book) in books.enumerated() {
                    guard !Task.isCancelled else { return MetadataFixAnalysis(fixes: [], seriesSuggestions: []) }
                    rows.append(MetadataFixRow(
                        bookID: book.uuid,
                        title: book.displayTitle,
                        originalFileName: book.originalFileName,
                        author: book.displayAuthor,
                        series: book.series,
                        seriesIndex: book.seriesIndex
                    ))
                    if index > 0, index.isMultiple(of: 128) { await Task.yield() }
                }
                let snapshotRows = rows
                task = Task { await Self.computeMetadataAnalysis(rows: snapshotRows) }
                metadataAnalysisTask = (revision, task)
            }

            let analysis = await task.value
            if metadataAnalysisTask?.revision == revision {
                metadataAnalysisTask = nil
            }
            guard LibraryMutationLog.shared.catalogRevision == revision else { continue }

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
        let assets = (try? modelContext.fetch(FetchDescriptor<BookAsset>())) ?? []
        var primaryEntries: [(uuid: UUID, fileName: String)] = []
        primaryEntries.reserveCapacity(books.count)
        for (index, book) in books.enumerated() {
            guard !Task.isCancelled else { return 0 }
            if book.hasDigitalFile { primaryEntries.append((book.uuid, book.fileName)) }
            if index > 0, index.isMultiple(of: 256) { await Task.yield() }
        }
        var assetEntries: [(uuid: UUID, fileName: String)] = []
        assetEntries.reserveCapacity(assets.count)
        for (index, asset) in assets.enumerated() {
            guard !Task.isCancelled else { return 0 }
            assetEntries.append((asset.uuid, asset.fileName))
            if index > 0, index.isMultiple(of: 256) { await Task.yield() }
        }
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
        var changedBookIDs: Set<UUID> = []
        for (index, asset) in assets.enumerated() {
            // The yields below let deletions interleave; a removed asset must not be written to.
            guard asset.modelContext != nil, let status = result.1[asset.uuid] else { continue }
            if status == .missing {
                if asset.validationStatus != .missing {
                    asset.validationStatus = .missing
                    if let bookID = asset.book?.uuid { changedBookIDs.insert(bookID) }
                }
            } else if asset.validationStatus == nil || asset.validationStatus == .missing {
                asset.validationStatus = .ok
                if let bookID = asset.book?.uuid { changedBookIDs.insert(bookID) }
            }
            if index > 0, index.isMultiple(of: 256) { await Task.yield() }
        }
        if !changedBookIDs.isEmpty {
            modelContext.saveQuietly(
                affectedBookIDs: changedBookIDs,
                fullTextAffectedBookIDs: changedBookIDs
            )
        }
        return result.0.count
    }

    func relink(_ book: Book, from url: URL) async {
        guard book.modelContext != nil else { return }
        let oldFileName = book.fileName
        let asset = book.assets.first { $0.fileName == oldFileName }
            ?? book.assets.first { $0.uuid == book.uuid }
        let replacementUUID = asset?.uuid ?? book.uuid
        let replacement: (fileName: String, size: Int64)? = await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let fileName = try? BookFileStore.replacementCopy(
                of: url,
                replacing: oldFileName,
                uuid: replacementUUID
            ) else { return nil }
            return (fileName, BookFileStore.size(of: fileName))
        }.value
        guard let replacement else { return }
        let fileName = replacement.fileName
        guard book.modelContext != nil, book.fileName == oldFileName else {
            Task.detached(priority: .utility) {
                BookFileStore.delete(fileName: fileName)
            }
            return
        }
        let replacementDate = Date()
        book.fileName = fileName
        book.fileSizeBytes = replacement.size
        book.drmProtected = nil
        book.coverVersion += 1

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
        guard modelContext.saveQuietly(
            rollbackOnFailure: true,
            affectedBookIDs: [book.uuid],
            fullTextAffectedBookIDs: [book.uuid]
        ) else {
            Task.detached(priority: .utility) {
                BookFileStore.delete(fileName: fileName)
            }
            return
        }
        analysisCoordinator.cancelAll(for: book.uuid)
        missingFileUUIDs.remove(book.uuid)
        if fileName != oldFileName, BookFileStore.validatedURL(for: oldFileName) != nil {
            Task.detached(priority: .utility) {
                BookFileStore.delete(fileName: oldFileName)
            }
        }

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
        modelContext.saveQuietly(
            affectedBookIDs: [book.uuid],
            fullTextAffectedBookIDs: [book.uuid]
        )
    }

}
