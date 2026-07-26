import Foundation
import OSLog
import SwiftData

@MainActor
@Observable
final class LibraryHealthService {
    private let modelContext: ModelContext
    private let analysisCoordinator: CatalogAnalysisCoordinator
    private let mutations: CatalogMutationService
    private let managedFiles: ManagedFileCoordinator
    private(set) var missingFileUUIDs: Set<UUID> = []
    private var cachedMetadataAnalysis: MetadataFixAnalysis?
    private var cachedMetadataAnalysisRevision = -1
    private var metadataAnalysisTask: (revision: Int, task: Task<MetadataFixAnalysis, Never>)?

    init(
        modelContext: ModelContext,
        analysisCoordinator: CatalogAnalysisCoordinator = CatalogAnalysisCoordinator(),
        mutations: CatalogMutationService? = nil,
        managedFiles: ManagedFileCoordinator = .shared
    ) {
        self.modelContext = modelContext
        let resolvedMutations = mutations ?? CatalogMutationService(
            modelContext: modelContext,
            managedFiles: managedFiles,
            analysisCoordinator: analysisCoordinator
        )
        self.analysisCoordinator = resolvedMutations.analysisCoordinator
        self.mutations = resolvedMutations
        self.managedFiles = managedFiles
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
                let books = (try? modelContext.fetchAllBooksForGlobalAnalysis()) ?? []
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
        let books = (try? modelContext.fetchAllBooksForGlobalAnalysis()) ?? []
        let assets = (try? modelContext.fetch(FetchDescriptor<BookAsset>())) ?? []
        var primaryEntries: [(uuid: UUID, fileName: String)] = []
        primaryEntries.reserveCapacity(books.count)
        for (index, book) in books.enumerated() {
            guard !Task.isCancelled else { return 0 }
            let primaryFileName = book.primaryAsset?.fileName ?? book.fileName
            if !primaryFileName.isEmpty {
                primaryEntries.append((book.uuid, primaryFileName))
            }
            if let primaryAsset = book.primaryAsset,
               book.fileName != primaryAsset.fileName
                    || book.primaryAssetUUID != primaryAsset.uuid {
                Log.persistence.error(
                    "Primary asset invariant drift for book \(book.uuid.uuidString, privacy: .public)"
                )
            }
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
        var updates: [CatalogAssetValidationUpdate] = []
        updates.reserveCapacity(assets.count)
        for (index, asset) in assets.enumerated() {
            // The yields below let deletions interleave; a removed asset must not be written to.
            guard asset.modelContext != nil, let status = result.1[asset.uuid] else { continue }
            let updatedStatus: AssetValidation?
            if status == .missing {
                updatedStatus = asset.validationStatus == .missing ? nil : .missing
            } else if asset.validationStatus == nil || asset.validationStatus == .missing {
                updatedStatus = .ok
            } else {
                updatedStatus = nil
            }
            if let updatedStatus {
                updates.append(CatalogAssetValidationUpdate(
                    assetID: asset.uuid,
                    expectedFileName: asset.fileName,
                    expectedDateAdded: asset.dateAdded,
                    validation: updatedStatus
                ))
            }
            if index > 0, index.isMultiple(of: 256) { await Task.yield() }
        }
        if !updates.isEmpty {
            _ = mutations.execute(.updateAssetValidations(updates))
        }
        return result.0.count
    }

    func relink(_ book: Book, from url: URL) async {
        guard book.modelContext != nil else { return }
        let asset = book.primaryAsset
        let bookID = book.uuid
        let primaryAssetID = asset?.uuid
        let primaryAssetDateAdded = asset?.dateAdded
        let oldFileName = asset?.fileName ?? book.fileName
        let replacementUUID = asset?.uuid ?? bookID
        let originalCoverVersion = book.coverVersion
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let previousIdentity: ManagedFileIdentitySnapshot
        let source: ManagedFileSource
        do {
            previousIdentity = try await managedFiles.captureIdentity(
                of: .book(oldFileName)
            )
            source = try .book(
                sourceURL: url,
                destination: .replacement(
                    assetID: replacementUUID,
                    previous: previousIdentity
                )
            )
        } catch {
            return
        }
        let fileName = source.finalRelativeName
        let transaction: ManagedFileTransaction
        do {
            transaction = try await managedFiles.stage(
                intent: .replaceBookFile,
                sources: [source],
                requirement: ManagedFileRequirement(
                    presentBookIDs: [bookID],
                    referencedBookFileNames: [fileName],
                    unreferencedBookFileNames: [oldFileName],
                    coverVersions: [bookID: originalCoverVersion + 1]
                ),
                cleanups: [.file(previousIdentity)]
            )
        } catch {
            return
        }
        guard let staged = transaction.files.first else {
            await managedFiles.abort(transaction)
            return
        }
        let primaryIsCurrent = if let primaryAssetID {
            book.primaryAsset?.uuid == primaryAssetID
                && book.primaryAsset?.fileName == oldFileName
                && book.primaryAsset?.dateAdded == primaryAssetDateAdded
        } else {
            book.assets.isEmpty && book.fileName == oldFileName
        }
        guard book.modelContext != nil,
              book.coverVersion == originalCoverVersion,
              primaryIsCurrent else {
            await managedFiles.abort(transaction)
            return
        }
        let drmProtected = await Task.detached(priority: .utility) {
            DRMDetector.isProtected(url: staged.stagedURL)
        }.value
        let replacementDate = Date()
        let updatedAssetID = primaryAssetID ?? bookID
        let bookPreimage = CatalogBookMetadataPreimage(book)
        let assetPreimage = asset.map(CatalogBookAssetPreimage.init)
        var insertedAsset: BookAsset?
        do {
            _ = try await mutations.commitFileMutation(
                primaryAssetID == nil
                    ? .addFile(bookID: bookID, assetID: updatedAssetID)
                    : .replaceFile(bookID: bookID, assetID: updatedAssetID),
                transaction: transaction,
                affectedBookIDs: [bookID],
                revertingOnFailure: {
                    bookPreimage.restore()
                    assetPreimage?.restore()
                    if let insertedAsset, insertedAsset.modelContext != nil {
                        self.modelContext.delete(insertedAsset)
                    }
                }
            ) {
                let storedBook = try self.mutations.book(id: bookID)
                let sourceIsCurrent = if let primaryAssetID {
                    storedBook.primaryAsset?.uuid == primaryAssetID
                        && storedBook.primaryAsset?.fileName == oldFileName
                        && storedBook.primaryAsset?.dateAdded == primaryAssetDateAdded
                } else {
                    storedBook.assets.isEmpty && storedBook.fileName == oldFileName
                }
                guard sourceIsCurrent,
                      storedBook.coverVersion == originalCoverVersion else {
                    throw CatalogMutationError.staleGeneration
                }

                storedBook.fileName = fileName
                storedBook.fileSizeBytes = staged.byteCount
                storedBook.drmProtected = drmProtected
                storedBook.coverVersion = originalCoverVersion + 1

                let updatedAsset: BookAsset
                if let primaryAssetID,
                   let storedAsset = storedBook.assets.first(where: { $0.uuid == primaryAssetID }) {
                    storedAsset.fileName = fileName
                    storedAsset.sizeBytes = staged.byteCount
                    storedAsset.contentHash = staged.sha256
                    storedAsset.generatedFromContentHash = nil
                    storedAsset.origin = .imported
                    storedAsset.validationStatus = .ok
                    storedAsset.dateAdded = replacementDate
                    updatedAsset = storedAsset
                } else {
                    let storedAsset = BookAsset(
                        uuid: updatedAssetID,
                        fileName: fileName,
                        origin: .original,
                        contentHash: staged.sha256,
                        sizeBytes: staged.byteCount,
                        dateAdded: replacementDate,
                        validationStatus: .ok,
                        book: storedBook
                    )
                    self.modelContext.insert(storedAsset)
                    insertedAsset = storedAsset
                    updatedAsset = storedAsset
                }
                storedBook.primaryAssetUUID = updatedAsset.uuid
            }
        } catch {
            return
        }
        analysisCoordinator.cancelAll(for: bookID)
        missingFileUUIDs.remove(bookID)
    }

}
