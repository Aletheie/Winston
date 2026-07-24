import CryptoKit
import Foundation
import Observation
import OSLog
import PDFKit
import SwiftData

nonisolated enum MaintenanceJob: String, CaseIterable, Sendable {
    case legacyLibrary
    case catalogStructure
    case catalogCleanup
    case assetInspection
    case metadataExtraction
    case editionDiscovery
    case automaticBackup
}

nonisolated struct MaintenanceProgress: Equatable, Sendable {
    let job: MaintenanceJob
    let completed: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

nonisolated enum MaintenancePauseReason: Equatable, Sendable {
    case requested
    case lowPower
}

nonisolated enum MaintenancePhase: Equatable, Sendable {
    case idle
    case running(MaintenanceProgress)
    case paused(MaintenanceProgress, MaintenancePauseReason)
    case failed(MaintenanceJob, String)
    case completed
}

@MainActor
final class MaintenanceCheckpointStore {
    private let defaults: UserDefaults
    private let prefix: String

    init(
        defaults: UserDefaults = .standard,
        prefix: String = "maintenance.scheduler"
    ) {
        self.defaults = defaults
        self.prefix = prefix
    }

    func offset(for job: MaintenanceJob, version: Int) -> Int {
        max(0, defaults.integer(forKey: key(job, version: version, suffix: "offset")))
    }

    func setOffset(_ offset: Int, for job: MaintenanceJob, version: Int) {
        defaults.set(max(0, offset), forKey: key(job, version: version, suffix: "offset"))
    }

    func isCompleted(_ job: MaintenanceJob, version: Int) -> Bool {
        defaults.bool(forKey: key(job, version: version, suffix: "complete"))
    }

    func markCompleted(_ job: MaintenanceJob, version: Int) {
        defaults.set(true, forKey: key(job, version: version, suffix: "complete"))
        defaults.removeObject(forKey: key(job, version: version, suffix: "offset"))
    }

    func reset(_ job: MaintenanceJob, version: Int) {
        defaults.removeObject(forKey: key(job, version: version, suffix: "complete"))
        defaults.removeObject(forKey: key(job, version: version, suffix: "offset"))
    }

    func resetAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("\(prefix).") {
            defaults.removeObject(forKey: key)
        }
    }

    private func key(
        _ job: MaintenanceJob,
        version: Int,
        suffix: String
    ) -> String {
        "\(prefix).\(job.rawValue).v\(version).\(suffix)"
    }
}

nonisolated struct AssetInspectionRequirements: Equatable, Sendable {
    let size: Bool
    let hash: Bool
    let drm: Bool
    let validation: Bool

    var isEmpty: Bool {
        !size && !hash && !drm && !validation
    }
}

nonisolated struct AssetInspectionInput: Equatable, Sendable {
    let bookID: UUID
    let assetID: UUID
    let fileName: String
    let assetDateAdded: Date
    let storedHash: String?
    let storedSize: Int64
    let storedValidation: AssetValidation?
    let primaryAssetID: UUID?
    let primaryFileName: String
    let primaryDRM: Bool?
    let primarySize: Int64
    let requirements: AssetInspectionRequirements

    var fileURL: URL { BookFileStore.url(for: fileName) }
    var isPrimary: Bool { assetID == primaryAssetID }

    @MainActor
    init?(asset: BookAsset, book: Book) {
        guard asset.modelContext != nil,
              book.modelContext != nil,
              asset.book?.uuid == book.uuid,
              ManagedLeafName(rawValue: asset.fileName) != nil else {
            return nil
        }
        let primaryAsset = book.primaryAsset
        let primaryFileName = primaryAsset?.fileName ?? book.fileName
        let isPrimary = asset.uuid == primaryAsset?.uuid
        bookID = book.uuid
        assetID = asset.uuid
        fileName = asset.fileName
        assetDateAdded = asset.dateAdded
        storedHash = asset.contentHash
        storedSize = asset.sizeBytes
        storedValidation = asset.validationStatus
        self.primaryAssetID = primaryAsset?.uuid
        self.primaryFileName = primaryFileName
        primaryDRM = book.drmProtected
        primarySize = primaryAsset?.sizeBytes ?? book.fileSizeBytes
        requirements = AssetInspectionRequirements(
            size: asset.sizeBytes <= 0 || (isPrimary && book.fileSizeBytes <= 0),
            hash: asset.contentHash == nil,
            drm: isPrimary && book.drmProtected == nil,
            validation: asset.validationStatus == nil
        )
    }

    @MainActor
    func matches(book: Book, asset: BookAsset) -> Bool {
        sourceMatches(book: book, asset: asset)
            && asset.contentHash == storedHash
            && asset.sizeBytes == storedSize
            && asset.validationStatus == storedValidation
            && (!isPrimary
                || (book.drmProtected == primaryDRM
                    && book.fileSizeBytes == primarySize))
    }

    @MainActor
    func sourceMatches(book: Book, asset: BookAsset) -> Bool {
        book.modelContext != nil
            && asset.modelContext != nil
            && book.uuid == bookID
            && asset.uuid == assetID
            && asset.book?.uuid == bookID
            && asset.fileName == fileName
            && asset.dateAdded == assetDateAdded
            && book.primaryAsset?.uuid == primaryAssetID
            && (book.primaryAsset?.fileName ?? book.fileName) == primaryFileName
    }
}

nonisolated struct AssetInspectionOutput: Equatable, Sendable {
    let sizeBytes: Int64
    let contentHash: String?
    let drmProtected: Bool?
    let validation: AssetValidation?
    let fileOpenCount: Int
}

nonisolated struct AssetInspectionProposal: Sendable {
    let input: AssetInspectionInput
    let output: AssetInspectionOutput
    let fileGeneration: CatalogFileGeneration?

    var sourceIsCurrent: Bool {
        if let fileGeneration {
            return CatalogFileGeneration.capture(at: input.fileURL) == fileGeneration
        }
        return !FileManager.default.fileExists(
            atPath: input.fileURL.path(percentEncoded: false)
        )
    }
}

nonisolated enum AssetInspectionPipeline {
    private static let readSize = 1_048_576

    @concurrent
    static func inspect(_ input: AssetInspectionInput) async -> AssetInspectionProposal? {
        guard !Task.isCancelled, !input.requirements.isEmpty else { return nil }
        guard let before = CatalogFileGeneration.capture(at: input.fileURL) else {
            return AssetInspectionProposal(
                input: input,
                output: AssetInspectionOutput(
                    sizeBytes: 0,
                    contentHash: nil,
                    drmProtected: nil,
                    validation: .missing,
                    fileOpenCount: 0
                ),
                fileGeneration: nil
            )
        }

        let format = input.fileURL.pathExtension.lowercased()
        var fileOpenCount = 0
        var contentHash: String?
        var prefix = Data()
        var mobiEncryption: UInt16?
        var mappedFile: Data?
        let parsesContainer = ["epub", "pdf"].contains(format)
            && (input.requirements.drm || input.requirements.validation)

        if input.requirements.hash, parsesContainer {
            do {
                let data = try Data(contentsOf: input.fileURL, options: .mappedIfSafe)
                fileOpenCount += 1
                contentHash = try sha256(of: data)
                mappedFile = data
            } catch is CancellationError {
                return nil
            } catch {
                return corruptProposal(
                    input: input,
                    generation: before,
                    fileOpenCount: fileOpenCount
                )
            }
        }

        if mappedFile == nil, input.requirements.hash
            || (["mobi", "azw", "azw3"].contains(format)
                && (input.requirements.drm || input.requirements.validation)) {
            do {
                let handle = try FileHandle(forReadingFrom: input.fileURL)
                fileOpenCount += 1
                defer { try? handle.close() }
                var hasher = SHA256()
                let shouldHash = input.requirements.hash
                while true {
                    try Task.checkCancellation()
                    guard let data = try handle.read(upToCount: readSize), !data.isEmpty else {
                        break
                    }
                    if shouldHash { hasher.update(data: data) }
                    if prefix.count < readSize {
                        prefix.append(data.prefix(readSize - prefix.count))
                    }
                    if !shouldHash { break }
                }
                if shouldHash {
                    contentHash = hasher.finalize()
                        .map { String(format: "%02x", $0) }
                        .joined()
                }
                if ["mobi", "azw", "azw3"].contains(format),
                   prefix.count >= 82 {
                    let recordOffset = Int(prefix.readUInt32BE(at: 78))
                    if recordOffset + 14 <= prefix.count {
                        mobiEncryption = prefix.readUInt16BE(at: recordOffset + 12)
                    } else if recordOffset + 14 > prefix.count,
                       recordOffset >= 0,
                       recordOffset + 14 <= before.fileSize {
                        try handle.seek(toOffset: UInt64(recordOffset))
                        if let recordHeader = try handle.read(upToCount: 14),
                           recordHeader.count >= 14 {
                            mobiEncryption = recordHeader.readUInt16BE(at: 12)
                        }
                    }
                }
            } catch is CancellationError {
                return nil
            } catch {
                return corruptProposal(
                    input: input,
                    generation: before,
                    fileOpenCount: fileOpenCount
                )
            }
        }

        var validation: AssetValidation?
        var drmProtected: Bool?
        switch format {
        case "epub" where input.requirements.validation || input.requirements.drm:
            let archive: EPUBArchive?
            if let mappedFile {
                archive = try? EPUBArchive(data: mappedFile, sourceURL: input.fileURL)
            } else {
                fileOpenCount += 1
                archive = try? EPUBArchive(url: input.fileURL)
            }
            if let archive {
                if input.requirements.validation {
                    let isValid = archive.entry("META-INF/container.xml")
                        .flatMap(MetadataExtractor.parseOPFPath(from:))
                        .flatMap(archive.entry) != nil
                    validation = isValid ? .ok : .corrupt
                }
                if input.requirements.drm {
                    drmProtected = archive.entry("META-INF/rights.xml") != nil
                }
            } else {
                validation = input.requirements.validation ? .corrupt : nil
                drmProtected = input.requirements.drm ? false : nil
            }

        case "pdf" where input.requirements.validation || input.requirements.drm:
            let document: PDFDocument?
            if let mappedFile {
                document = PDFDocument(data: mappedFile)
            } else {
                fileOpenCount += 1
                document = PDFDocument(url: input.fileURL)
            }
            if input.requirements.validation {
                validation = document == nil ? .corrupt : .ok
            }
            if input.requirements.drm {
                drmProtected = document.map { $0.isEncrypted && $0.isLocked } ?? false
            }

        case "mobi", "azw", "azw3":
            if input.requirements.validation {
                validation = prefix.count >= 68
                    && String(data: prefix[60 ..< 68], encoding: .ascii) == "BOOKMOBI"
                    ? .ok
                    : .corrupt
            }
            if input.requirements.drm {
                drmProtected = prefix.count > 78
                    && Int(prefix.readUInt16BE(at: 76)) > 0
                    && (mobiEncryption == 1 || mobiEncryption == 2)
            }

        default:
            if input.requirements.validation { validation = .ok }
            if input.requirements.drm { drmProtected = false }
        }

        guard !Task.isCancelled,
              let after = CatalogFileGeneration.capture(at: input.fileURL),
              before == after else { return nil }
        return AssetInspectionProposal(
            input: input,
            output: AssetInspectionOutput(
                sizeBytes: after.fileSize,
                contentHash: contentHash,
                drmProtected: drmProtected,
                validation: validation,
                fileOpenCount: fileOpenCount
            ),
            fileGeneration: after
        )
    }

    private static func sha256(of data: Data) throws -> String {
        var hasher = SHA256()
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let end = min(offset + readSize, data.count)
            hasher.update(data: data[offset ..< end])
            offset = end
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func corruptProposal(
        input: AssetInspectionInput,
        generation: CatalogFileGeneration,
        fileOpenCount: Int
    ) -> AssetInspectionProposal {
        AssetInspectionProposal(
            input: input,
            output: AssetInspectionOutput(
                sizeBytes: generation.fileSize,
                contentHash: nil,
                drmProtected: nil,
                validation: .corrupt,
                fileOpenCount: fileOpenCount
            ),
            fileGeneration: generation
        )
    }
}

@MainActor
enum CatalogStructureBackfill {
    struct ChunkResult: Equatable {
        let visited: Int
        let changedBooks: Int
        let hasMore: Bool
    }

    struct CleanupChunkResult: Equatable {
        let visited: Int
        let deleted: Int
        let nextOffset: Int
    }

    static func processChunk(
        context: ModelContext,
        offset: Int,
        limit: Int
    ) throws -> ChunkResult {
        guard !context.hasChanges else { throw MaintenanceSchedulerError.dirtyContext }
        var descriptor = FetchDescriptor<Book>(
            sortBy: [
                SortDescriptor(\Book.dateAdded),
                SortDescriptor(\Book.uuid),
            ]
        )
        descriptor.relationshipKeyPathsForPrefetching = [
            \Book.assets,
            \Book.work,
            \Book.readingSessions,
        ]
        descriptor.fetchOffset = max(0, offset)
        descriptor.fetchLimit = max(1, limit)
        let books = try context.fetch(descriptor)
        var changedBookIDs: Set<UUID> = []
        var changedWorkIDs: Set<UUID> = []
        var changedAssetIDs: Set<UUID> = []
        var fullTextBookIDs: Set<UUID> = []

        for book in books {
            if book.repairPrimaryAssetInvariant() {
                changedBookIDs.insert(book.uuid)
                if let primaryAssetID = book.primaryAssetUUID {
                    changedAssetIDs.insert(primaryAssetID)
                }
                fullTextBookIDs.insert(book.uuid)
            }

            if book.assets.isEmpty,
               !book.fileName.isEmpty,
               ManagedLeafName(rawValue: book.fileName) != nil {
                let asset = BookAsset(
                    uuid: book.uuid,
                    fileName: book.fileName,
                    origin: .original,
                    sizeBytes: book.fileSizeBytes,
                    dateAdded: book.dateAdded,
                    book: book
                )
                context.insert(asset)
                book.primaryAssetUUID = asset.uuid
                changedBookIDs.insert(book.uuid)
                changedAssetIDs.insert(asset.uuid)
                fullTextBookIDs.insert(book.uuid)
            }

            if book.work == nil {
                let work = Work(
                    title: book.displayTitle,
                    author: book.author,
                    dateCreated: book.dateAdded
                )
                context.insert(work)
                book.work = work
                work.preferredEditionUUID = book.uuid
                changedBookIDs.insert(book.uuid)
                changedWorkIDs.insert(work.uuid)
            }

            if let work = book.work,
               WorkService.repairPreferredEditionInvariant(work) {
                changedBookIDs.formUnion(work.editions.map(\.uuid))
                changedWorkIDs.insert(work.uuid)
            }

            if book.readingSessions.isEmpty,
               let session = readingSession(for: book) {
                context.insert(session)
                changedBookIDs.insert(book.uuid)
            }
        }

        if !changedBookIDs.isEmpty {
            try context.saveAndPublish(
                affectedBookIDs: changedBookIDs,
                affectedWorkIDs: changedWorkIDs,
                affectedAssetIDs: changedAssetIDs,
                fields: [
                    .assetAvailability,
                    .displayMetadata,
                    .fullTextSource,
                    .readingState,
                    .workMembership,
                ],
                fullTextAffectedBookIDs: fullTextBookIDs
            )
        }
        return ChunkResult(
            visited: books.count,
            changedBooks: changedBookIDs.count,
            hasMore: books.count == max(1, limit)
        )
    }

    static func pruneOrphanWorksChunk(
        context: ModelContext,
        offset: Int,
        limit: Int
    ) throws -> CleanupChunkResult {
        guard !context.hasChanges else { throw MaintenanceSchedulerError.dirtyContext }
        var descriptor = FetchDescriptor<Work>(
            sortBy: [SortDescriptor(\Work.uuid)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\Work.editions]
        descriptor.fetchOffset = max(0, offset)
        descriptor.fetchLimit = max(1, limit)
        let works = try context.fetch(descriptor)
        let orphaned = works.filter(\.editions.isEmpty)
        orphaned.forEach(context.delete)
        if !orphaned.isEmpty {
            try context.save()
        }
        return CleanupChunkResult(
            visited: works.count,
            deleted: orphaned.count,
            nextOffset: max(0, offset) + works.count - orphaned.count
        )
    }

    private static func readingSession(for book: Book) -> ReadingSession? {
        let status = book.readingStatus
        guard status != .unread else { return nil }
        let startedAt = book.dateStarted ?? book.dateFinished ?? book.dateAdded
        let sessionStatus: ReadingSessionStatus
        let endedAt: Date?
        let progress: Double
        switch status {
        case .unread:
            return nil
        case .reading:
            sessionStatus = .reading
            endedAt = nil
            progress = 0
        case .paused:
            sessionStatus = .paused
            endedAt = nil
            progress = 0
        case .finished:
            sessionStatus = .finished
            endedAt = book.dateFinished ?? startedAt
            progress = 1
        case .didNotFinish:
            sessionStatus = .didNotFinish
            endedAt = book.dateFinished ?? startedAt
            progress = 0
        }
        return ReadingSession(
            startedAt: startedAt,
            endedAt: endedAt,
            status: sessionStatus,
            progress: progress,
            book: book
        )
    }
}

@MainActor
enum AssetInspectionMaintenance {
    struct ChunkResult: Equatable {
        let visited: Int
        let inspected: Int
        let failed: Int
        let missing: Int
        let fileOpenCount: Int
        let hasMore: Bool
    }

    static func processChunk(
        context: ModelContext,
        mutations: CatalogMutationService,
        offset: Int,
        limit: Int,
        inspect: @escaping @Sendable (AssetInspectionInput) async -> AssetInspectionProposal? =
            AssetInspectionPipeline.inspect
    ) async throws -> ChunkResult {
        guard !context.hasChanges else { throw MaintenanceSchedulerError.dirtyContext }
        let signposter = Log.persistenceSignposter
        let interval = signposter.beginInterval(
            "AssetInspectionChunk",
            id: signposter.makeSignpostID()
        )
        var measuredVisited = 0
        var measuredInspected = 0
        var measuredOpens = 0
        var measuredBytes: Int64 = 0
        defer {
            signposter.endInterval(
                "AssetInspectionChunk",
                interval,
                "visited \(measuredVisited) inspected \(measuredInspected) opened \(measuredOpens) sourceBytes \(measuredBytes)"
            )
        }
        var descriptor = FetchDescriptor<BookAsset>(
            sortBy: [SortDescriptor(\BookAsset.uuid)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\BookAsset.book]
        descriptor.fetchOffset = max(0, offset)
        descriptor.fetchLimit = max(1, limit)
        let assets = try context.fetch(descriptor)
        let inputs = assets.compactMap { asset in
            asset.book.flatMap { AssetInspectionInput(asset: asset, book: $0) }
        }.filter { !$0.requirements.isEmpty }

        var proposals: [AssetInspectionProposal] = []
        for start in stride(from: 0, to: inputs.count, by: 2) {
            try Task.checkCancellation()
            let pair = Array(inputs[start ..< min(start + 2, inputs.count)])
            let completed = await withTaskGroup(
                of: AssetInspectionProposal?.self,
                returning: [AssetInspectionProposal].self
            ) { group in
                for input in pair {
                    group.addTask { await inspect(input) }
                }
                var output: [AssetInspectionProposal] = []
                for await proposal in group {
                    if let proposal { output.append(proposal) }
                }
                return output
            }
            proposals.append(contentsOf: completed)
        }
        try Task.checkCancellation()

        var valid: [(AssetInspectionProposal, Book, BookAsset)] = []
        for proposal in proposals {
            guard proposal.sourceIsCurrent,
                  let book = try? mutations.book(id: proposal.input.bookID),
                  let asset = book.assets.first(where: { $0.uuid == proposal.input.assetID }),
                  proposal.input.matches(book: book, asset: asset) else {
                continue
            }
            valid.append((proposal, book, asset))
        }

        if !valid.isEmpty {
            let bookPreimages = valid.map { CatalogBookMetadataPreimage($0.1) }
            let assetPreimages = valid.map { CatalogBookAssetPreimage($0.2) }
            let bookIDs = Set(valid.map { $0.0.input.bookID })
            try mutations.commit(
                .applyAnalysisBatch(
                    bookIDs: Array(bookIDs),
                    kind: .assetInspection(assetID: valid[0].0.input.assetID)
                ),
                affectedBookIDs: bookIDs,
                revertingOnFailure: {
                    bookPreimages.forEach { $0.restore() }
                    assetPreimages.forEach { $0.restore() }
                }
            ) {
                for (proposal, _, _) in valid {
                    let input = proposal.input
                    let output = proposal.output
                    let book = try mutations.book(id: input.bookID)
                    guard let asset = book.assets.first(where: { $0.uuid == input.assetID }),
                          input.sourceMatches(book: book, asset: asset),
                          proposal.sourceIsCurrent else {
                        throw CatalogMutationError.staleAnalysis
                    }
                    if input.requirements.size, output.sizeBytes > 0 {
                        if asset.sizeBytes <= 0 { asset.sizeBytes = output.sizeBytes }
                        if input.isPrimary, book.fileSizeBytes <= 0 {
                            book.fileSizeBytes = output.sizeBytes
                        }
                    }
                    if input.requirements.hash,
                       asset.contentHash == nil,
                       let hash = output.contentHash {
                        asset.contentHash = hash
                    }
                    if input.requirements.validation,
                       asset.validationStatus == nil,
                       let validation = output.validation {
                        asset.validationStatus = validation
                    }
                    if input.requirements.drm,
                       input.isPrimary,
                       book.drmProtected == nil,
                       let drmProtected = output.drmProtected {
                        book.drmProtected = drmProtected
                    }
                }
            }
        }

        let missing = valid.count { $0.0.output.validation == .missing }
        let opens = proposals.reduce(0) { $0 + $1.output.fileOpenCount }
        measuredVisited = assets.count
        measuredInspected = valid.count
        measuredOpens = opens
        measuredBytes = proposals.reduce(Int64(0)) {
            $0 + max(0, $1.output.sizeBytes)
        }
        return ChunkResult(
            visited: assets.count,
            inspected: valid.count,
            failed: inputs.count - valid.count,
            missing: missing,
            fileOpenCount: opens,
            hasMore: assets.count == max(1, limit)
        )
    }
}

enum MaintenanceSchedulerError: Error, LocalizedError {
    case dirtyContext
    case legacyMigration

    var errorDescription: String? {
        switch self {
        case .dirtyContext:
            "The library has pending edits."
        case .legacyMigration:
            "The legacy library migration needs attention."
        }
    }
}

@MainActor
@Observable
final class MaintenanceScheduler {
    private static let catalogStructureVersion = 4
    private static let catalogCleanupVersion = 1
    private static let assetInspectionVersion = 1
    private static let metadataExtractionVersion = 1
    private static let chunkSize = 64

    private(set) var phase: MaintenancePhase = .idle

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let mutations: CatalogMutationService
    @ObservationIgnored private let managedFiles: ManagedFileCoordinator
    @ObservationIgnored private let importer: ImportService
    @ObservationIgnored private let editions: CatalogReconciliationService
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let checkpoints: MaintenanceCheckpointStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pauseRequested = false
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private var runTask: Task<Void, Never>?

    init(
        context: ModelContext,
        mutations: CatalogMutationService,
        managedFiles: ManagedFileCoordinator,
        importer: ImportService,
        editions: CatalogReconciliationService,
        settings: AppSettings,
        toasts: ToastCenter,
        defaults: UserDefaults = .standard,
        restoreApplied: Bool = PersistenceController.restoreAppliedAtLaunch
    ) {
        self.context = context
        self.mutations = mutations
        self.managedFiles = managedFiles
        self.importer = importer
        self.editions = editions
        self.settings = settings
        self.toasts = toasts
        self.defaults = defaults
        checkpoints = MaintenanceCheckpointStore(defaults: defaults)
        if restoreApplied {
            checkpoints.resetAll()
            LegacyLibraryMigrator.resetCheckpoint(defaults: defaults)
            defaults.removeObject(forKey: "migration.catalog-assets-reading-history.v2")
        }
    }

    var isActive: Bool {
        switch phase {
        case .running, .paused: true
        default: false
        }
    }

    func start() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        guard runTask == nil else { return }
        switch phase {
        case .idle, .failed:
            break
        case .running, .paused, .completed:
            return
        }
        runGeneration &+= 1
        let generation = runGeneration
        runTask = Task { [weak self] in
            await self?.run(generation: generation)
        }
    }

    private func run(generation: Int) async {
        let signposter = Log.persistenceSignposter
        let interval = signposter.beginInterval(
            "DeferredStartupMaintenance",
            id: signposter.makeSignpostID()
        )
        defer {
            signposter.endInterval("DeferredStartupMaintenance", interval)
            if generation == runGeneration {
                runTask = nil
            }
        }

        do {
            try await Task.sleep(for: .milliseconds(750))
            try await runLegacyMigration()
            try await runCatalogStructureBackfill()
            try await runCatalogCleanup()
            try await runAssetInspection()
            try await runMetadataExtraction()
            try await runEditionDiscovery()
            try await runAutomaticBackup()
            guard !Task.isCancelled, generation == runGeneration else { return }
            phase = .completed
        } catch is CancellationError {
            guard generation == runGeneration else { return }
            phase = .idle
        } catch {
            guard generation == runGeneration else { return }
            let job = currentProgress?.job ?? .catalogStructure
            phase = .failed(job, error.localizedDescription)
        }
    }

    func pause() {
        pauseRequested = true
    }

    func resume() {
        pauseRequested = false
    }

    func cancel() {
        runGeneration &+= 1
        runTask?.cancel()
        runTask = nil
        phase = .idle
    }

    private var currentProgress: MaintenanceProgress? {
        switch phase {
        case .running(let progress), .paused(let progress, _):
            progress
        default:
            nil
        }
    }

    private func runLegacyMigration() async throws {
        let legacyFile = AppPaths.appSupportDirectory.appending(path: "library.json")
        let hadLegacyCatalog = FileManager.default.fileExists(
            atPath: legacyFile.path(percentEncoded: false)
        )
        let progress = MaintenanceProgress(job: .legacyLibrary, completed: 0, total: 1)
        try await waitUntilRunnable(progress)
        let result = await LegacyLibraryMigrator.migrateIncrementally(
            context: context,
            mutations: mutations,
            managedFiles: managedFiles,
            defaults: defaults
        ) { [weak self] completed, total in
            self?.phase = .running(MaintenanceProgress(
                job: .legacyLibrary,
                completed: completed,
                total: max(total, 1)
            ))
        }
        switch result {
        case .completed:
            if hadLegacyCatalog {
                checkpoints.reset(
                    .catalogStructure,
                    version: Self.catalogStructureVersion
                )
                checkpoints.reset(
                    .assetInspection,
                    version: Self.assetInspectionVersion
                )
                checkpoints.reset(
                    .catalogCleanup,
                    version: Self.catalogCleanupVersion
                )
                checkpoints.reset(
                    .metadataExtraction,
                    version: Self.metadataExtractionVersion
                )
                defaults.removeObject(
                    forKey: "migration.catalog-assets-reading-history.v2"
                )
            }
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw MaintenanceSchedulerError.legacyMigration
        }
    }

    private func runCatalogStructureBackfill() async throws {
        let job = MaintenanceJob.catalogStructure
        let version = Self.catalogStructureVersion
        if defaults.bool(forKey: "migration.catalog-assets-reading-history.v2") {
            checkpoints.markCompleted(job, version: version)
        }
        guard !checkpoints.isCompleted(job, version: version) else { return }
        let total = try context.fetchCount(FetchDescriptor<Book>())
        var offset = min(checkpoints.offset(for: job, version: version), total)
        while offset < total {
            let progress = MaintenanceProgress(job: job, completed: offset, total: total)
            try await waitUntilRunnable(progress)
            let result = try CatalogStructureBackfill.processChunk(
                context: context,
                offset: offset,
                limit: Self.chunkSize
            )
            offset += result.visited
            checkpoints.setOffset(offset, for: job, version: version)
            phase = .running(MaintenanceProgress(job: job, completed: offset, total: total))
            guard result.visited > 0 else { break }
            await Task.yield()
        }
        checkpoints.markCompleted(job, version: version)
        defaults.set(true, forKey: "migration.catalog-assets-reading-history.v2")
    }

    private func runCatalogCleanup() async throws {
        let job = MaintenanceJob.catalogCleanup
        let version = Self.catalogCleanupVersion
        guard !checkpoints.isCompleted(job, version: version) else { return }
        let total = try context.fetchCount(FetchDescriptor<Work>())
        var offset = min(checkpoints.offset(for: job, version: version), total)
        var deleted = 0
        while true {
            let remainingCount = try context.fetchCount(FetchDescriptor<Work>())
            guard offset < remainingCount else { break }
            let completed = min(total, offset + deleted)
            let progress = MaintenanceProgress(job: job, completed: completed, total: total)
            try await waitUntilRunnable(progress)
            let result = try CatalogStructureBackfill.pruneOrphanWorksChunk(
                context: context,
                offset: offset,
                limit: Self.chunkSize
            )
            deleted += result.deleted
            offset = result.nextOffset
            checkpoints.setOffset(offset, for: job, version: version)
            phase = .running(MaintenanceProgress(
                job: job,
                completed: min(total, offset + deleted),
                total: total
            ))
            guard result.visited > 0 else { break }
            await Task.yield()
        }
        checkpoints.markCompleted(job, version: version)
    }

    private func runAssetInspection() async throws {
        let job = MaintenanceJob.assetInspection
        let version = Self.assetInspectionVersion
        guard !checkpoints.isCompleted(job, version: version) else { return }
        let total = try context.fetchCount(FetchDescriptor<BookAsset>())
        var offset = min(checkpoints.offset(for: job, version: version), total)
        var missing = 0
        var failed = 0
        while offset < total {
            let progress = MaintenanceProgress(job: job, completed: offset, total: total)
            try await waitUntilRunnable(progress)
            let result = try await AssetInspectionMaintenance.processChunk(
                context: context,
                mutations: mutations,
                offset: offset,
                limit: Self.chunkSize
            )
            missing += result.missing
            failed += result.failed
            offset += result.visited
            checkpoints.setOffset(offset, for: job, version: version)
            phase = .running(MaintenanceProgress(job: job, completed: offset, total: total))
            guard result.visited > 0 else { break }
            await Task.yield()
        }
        if failed == 0 {
            checkpoints.markCompleted(job, version: version)
        } else {
            checkpoints.reset(job, version: version)
        }
        if missing > 0 {
            toasts.error(String(localized: "Some book files are missing (\(missing))."))
        }
    }

    private func runMetadataExtraction() async throws {
        let job = MaintenanceJob.metadataExtraction
        let version = Self.metadataExtractionVersion
        guard !checkpoints.isCompleted(job, version: version) else { return }
        let total = try context.fetchCount(FetchDescriptor<Book>())
        var offset = min(checkpoints.offset(for: job, version: version), total)
        while offset < total {
            let progress = MaintenanceProgress(job: job, completed: offset, total: total)
            try await waitUntilRunnable(progress)
            var descriptor = FetchDescriptor<Book>(
                sortBy: [
                    SortDescriptor(\Book.dateAdded),
                    SortDescriptor(\Book.uuid),
                ]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = Self.chunkSize
            let books = try context.fetch(descriptor)
            let candidates = books.filter {
                $0.title == nil && $0.hasCatalogDigitalFile
            }.map(\.uuid)
            await importer.rescanMissingMetadata(bookIDs: candidates)
            offset += books.count
            checkpoints.setOffset(offset, for: job, version: version)
            phase = .running(MaintenanceProgress(job: job, completed: offset, total: total))
            guard !books.isEmpty else { break }
            await Task.yield()
        }
        checkpoints.markCompleted(job, version: version)
    }

    private func runEditionDiscovery() async throws {
        let progress = MaintenanceProgress(job: .editionDiscovery, completed: 0, total: 1)
        try await waitUntilRunnable(progress)
        await editions.scanLibrary()
        try Task.checkCancellation()
        phase = .running(MaintenanceProgress(
            job: .editionDiscovery,
            completed: 1,
            total: 1
        ))
    }

    private func runAutomaticBackup() async throws {
        let progress = MaintenanceProgress(job: .automaticBackup, completed: 0, total: 1)
        try await waitUntilRunnable(progress)
        guard settings.autoBackupEnabled,
              let path = settings.backupFolderPath else { return }
        let due = settings.lastBackupAt.map {
            Date.now.timeIntervalSince($0) > 24 * 3600
        } ?? true
        guard due else { return }
        do {
            _ = try await managedFiles.createBackup(
                storeURL: PersistenceController.storeURL,
                to: URL(fileURLWithPath: path)
            )
            settings.lastBackupAt = .now
            toasts.info(String(localized: "Library backed up."))
        } catch {
            toasts.error(String(localized: "Backup failed."))
        }
        phase = .running(MaintenanceProgress(
            job: .automaticBackup,
            completed: 1,
            total: 1
        ))
    }

    private func waitUntilRunnable(_ progress: MaintenanceProgress) async throws {
        while true {
            try Task.checkCancellation()
            if pauseRequested {
                phase = .paused(progress, .requested)
            } else if ProcessInfo.processInfo.isLowPowerModeEnabled {
                phase = .paused(progress, .lowPower)
            } else {
                phase = .running(progress)
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
    }
}
