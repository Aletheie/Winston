import Foundation
import SwiftData
import AppKit

@MainActor
@Observable
final class ConversionService {
    private struct InstalledCover {
        let rollback: CoverRollbackTicket
        let version: Int
    }

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
    private let covers: CoverRepository

    private(set) var convertingUUIDs: Set<UUID> = []

    init(
        modelContext: ModelContext,
        toasts: ToastCenter,
        covers: CoverRepository = .shared
    ) {
        self.modelContext = modelContext
        self.toasts = toasts
        self.covers = covers
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
        let coverToken = await covers.beginBackgroundMutation(for: uuid)
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
        if let sourceAssetUUID = request.sourceAssetUUID,
           let sourceAsset = book.assets.first(where: { $0.uuid == sourceAssetUUID }),
           sourceAsset.contentHash == nil {
            sourceAsset.contentHash = sourceHash
        }

        let extractedCover = await Task.detached(priority: .utility) { () -> (NSImage, Data)? in
            if !CoverStore.exists(for: uuid),
               let cover = CoverExtractor.extractCover(from: sourceURL),
               let data = ImageTranscoder.jpegData(from: cover) {
                return (cover, data)
            }
            return nil
        }.value

        guard sourceSnapshotIsCurrent(request) else { return }
        var installedCover: InstalledCover?
        if let (_, coverData) = extractedCover,
           book.coverVersion == request.coverVersion {
            let rollback = await covers.install(coverData, using: coverToken, onlyIfMissing: true)
            guard sourceSnapshotIsCurrent(request) else {
                if let rollback { _ = await covers.rollback(rollback) }
                return
            }
            if let rollback,
               await covers.isCurrent(coverToken),
               book.coverVersion == request.coverVersion {
                book.coverVersion += 1
                installedCover = InstalledCover(rollback: rollback, version: book.coverVersion)
            }
        }

        let converted: URL? = try? await EbookConverter.convert(sourceURL, to: request.format)
        guard sourceSnapshotIsCurrent(request) else {
            if let converted { try? FileManager.default.removeItem(at: converted) }
            await removeInstalledCover(for: book, url: sourceURL, installed: installedCover)
            return
        }
        guard let converted else {
            await removeInstalledCover(for: book, url: sourceURL, installed: installedCover)
            toasts.error(String(localized: "Couldn\u{2019}t convert \u{201C}\(request.title)\u{201D}."))
            return
        }
        defer { try? FileManager.default.removeItem(at: converted) }

        let contentHash = await Task.detached(priority: .utility) {
            try? ContentHasher.sha256(of: converted)
        }.value
        guard sourceSnapshotIsCurrent(request) else {
            await removeInstalledCover(for: book, url: sourceURL, installed: installedCover)
            return
        }

        let existingAsset = request.existingAssetUUID.flatMap { existingUUID in
            book.assets.first { $0.uuid == existingUUID }
        }
        let oldFileName = existingAsset?.fileName
        let storedFile: (name: String, size: Int64)? = await Task.detached(priority: .userInitiated) {
            do {
                let name: String
                if let oldFileName {
                    name = try BookFileStore.replacementCopy(
                        of: converted,
                        replacing: oldFileName,
                        uuid: request.assetUUID
                    )
                } else {
                    name = try BookFileStore.importCopy(of: converted, uuid: request.assetUUID)
                }
                return (name, BookFileStore.size(of: name))
            } catch {
                return nil
            }
        }.value
        guard let storedFile else {
            await removeInstalledCover(for: book, url: sourceURL, installed: installedCover)
            toasts.error(String(localized: "Couldn\u{2019}t convert \u{201C}\(request.title)\u{201D}."))
            return
        }
        let newFileName = storedFile.name
        let size = storedFile.size
        guard sourceSnapshotIsCurrent(request) else {
            Task.detached(priority: .utility) {
                BookFileStore.delete(fileName: newFileName)
            }
            await removeInstalledCover(for: book, url: sourceURL, installed: installedCover)
            return
        }
        if let asset = existingAsset {
            asset.fileName = newFileName
            asset.sizeBytes = size
            asset.contentHash = contentHash
            asset.generatedFromContentHash = sourceHash
            asset.validationStatus = .ok
            asset.dateAdded = Date()
        } else {
            let asset = BookAsset(
                uuid: request.assetUUID,
                fileName: newFileName,
                origin: .generated,
                contentHash: contentHash,
                generatedFromContentHash: sourceHash,
                sizeBytes: size,
                validationStatus: .ok,
                book: book
            )
            modelContext.insert(asset)
        }
        guard modelContext.saveQuietly(rollbackOnFailure: true) else {
            Task.detached(priority: .utility) {
                BookFileStore.delete(fileName: newFileName)
            }
            await removeInstalledCover(
                for: book, url: sourceURL, installed: installedCover, force: true
            )
            toasts.error(String(localized: "Couldn\u{2019}t save \u{201C}\(request.title)\u{201D}."))
            return
        }
        if let oldFileName, oldFileName != newFileName {
            Task.detached(priority: .utility) {
                BookFileStore.delete(fileName: oldFileName)
            }
        }
        toasts.success(String(localized: "Created \(request.format.label) copy."))
    }

    private func removeInstalledCover(
        for book: Book,
        url: URL,
        installed: InstalledCover?,
        force: Bool = false
    ) async {
        guard let installed, force || book.coverVersion == installed.version else { return }
        guard await covers.rollback(installed.rollback) else { return }
        if book.coverVersion == installed.version {
            book.coverVersion = max(0, installed.version - 1)
        }
        await CoverCache.shared.replace(nil, for: url)
    }

    private func sourceSnapshotIsCurrent(_ request: Request) -> Bool {
        guard request.book.modelContext != nil,
              request.book.fileName == request.sourceFileName else { return false }
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
