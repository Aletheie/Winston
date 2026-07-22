import Foundation
import SwiftData
import AppKit

@MainActor
@Observable
final class ConversionService {
    private struct Request {
        let book: Book
        let uuid: UUID
        let sourceURL: URL
        let sourceFileName: String
        let sourceAssetUUID: UUID?
        let sourceAssetDateAdded: Date?
        let sourceContentHash: String?
        let coverVersion: Int
        let assetUUID: UUID
        let existingAssetUUID: UUID?
        let title: String
        let format: EbookConverter.OutputFormat
    }

    private let modelContext: ModelContext
    private let toasts: ToastCenter
    private let mutations: CatalogMutationService
    private let managedFiles: ManagedFileCoordinator

    private(set) var convertingUUIDs: Set<UUID> = []

    init(
        modelContext: ModelContext,
        toasts: ToastCenter,
        mutations: CatalogMutationService? = nil,
        managedFiles: ManagedFileCoordinator = .shared
    ) {
        self.modelContext = modelContext
        self.toasts = toasts
        self.mutations = mutations ?? CatalogMutationService(
            modelContext: modelContext,
            managedFiles: managedFiles
        )
        self.managedFiles = managedFiles
    }

    func isConverting(_ book: Book) -> Bool { convertingUUIDs.contains(book.uuid) }

    func convert(_ book: Book) {
        guard book.hasDigitalFile, EbookConverter.needsConversion(format: book.format) else { return }
        convert(book, to: EbookConverter.kindleTarget(forFormat: book.format))
    }

    func convert(_ book: Book, to format: EbookConverter.OutputFormat) {
        guard book.hasDigitalFile, book.format.lowercased() != format.ext,
              !convertingUUIDs.contains(book.uuid) else { return }
        if book.drmProtected == true {
            toasts.error(String(localized: "\u{201C}\(book.displayTitle)\u{201D} is DRM\u{2011}protected and can't be converted."))
            return
        }
        guard EbookConverter.canConvert(from: book.format, to: format) else {
            toasts.error(String(localized: "Install calibre to convert books"))
            return
        }
        let request = makeRequest(for: book, to: format)
        convertingUUIDs.insert(request.uuid)
        Task { await performConvert(request) }
    }

    func convertBooks(_ books: [Book]) {
        let candidates = books.filter {
            $0.hasDigitalFile && EbookConverter.needsConversion(format: $0.format)
                && !convertingUUIDs.contains($0.uuid)
        }
        let drmCount = candidates.filter { $0.drmProtected == true }.count
        if drmCount > 0 {
            toasts.error(String(localized: "Some DRM\u{2011}protected books were skipped (\(drmCount))."))
        }
        let targets = candidates.filter {
            $0.drmProtected != true && EbookConverter.canConvertForKindle($0.format)
        }
        guard !targets.isEmpty else {
            if candidates.contains(where: { $0.drmProtected != true }) {
                toasts.error(String(localized: "Install calibre to convert books"))
            }
            return
        }
        let requests = targets.map {
            makeRequest(for: $0, to: EbookConverter.kindleTarget(forFormat: $0.format))
        }
        for request in requests { convertingUUIDs.insert(request.uuid) }
        Task {
            for request in requests { await performConvert(request) }
        }
    }

    func convertBooks(_ books: [Book], to format: EbookConverter.OutputFormat) {
        let convertible = books.filter {
            $0.hasDigitalFile && $0.format.lowercased() != format.ext
                && !convertingUUIDs.contains($0.uuid)
        }
        let drmCount = convertible.filter { $0.drmProtected == true }.count
        if drmCount > 0 {
            toasts.error(String(localized: "Some DRM\u{2011}protected books were skipped (\(drmCount))."))
        }
        let targets = convertible.filter { $0.drmProtected != true }
        guard !targets.isEmpty else { return }
        let needsCalibre = targets.contains { !EbookConverter.canConvertNatively(from: $0.format, to: format) }
        if needsCalibre, !EbookConverter.isCalibreAvailable {
            toasts.error(String(localized: "Install calibre to convert books"))
            return
        }
        let requests = targets.map { makeRequest(for: $0, to: format) }
        for request in requests { convertingUUIDs.insert(request.uuid) }
        Task {
            for request in requests { await performConvert(request) }
        }
    }

    private func makeRequest(for book: Book, to format: EbookConverter.OutputFormat) -> Request {
        let sourceAsset = book.assets.first { $0.fileName == book.fileName }
        let existing = book.assets.first {
            $0.origin == .generated && $0.format.lowercased() == format.ext
        }
        return Request(
            book: book,
            uuid: book.uuid,
            sourceURL: book.fileURL,
            sourceFileName: book.fileName,
            sourceAssetUUID: sourceAsset?.uuid,
            sourceAssetDateAdded: sourceAsset?.dateAdded,
            sourceContentHash: sourceAsset?.contentHash,
            coverVersion: book.coverVersion,
            assetUUID: existing?.uuid ?? UUID(),
            existingAssetUUID: existing?.uuid,
            title: book.displayTitle,
            format: format
        )
    }

    private func performConvert(_ request: Request) async {
        let book = request.book
        let uuid = request.uuid
        let sourceURL = request.sourceURL
        defer { convertingUUIDs.remove(uuid) }
        guard sourceSnapshotIsCurrent(request) else { return }

        let resolvedSourceHash: String?
        if let sourceContentHash = request.sourceContentHash {
            resolvedSourceHash = sourceContentHash
        } else {
            resolvedSourceHash = await Task.detached(priority: .utility) {
                try? ContentHasher.sha256(of: sourceURL)
            }.value
        }
        guard let sourceHash = resolvedSourceHash else {
            toasts.error(String(localized: "Couldn’t convert “\(request.title)”."))
            return
        }
        guard sourceSnapshotIsCurrent(request) else { return }

        let extractedCover = await Task.detached(priority: .utility) { () -> (NSImage, Data)? in
            if !CoverStore.exists(for: uuid),
               let cover = CoverExtractor.extractCover(from: sourceURL),
               let data = ImageTranscoder.jpegData(from: cover) {
                return (cover, data)
            }
            return nil
        }.value

        guard sourceSnapshotIsCurrent(request) else { return }
        let converted: URL? = try? await EbookConverter.convert(sourceURL, to: request.format)
        guard sourceSnapshotIsCurrent(request) else {
            if let converted { try? FileManager.default.removeItem(at: converted) }
            return
        }
        guard let converted else {
            toasts.error(String(localized: "Couldn\u{2019}t convert \u{201C}\(request.title)\u{201D}."))
            return
        }
        defer { try? FileManager.default.removeItem(at: converted) }

        let existingAsset = request.existingAssetUUID.flatMap { existingUUID in
            book.assets.first { $0.uuid == existingUUID }
        }
        let oldFileName = existingAsset?.fileName
        let oldAssetDate = existingAsset?.dateAdded
        let retiredNames = Set(oldFileName.map { [$0] } ?? [])
        let bookSource: ManagedFileSource
        do {
            bookSource = try .book(sourceURL: converted)
        } catch {
            toasts.error(String(localized: "Couldn\u{2019}t convert \u{201C}\(request.title)\u{201D}."))
            return
        }

        let shouldInstallCover = extractedCover != nil
            && book.coverVersion == request.coverVersion
            && !CoverStore.exists(for: uuid)
        var sources = [bookSource]
        if shouldInstallCover, let coverData = extractedCover?.1 {
            sources.append(.cover(data: coverData, bookID: uuid))
        }
        let newFileName = bookSource.finalRelativeName
        let expectedCoverVersion = request.coverVersion + (shouldInstallCover ? 1 : 0)
        let transaction: ManagedFileTransaction
        do {
            transaction = try await managedFiles.stage(
                intent: .conversionOutput,
                sources: sources,
                requirement: ManagedFileRequirement(
                    presentBookIDs: [uuid],
                    referencedBookFileNames: [newFileName],
                    unreferencedBookFileNames: retiredNames,
                    coverVersions: shouldInstallCover ? [uuid: expectedCoverVersion] : [:]
                ),
                cleanups: oldFileName.map { [.book($0)] } ?? []
            )
        } catch {
            toasts.error(String(localized: "Couldn\u{2019}t save \u{201C}\(request.title)\u{201D}."))
            return
        }

        let currentExisting = request.existingAssetUUID.flatMap { existingUUID in
            book.assets.first { $0.uuid == existingUUID }
        }
        guard sourceSnapshotIsCurrent(request),
              currentExisting?.fileName == oldFileName,
              currentExisting?.dateAdded == oldAssetDate,
              let stagedBook = transaction.files.first(where: { $0.kind == .book }) else {
            await managedFiles.abort(transaction)
            return
        }

        let sourceAsset = request.sourceAssetUUID.flatMap { sourceAssetUUID in
            book.assets.first { $0.uuid == sourceAssetUUID }
        }
        let originalSourceHash = sourceAsset?.contentHash
        let oldSize = currentExisting?.sizeBytes
        let oldHash = currentExisting?.contentHash
        let oldGeneratedFromHash = currentExisting?.generatedFromContentHash
        let oldValidation = currentExisting?.validationStatus
        let replacementDate = Date()
        var insertedAsset: BookAsset?
        do {
            let result = try await mutations.commitFileMutation(
                .conversionOutput(bookID: uuid, assetID: request.assetUUID),
                transaction: transaction,
                affectedBookIDs: [uuid],
                revertingOnFailure: {
                    book.coverVersion = request.coverVersion
                    sourceAsset?.contentHash = originalSourceHash
                    if let currentExisting {
                        currentExisting.fileName = oldFileName ?? currentExisting.fileName
                        currentExisting.sizeBytes = oldSize ?? currentExisting.sizeBytes
                        currentExisting.contentHash = oldHash
                        currentExisting.generatedFromContentHash = oldGeneratedFromHash
                        currentExisting.validationStatus = oldValidation
                        currentExisting.dateAdded = oldAssetDate ?? currentExisting.dateAdded
                    }
                    if let insertedAsset {
                        book.assets.removeAll { $0 === insertedAsset }
                        if insertedAsset.modelContext != nil {
                            modelContext.delete(insertedAsset)
                        }
                    }
                }
            ) {
                let liveBook = try mutations.book(id: uuid)
                guard sourceSnapshotIsCurrent(request),
                      liveBook.coverVersion == request.coverVersion else {
                    throw CatalogMutationError.modelNotFound
                }
                if let sourceAssetUUID = request.sourceAssetUUID,
                   let sourceAsset = liveBook.assets.first(where: { $0.uuid == sourceAssetUUID }),
                   sourceAsset.contentHash == nil {
                    sourceAsset.contentHash = sourceHash
                }
                if let existingAssetUUID = request.existingAssetUUID,
                   let asset = liveBook.assets.first(where: { $0.uuid == existingAssetUUID }) {
                    guard asset.fileName == oldFileName,
                          asset.dateAdded == oldAssetDate else {
                        throw CatalogMutationError.modelNotFound
                    }
                    asset.fileName = newFileName
                    asset.sizeBytes = stagedBook.byteCount
                    asset.contentHash = stagedBook.sha256
                    asset.generatedFromContentHash = sourceHash
                    asset.validationStatus = .ok
                    asset.dateAdded = replacementDate
                } else {
                    guard request.existingAssetUUID == nil else {
                        throw CatalogMutationError.modelNotFound
                    }
                    let asset = BookAsset(
                        uuid: request.assetUUID,
                        fileName: newFileName,
                        origin: .generated,
                        contentHash: stagedBook.sha256,
                        generatedFromContentHash: sourceHash,
                        sizeBytes: stagedBook.byteCount,
                        validationStatus: .ok,
                        book: liveBook
                    )
                    modelContext.insert(asset)
                    insertedAsset = asset
                }
                if shouldInstallCover {
                    liveBook.coverVersion = expectedCoverVersion
                }
            }
            guard result.isFullyPublished else {
                toasts.error(String(localized: "Converted file is waiting for recovery."))
                return
            }
        } catch {
            toasts.error(String(localized: "Couldn\u{2019}t save \u{201C}\(request.title)\u{201D}."))
            return
        }

        if shouldInstallCover, let image = extractedCover?.0 {
            await CoverCache.shared.replace(image, for: sourceURL)
        }
        toasts.success(String(localized: "Created \(request.format.label) copy."))
    }

    private func sourceSnapshotIsCurrent(_ request: Request) -> Bool {
        guard request.book.modelContext != nil,
              request.book.fileName == request.sourceFileName,
              request.book.coverVersion == request.coverVersion else { return false }
        guard let sourceAssetUUID = request.sourceAssetUUID else { return true }
        guard let sourceAsset = request.book.assets.first(where: { $0.uuid == sourceAssetUUID }),
              sourceAsset.fileName == request.sourceFileName,
              sourceAsset.dateAdded == request.sourceAssetDateAdded else { return false }
        if let expected = request.sourceContentHash,
           let current = sourceAsset.contentHash,
           current != expected { return false }
        return true
    }
}
