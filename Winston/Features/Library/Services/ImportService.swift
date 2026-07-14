import Foundation
import SwiftData

struct ImportBookAnalysis: Sendable {
    let metadata: BookMetadata
    let drmProtected: Bool
}

@MainActor
@Observable
final class ImportService {
    nonisolated private struct CopyRequest: Sendable {
        let source: URL
        let uuid: UUID
        let originalName: String
    }

    nonisolated private enum CopyResult: Sendable {
        case copied(uuid: UUID, originalName: String, fileName: String, size: Int64, contentHash: String?)
        case failed(originalName: String)
    }

    private let modelContext: ModelContext
    private let settings: AppSettings
    private let metadata: MetadataService
    private let wishlist: WishlistService
    private let toasts: ToastCenter
    private let editions: EditionService?
    private let analyzeBook: @Sendable (URL) async -> ImportBookAnalysis

    private(set) var pendingMetadataUUIDs: Set<UUID> = []
    private var pendingOriginalFileNames: Set<String> = []

    init(
        modelContext: ModelContext,
        settings: AppSettings,
        metadata: MetadataService,
        wishlist: WishlistService,
        toasts: ToastCenter,
        editions: EditionService? = nil,
        analyzeBook: @escaping @Sendable (URL) async -> ImportBookAnalysis = ImportService.defaultAnalysis
    ) {
        self.modelContext = modelContext
        self.settings = settings
        self.metadata = metadata
        self.wishlist = wishlist
        self.toasts = toasts
        self.editions = editions
        self.analyzeBook = analyzeBook
    }

    var isExtracting: Bool { !pendingMetadataUUIDs.isEmpty }
    var pendingMetadataCount: Int { pendingMetadataUUIDs.count }

    func addBooks(from urls: [URL]) {
        addBooks(from: urls, assigningTo: nil)
    }

    func addBooks(from urls: [URL], assigningTo targetWork: Work?) {
        var requests: [CopyRequest] = []
        var failed = 0
        for url in urls {
            guard libraryEbookExtensions.contains(url.pathExtension.lowercased()) else { failed += 1; continue }

            let originalName = url.lastPathComponent
            if targetWork == nil {
                guard !pendingOriginalFileNames.contains(originalName),
                      !isDuplicate(originalFileName: originalName) else { continue }
                pendingOriginalFileNames.insert(originalName)
            }
            requests.append(CopyRequest(source: url, uuid: UUID(), originalName: originalName))
        }

        guard !requests.isEmpty else {
            reportImportFailures(failed)
            return
        }

        let validationFailures = failed
        Task { [weak self, requests] in
            guard let self else { return }
            let results = await Task.detached(priority: .userInitiated) {
                requests.map(Self.copyToManagedStore)
            }.value
            if let targetWork, targetWork.modelContext == nil {
                for result in results {
                    if case .copied(_, _, let fileName, _, _) = result {
                        BookFileStore.delete(fileName: fileName)
                    }
                }
                return
            }

            var imported: [Book] = []
            var failureCount = validationFailures
            var knownHashes = Set(
                ((try? modelContext.fetch(FetchDescriptor<BookAsset>())) ?? [])
                    .compactMap(\.contentHash)
            )
            for result in results {
                switch result {
                case .copied(let uuid, let originalName, let fileName, let size, let contentHash):
                    if targetWork == nil { pendingOriginalFileNames.remove(originalName) }
                    if targetWork != nil,
                       let contentHash,
                       knownHashes.contains(contentHash) {
                        BookFileStore.delete(fileName: fileName)
                        continue
                    }
                    let book = Book(uuid: uuid, fileName: fileName, originalFileName: originalName)
                    book.fileSizeBytes = size
                    let work = targetWork ?? Work(dateCreated: book.dateAdded)
                    let asset = BookAsset(
                        uuid: uuid,
                        fileName: fileName,
                        origin: .original,
                        contentHash: contentHash,
                        sizeBytes: size,
                        dateAdded: book.dateAdded,
                        validationStatus: .ok,
                        book: book
                    )
                    if targetWork == nil { modelContext.insert(work) }
                    modelContext.insert(book)
                    modelContext.insert(asset)
                    book.work = work
                    if work.preferredEditionUUID == nil { work.preferredEditionUUID = book.uuid }
                    imported.append(book)
                    if let contentHash { knownHashes.insert(contentHash) }
                case .failed(let originalName):
                    if targetWork == nil { pendingOriginalFileNames.remove(originalName) }
                    failureCount += 1
                }
            }

            if !imported.isEmpty {
                modelContext.saveQuietly()
                if targetWork != nil { editions?.refreshEditionCounts() }
                for book in imported { extractMetadata(for: book, evaluateMatch: targetWork == nil) }
            }
            reportImportFailures(failureCount)
        }
    }

    func cancelPending(_ uuid: UUID) { pendingMetadataUUIDs.remove(uuid) }

    // MARK: - Maintenance

    func backfillMissingSizes() {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.fileSizeBytes == 0 })
        guard let books = try? modelContext.fetch(descriptor), !books.isEmpty else { return }
        let candidates = books.map { (book: $0, fileName: $0.fileName) }
        Task {
            for candidate in candidates {
                let fileName = candidate.fileName
                let size = await Task.detached(priority: .utility) {
                    BookFileStore.size(of: fileName)
                }.value
                guard candidate.book.modelContext != nil else { continue }
                if size > 0 {
                    candidate.book.fileSizeBytes = size
                    candidate.book.assets.first(where: { $0.fileName == candidate.book.fileName })?.sizeBytes = size
                }
            }
            modelContext.saveQuietly()
        }
    }

    func detectMissingDRM() {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.drmProtected == nil })
        guard let books = try? modelContext.fetch(descriptor), !books.isEmpty else { return }
        let candidates = books.map { (book: $0, url: $0.fileURL) }
        Task {
            var processed = 0
            for candidate in candidates {
                let url = candidate.url
                let drmProtected = await Task.detached(priority: .utility) {
                    DRMDetector.isProtected(url: url)
                }.value
                guard candidate.book.modelContext != nil else { continue }
                candidate.book.drmProtected = drmProtected
                processed += 1
                if processed % 50 == 0 { modelContext.saveQuietly() }
            }
            modelContext.saveQuietly()
        }
    }

    func rescanMissingMetadata() {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.title == nil })
        guard let books = try? modelContext.fetch(descriptor), !books.isEmpty else { return }
        for book in books {
            extractMetadata(for: book)
        }
    }

    // MARK: - Background extraction

    private func extractMetadata(for book: Book, evaluateMatch: Bool = true) {
        let url = book.fileURL
        let uuid = book.uuid
        pendingMetadataUUIDs.insert(uuid)
        Task {
            defer { pendingMetadataUUIDs.remove(uuid) }
            let result = await analyzeBook(url)
            guard book.modelContext != nil else { return }
            book.apply(result.metadata)
            book.drmProtected = result.drmProtected
            refreshWorkIdentity(for: book, allowDisplayTitleFallback: !settings.onlineMetadataEnabled)
            modelContext.saveQuietly()
            wishlist.fulfil(with: [book])
            if settings.onlineMetadataEnabled {
                await metadata.performEnrich(book, replaceCover: false)
                guard book.modelContext != nil else { return }
                refreshWorkIdentity(for: book, allowDisplayTitleFallback: true)
                modelContext.saveQuietly()
                wishlist.fulfil(with: [book])
            }
            if evaluateMatch, let editions {
                if let undo = editions.evaluate(book) {
                    let title = book.work?.displayTitle ?? book.displayTitle
                    toasts.post(
                        String(localized: "Grouped with “\(title)”"),
                        style: .success,
                        action: .undoEditionAssignment(undo)
                    )
                } else if editions.pendingProposals.contains(where: { $0.memberUUIDs.contains(book.uuid) }) {
                    toasts.post(
                        String(localized: "Edition suggestions are ready to review."),
                        style: .info,
                        action: .reviewEditionProposals
                    )
                }
            }
        }
    }

    nonisolated static func defaultAnalysis(for url: URL) async -> ImportBookAnalysis {
        await Task.detached(priority: .userInitiated) {
            ImportBookAnalysis(
                metadata: MetadataExtractor.extractMetadata(from: url),
                drmProtected: DRMDetector.isProtected(url: url)
            )
        }.value
    }

    private func isDuplicate(originalFileName: String) -> Bool {
        let predicate = #Predicate<Book> { $0.originalFileName == originalFileName }
        let count = (try? modelContext.fetchCount(FetchDescriptor(predicate: predicate))) ?? 0
        return count > 0
    }

    private func refreshWorkIdentity(for book: Book, allowDisplayTitleFallback: Bool) {
        guard let work = book.work else { return }
        if work.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            if let title = book.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                work.title = title
            } else if allowDisplayTitleFallback {
                work.title = book.displayTitle
            }
        }
        if work.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            work.author = book.displayAuthor
        }
        work.refreshMatchKey()
    }

    private nonisolated static func copyToManagedStore(_ request: CopyRequest) -> CopyResult {
        let accessing = request.source.startAccessingSecurityScopedResource()
        defer { if accessing { request.source.stopAccessingSecurityScopedResource() } }
        do {
            let fileName = try BookFileStore.importCopy(of: request.source, uuid: request.uuid)
            return .copied(
                uuid: request.uuid,
                originalName: request.originalName,
                fileName: fileName,
                size: BookFileStore.size(of: fileName),
                contentHash: try? ContentHasher.sha256(of: BookFileStore.url(for: fileName))
            )
        } catch {
            return .failed(originalName: request.originalName)
        }
    }

    private func reportImportFailures(_ count: Int) {
        if count > 0 {
            toasts.error(String(localized: "Some files couldn\u{2019}t be imported (\(count))."))
        }
    }
}
