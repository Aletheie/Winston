import AppKit
import Foundation
import SwiftData

typealias ConversionWorker = @Sendable (
    URL,
    EbookConverter.OutputFormat
) async throws -> URL

nonisolated enum ConversionCheckpoint: Sendable {
    case artifactReady
}

typealias ConversionCheckpointHandler = @Sendable (ConversionCheckpoint) async -> Void

nonisolated enum ConversionArtifactAdoptionResult: Sendable, Equatable {
    case adopted
    case conflict
    case failed
    case pendingRecovery
}

@MainActor
@Observable
final class ConversionService {
    /// Catalog identity of the source file. Derived inspection fields are
    /// deliberately excluded: hash/size/validation backfills may finish while
    /// conversion is running without replacing the source bytes. The physical
    /// digest is captured and checked separately around every long phase.
    private struct SourceGeneration: Equatable, Sendable {
        let uuid: UUID
        let fileName: String
        let dateAdded: Date
        let isPrimary: Bool
    }

    private struct AssetGeneration: Equatable, Sendable {
        let uuid: UUID
        let fileName: String
        let dateAdded: Date
        let contentHash: String?
        let generatedFromContentHash: String?
        let sizeBytes: Int64
        let originRaw: String?
        let validationStatusRaw: String?
        let isPrimary: Bool
    }

    private struct TargetGeneration: Equatable, Sendable {
        let format: String
        let assets: [AssetGeneration]
        let replacementAssetUUID: UUID?

        var replacementAsset: AssetGeneration? {
            guard let replacementAssetUUID else { return nil }
            return assets.first { $0.uuid == replacementAssetUUID }
        }
    }

    /// Contains no live SwiftData models. Both sides of the conversion are
    /// immutable generations captured before the first suspension point.
    private struct Request: Sendable {
        let uuid: UUID
        let sourceURL: URL
        let sourceFileName: String
        let sourceAsset: SourceGeneration?
        let coverVersion: Int
        let newAssetUUID: UUID
        let target: TargetGeneration
        let title: String
        let format: EbookConverter.OutputFormat
    }

    private enum TargetFileIdentity: Equatable, Sendable {
        case none
        case missing
        case sha256(String)
    }

    private enum SnapshotConflict: Sendable {
        case sourceChanged
        case targetChanged
    }

    private enum InstallResult: Sendable {
        case installed
        case conflict(SnapshotConflict)
        case failed
        case pendingRecovery
    }

    private struct AssetPreimage {
        let asset: BookAsset
        let fileName: String
        let dateAdded: Date
        let contentHash: String?
        let generatedFromContentHash: String?
        let sizeBytes: Int64
        let originRaw: String?
        let validationStatusRaw: String?

        init(_ asset: BookAsset) {
            self.asset = asset
            fileName = asset.fileName
            dateAdded = asset.dateAdded
            contentHash = asset.contentHash
            generatedFromContentHash = asset.generatedFromContentHash
            sizeBytes = asset.sizeBytes
            originRaw = asset.originRaw
            validationStatusRaw = asset.validationStatusRaw
        }

        func restore() {
            asset.fileName = fileName
            asset.dateAdded = dateAdded
            asset.contentHash = contentHash
            asset.generatedFromContentHash = generatedFromContentHash
            asset.sizeBytes = sizeBytes
            asset.originRaw = originRaw
            asset.validationStatusRaw = validationStatusRaw
        }
    }

    private struct BookPreimage {
        let book: Book
        let fileName: String
        let fileSizeBytes: Int64
        let coverVersion: Int

        init(_ book: Book) {
            self.book = book
            fileName = book.fileName
            fileSizeBytes = book.fileSizeBytes
            coverVersion = book.coverVersion
        }

        func restore() {
            book.fileName = fileName
            book.fileSizeBytes = fileSizeBytes
            book.coverVersion = coverVersion
        }
    }

    private let modelContext: ModelContext
    private let toasts: ToastCenter
    private let mutations: CatalogMutationService
    private let managedFiles: ManagedFileCoordinator
    private let worker: ConversionWorker
    private let checkpoint: ConversionCheckpointHandler

    private(set) var convertingUUIDs: Set<UUID> = []

    init(
        modelContext: ModelContext,
        toasts: ToastCenter,
        mutations: CatalogMutationService? = nil,
        managedFiles: ManagedFileCoordinator = .shared,
        worker: @escaping ConversionWorker = { source, format in
            try await EbookConverter.convert(source, to: format)
        },
        checkpoint: @escaping ConversionCheckpointHandler = { _ in }
    ) {
        self.modelContext = modelContext
        self.toasts = toasts
        self.mutations = mutations ?? CatalogMutationService(
            modelContext: modelContext,
            managedFiles: managedFiles
        )
        self.managedFiles = managedFiles
        self.worker = worker
        self.checkpoint = checkpoint
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
        guard let request = makeRequest(for: book, to: format) else {
            toasts.error(String(
                localized: "Couldn\u{2019}t prepare \u{201C}\(book.displayTitle)\u{201D} for conversion.",
                comment: "Conversion setup error; the placeholder is the book title."
            ))
            return
        }
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
        let requests = targets.compactMap {
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
        let requests = targets.compactMap { makeRequest(for: $0, to: format) }
        for request in requests { convertingUUIDs.insert(request.uuid) }
        Task {
            for request in requests { await performConvert(request) }
        }
    }

    @discardableResult
    func adoptArtifact(for bookUUID: UUID, from url: URL) async -> ConversionArtifactAdoptionResult {
        guard let book = lookupBook(uuid: bookUUID), book.hasDigitalFile,
              let format = EbookConverter.OutputFormat(rawValue: url.pathExtension.lowercased()),
              let request = makeRequest(for: book, to: format) else {
            return .failed
        }
        guard snapshotConflict(for: request) == nil else { return .conflict }
        guard let sourceHash = await hash(of: request.sourceURL) else { return .failed }
        guard let targetIdentity = await captureTargetFileIdentity(for: request) else {
            notify(.targetChanged, request: request)
            return .conflict
        }
        if let conflict = snapshotConflict(for: request) {
            notify(conflict, request: request)
            return .conflict
        }

        let result = await installArtifact(
            at: url,
            for: request,
            sourceHash: sourceHash,
            targetIdentity: targetIdentity,
            extractedCover: nil
        )
        switch result {
        case .installed:
            return .adopted
        case .conflict(let conflict):
            notify(conflict, request: request)
            return .conflict
        case .failed:
            toasts.error(String(localized: "Couldn\u{2019}t save \u{201C}\(request.title)\u{201D}."))
            return .failed
        case .pendingRecovery:
            toasts.error(String(localized: "Converted file is waiting for recovery."))
            return .pendingRecovery
        }
    }

    private func makeRequest(
        for book: Book,
        to format: EbookConverter.OutputFormat
    ) -> Request? {
        let sourceAsset = primaryAsset(in: book).map {
            Self.sourceGeneration(of: $0, primaryFileName: book.fileName)
        }
        let target = Self.targetGeneration(for: book, format: format.ext)
        if let replacementAssetUUID = target.replacementAssetUUID,
           replacementAssetUUID == sourceAsset?.uuid {
            return nil
        }
        return Request(
            uuid: book.uuid,
            sourceURL: book.fileURL,
            sourceFileName: book.fileName,
            sourceAsset: sourceAsset,
            coverVersion: book.coverVersion,
            newAssetUUID: UUID(),
            target: target,
            title: book.displayTitle,
            format: format
        )
    }

    private func performConvert(_ request: Request) async {
        defer { convertingUUIDs.remove(request.uuid) }
        guard snapshotConflict(for: request) == nil else { return }

        guard let sourceHash = await hash(of: request.sourceURL) else {
            toasts.error(String(localized: "Couldn\u{2019}t convert \u{201C}\(request.title)\u{201D}."))
            return
        }
        guard let targetIdentity = await captureTargetFileIdentity(for: request) else {
            notify(.targetChanged, request: request)
            return
        }
        if let conflict = snapshotConflict(for: request) {
            notify(conflict, request: request)
            return
        }

        let extractedCover = await Task.detached(priority: .utility) { () -> (NSImage, Data)? in
            if !CoverStore.exists(for: request.uuid),
               let cover = CoverExtractor.extractCover(from: request.sourceURL),
               let data = ImageTranscoder.jpegData(from: cover) {
                return (cover, data)
            }
            return nil
        }.value
        if let conflict = snapshotConflict(for: request) {
            notify(conflict, request: request)
            return
        }

        let converted: URL
        do {
            converted = try await worker(request.sourceURL, request.format)
        } catch {
            toasts.error(String(localized: "Couldn\u{2019}t convert \u{201C}\(request.title)\u{201D}."))
            return
        }
        defer { try? FileManager.default.removeItem(at: converted) }

        let result = await installArtifact(
            at: converted,
            for: request,
            sourceHash: sourceHash,
            targetIdentity: targetIdentity,
            extractedCover: extractedCover
        )
        switch result {
        case .installed:
            if let image = extractedCover?.0 {
                await CoverCache.shared.replace(image, for: request.sourceURL)
            }
            toasts.success(String(localized: "Created \(request.format.label) copy."))
        case .conflict(let conflict):
            notify(conflict, request: request)
        case .failed:
            toasts.error(String(localized: "Couldn\u{2019}t save \u{201C}\(request.title)\u{201D}."))
        case .pendingRecovery:
            toasts.error(String(localized: "Converted file is waiting for recovery."))
        }
    }

    private func installArtifact(
        at artifactURL: URL,
        for request: Request,
        sourceHash: String,
        targetIdentity: TargetFileIdentity,
        extractedCover: (NSImage, Data)?
    ) async -> InstallResult {
        await checkpoint(.artifactReady)
        if let conflict = snapshotConflict(for: request) {
            return .conflict(conflict)
        }
        guard await hash(of: request.sourceURL) == sourceHash else {
            return .conflict(.sourceChanged)
        }
        guard await targetFileIdentityIsCurrent(targetIdentity, request: request) else {
            return .conflict(.targetChanged)
        }

        let replacement: AssetGeneration?
        let expectedTargetHash: String?
        switch targetIdentity {
        case .sha256(let hash):
            replacement = request.target.replacementAsset
            expectedTargetHash = hash
        case .none, .missing:
            // A missing target is retained as a recoverable catalog record. A
            // new generated asset is safer than reusing a generation whose
            // physical bytes did not exist when conversion began.
            replacement = nil
            expectedTargetHash = nil
        }
        let installedAssetUUID = replacement?.uuid ?? request.newAssetUUID

        let bookSource: ManagedFileSource
        do {
            bookSource = try .book(sourceURL: artifactURL)
        } catch {
            return .failed
        }
        let newFileName = bookSource.finalRelativeName
        let oldFileName = replacement?.fileName
        let retiredNames = Set(oldFileName.map { [$0] } ?? [])

        let shouldInstallCover = extractedCover != nil
            && lookupBook(uuid: request.uuid)?.coverVersion == request.coverVersion
            && !CoverStore.exists(for: request.uuid)
        let expectedCoverVersion = request.coverVersion + (shouldInstallCover ? 1 : 0)
        var sources = [bookSource]
        if shouldInstallCover, let coverData = extractedCover?.1 {
            sources.append(.cover(data: coverData, bookID: request.uuid))
        }
        let cleanups: [ManagedFileCleanup]
        if let oldFileName, let expectedTargetHash {
            cleanups = [.book(oldFileName, expectedSHA256: expectedTargetHash)]
        } else {
            cleanups = []
        }

        let transaction: ManagedFileTransaction
        do {
            transaction = try await managedFiles.stage(
                intent: .conversionOutput,
                sources: sources,
                requirement: ManagedFileRequirement(
                    presentBookIDs: [request.uuid],
                    referencedBookFileNames: [newFileName],
                    unreferencedBookFileNames: retiredNames,
                    coverVersions: shouldInstallCover ? [request.uuid: expectedCoverVersion] : [:]
                ),
                cleanups: cleanups
            )
        } catch {
            return .failed
        }

        if let conflict = snapshotConflict(for: request) {
            await managedFiles.abort(transaction)
            return .conflict(conflict)
        }
        guard await hash(of: request.sourceURL) == sourceHash else {
            await managedFiles.abort(transaction)
            return .conflict(.sourceChanged)
        }
        guard await targetFileIdentityIsCurrent(targetIdentity, request: request),
              let stagedBook = transaction.files.first(where: { $0.kind == .book }) else {
            await managedFiles.abort(transaction)
            return .conflict(.targetChanged)
        }

        var mutationWasApplied = false
        var insertedAsset: BookAsset?
        var bookPreimage: BookPreimage?
        var sourcePreimage: AssetPreimage?
        var targetPreimage: AssetPreimage?
        let replacementDate = Date()
        do {
            let result = try await mutations.commitFileMutation(
                .conversionOutput(bookID: request.uuid, assetID: installedAssetUUID),
                transaction: transaction,
                affectedBookIDs: [request.uuid],
                revertingOnFailure: {
                    guard mutationWasApplied else { return }
                    if let insertedAsset {
                        insertedAsset.book?.assets.removeAll { $0 === insertedAsset }
                        if insertedAsset.modelContext != nil {
                            modelContext.delete(insertedAsset)
                        }
                    }
                    targetPreimage?.restore()
                    sourcePreimage?.restore()
                    bookPreimage?.restore()
                }
            ) {
                let liveBook = try mutations.book(id: request.uuid)
                guard snapshotConflict(for: request, in: liveBook) == nil else {
                    throw CatalogMutationError.staleConversion
                }
                let liveSource = request.sourceAsset.flatMap { source in
                    liveBook.assets.first { $0.uuid == source.uuid }
                }
                if request.sourceAsset != nil, liveSource == nil {
                    throw CatalogMutationError.staleConversion
                }
                let liveTarget = replacement.flatMap { target in
                    liveBook.assets.first { $0.uuid == target.uuid }
                }
                if replacement != nil, liveTarget == nil {
                    throw CatalogMutationError.staleConversion
                }
                guard liveBook.assets.allSatisfy({ $0.uuid != request.newAssetUUID }) else {
                    throw CatalogMutationError.staleConversion
                }

                bookPreimage = BookPreimage(liveBook)
                sourcePreimage = liveSource.map(AssetPreimage.init)
                targetPreimage = liveTarget.map(AssetPreimage.init)
                mutationWasApplied = true

                liveSource?.contentHash = sourceHash
                if let liveTarget {
                    liveTarget.fileName = newFileName
                    liveTarget.sizeBytes = stagedBook.byteCount
                    liveTarget.contentHash = stagedBook.sha256
                    liveTarget.generatedFromContentHash = sourceHash
                    liveTarget.validationStatus = .ok
                    liveTarget.dateAdded = replacementDate
                } else {
                    let asset = BookAsset(
                        uuid: request.newAssetUUID,
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
                if replacement?.isPrimary == true {
                    liveBook.fileName = newFileName
                    liveBook.fileSizeBytes = stagedBook.byteCount
                }
                if shouldInstallCover {
                    liveBook.coverVersion = expectedCoverVersion
                }
            }
            return result.isFullyPublished ? .installed : .pendingRecovery
        } catch {
            if let conflict = snapshotConflict(for: request) {
                return .conflict(conflict)
            }
            if await hash(of: request.sourceURL) != sourceHash {
                return .conflict(.sourceChanged)
            }
            if !(await targetFileIdentityIsCurrent(targetIdentity, request: request)) {
                return .conflict(.targetChanged)
            }
            return .failed
        }
    }

    private func snapshotConflict(for request: Request) -> SnapshotConflict? {
        guard let book = lookupBook(uuid: request.uuid) else { return .sourceChanged }
        return snapshotConflict(for: request, in: book)
    }

    private func snapshotConflict(for request: Request, in book: Book) -> SnapshotConflict? {
        if Self.targetGeneration(for: book, format: request.target.format) != request.target {
            return .targetChanged
        }
        guard book.fileName == request.sourceFileName,
              book.coverVersion == request.coverVersion else {
            return .sourceChanged
        }
        if let expectedSource = request.sourceAsset {
            guard let source = book.assets.first(where: { $0.uuid == expectedSource.uuid }),
                  Self.sourceGeneration(of: source, primaryFileName: book.fileName) == expectedSource else {
                return .sourceChanged
            }
        } else if book.assets.contains(where: { $0.fileName == request.sourceFileName }) {
            return .sourceChanged
        }
        return nil
    }

    private func captureTargetFileIdentity(for request: Request) async -> TargetFileIdentity? {
        guard let target = request.target.replacementAsset else {
            return TargetFileIdentity.none
        }
        guard let url = BookFileStore.validatedURL(for: target.fileName) else { return nil }
        return await Task.detached(priority: .utility) { () -> TargetFileIdentity? in
            let path = url.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path) else { return .missing }
            guard let digest = try? ContentHasher.sha256Cancellable(of: url) else { return nil }
            return .sha256(digest)
        }.value
    }

    private func targetFileIdentityIsCurrent(
        _ identity: TargetFileIdentity,
        request: Request
    ) async -> Bool {
        switch identity {
        case .none, .missing:
            return true
        case .sha256(let expected):
            guard let target = request.target.replacementAsset,
                  let url = BookFileStore.validatedURL(for: target.fileName) else { return false }
            return await hash(of: url) == expected
        }
    }

    private func hash(of url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            try? ContentHasher.sha256Cancellable(of: url)
        }.value
    }

    private func notify(_ conflict: SnapshotConflict, request: Request) {
        switch conflict {
        case .sourceChanged:
            toasts.info(String(
                localized: "\u{201C}\(request.title)\u{201D} changed during conversion. The conversion result was not installed.",
                comment: "Stale conversion warning; the placeholder is the book title."
            ))
        case .targetChanged:
            toasts.info(String(
                localized: "The \(request.format.label) destination for \u{201C}\(request.title)\u{201D} changed during conversion. The conversion result was not installed.",
                comment: "Stale conversion warning; the first placeholder is a file format and the second is the book title."
            ))
        }
    }

    private func lookupBook(uuid: UUID) -> Book? {
        try? mutations.book(id: uuid)
    }

    private func primaryAsset(in book: Book) -> BookAsset? {
        let candidates = book.assets.filter { $0.fileName == book.fileName }
        return candidates.first(where: { $0.uuid == book.uuid })
            ?? candidates.min { $0.uuid.uuidString < $1.uuid.uuidString }
    }

    private static func targetGeneration(for book: Book, format: String) -> TargetGeneration {
        let assets = book.assets
            .filter { $0.format.lowercased() == format }
            .map { generation(of: $0, primaryFileName: book.fileName) }
            .sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        let replacement = assets
            .filter { $0.originRaw == AssetOrigin.generated.rawValue }
            .min { $0.uuid.uuidString < $1.uuid.uuidString }
        return TargetGeneration(
            format: format,
            assets: assets,
            replacementAssetUUID: replacement?.uuid
        )
    }

    private static func generation(
        of asset: BookAsset,
        primaryFileName: String
    ) -> AssetGeneration {
        AssetGeneration(
            uuid: asset.uuid,
            fileName: asset.fileName,
            dateAdded: asset.dateAdded,
            contentHash: asset.contentHash,
            generatedFromContentHash: asset.generatedFromContentHash,
            sizeBytes: asset.sizeBytes,
            originRaw: asset.originRaw,
            validationStatusRaw: asset.validationStatusRaw,
            isPrimary: asset.fileName == primaryFileName
        )
    }

    private static func sourceGeneration(
        of asset: BookAsset,
        primaryFileName: String
    ) -> SourceGeneration {
        SourceGeneration(
            uuid: asset.uuid,
            fileName: asset.fileName,
            dateAdded: asset.dateAdded,
            isPrimary: asset.fileName == primaryFileName
        )
    }
}
