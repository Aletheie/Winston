import CryptoKit
import Foundation
import OSLog

nonisolated enum ManagedFileIntent: String, Codable, Sendable {
    case importBook
    case replaceBookFile
    case conversionOutput
    case deleteBook
    case deleteBookFile
    case calibreImport
    case legacyMigration
    case coverUpdate
    case restore
}

nonisolated enum ManagedFileKind: String, Codable, Sendable {
    case book
    case cover
}

nonisolated enum ManagedFileCleanupDisposition: String, Codable, Sendable {
    case delete
    case trash
}

nonisolated struct ManagedFileReference: Codable, Sendable, Equatable, Hashable {
    let kind: ManagedFileKind
    let relativeName: String

    static func book(_ relativeName: String) -> ManagedFileReference {
        ManagedFileReference(kind: .book, relativeName: relativeName)
    }

    static func cover(bookID: UUID) -> ManagedFileReference {
        ManagedFileReference(kind: .cover, relativeName: "\(bookID.uuidString).jpg")
    }
}

/// Physical generation of one managed file. The catalog identity and content
/// digest alone are insufficient: an atomic replacement can install a different
/// inode with the same name (and even the same bytes) while a cleanup is queued.
nonisolated struct ManagedFileGeneration: Codable, Sendable, Equatable, Hashable {
    let volumeNumber: UInt64?
    let fileNumber: UInt64?
    let byteCount: Int64
    let modificationDate: Date?
    let sha256: String
}

/// Immutable evidence captured by ManagedFileCoordinator before a catalog
/// mutation. A nil generation deliberately records that the path was missing;
/// a file appearing later is therefore a conflict, not something to delete.
nonisolated struct ManagedFileIdentitySnapshot: Codable, Sendable, Equatable, Hashable {
    let reference: ManagedFileReference
    let generation: ManagedFileGeneration?

    var exists: Bool { generation != nil }
}

nonisolated enum ManagedBookDestinationIntent: Sendable, Equatable {
    case newAsset(assetID: UUID)
    case replacement(assetID: UUID, previous: ManagedFileIdentitySnapshot)
}

nonisolated struct ManagedFileSource: Sendable {
    let kind: ManagedFileKind
    let sourceURL: URL?
    let data: Data?
    let finalRelativeName: String
    let replacesExisting: Bool
    let expectedDestinationIdentity: ManagedFileIdentitySnapshot?

    static func book(sourceURL: URL, fileID: UUID = UUID()) throws -> ManagedFileSource {
        try book(sourceURL: sourceURL, destination: .newAsset(assetID: fileID))
    }

    static func book(
        sourceURL: URL,
        destination: ManagedBookDestinationIntent
    ) throws -> ManagedFileSource {
        let ext = sourceURL.pathExtension.lowercased()
        let fileID: UUID
        switch destination {
        case .newAsset(let assetID):
            fileID = assetID
        case .replacement(let assetID, let previous):
            let preferred = ext.isEmpty ? assetID.uuidString : "\(assetID.uuidString).\(ext)"
            // Never stage a replacement over the generation being retired.
            // Publishing a new leaf first keeps rollback and crash recovery lossless.
            fileID = preferred == previous.reference.relativeName ? UUID() : assetID
        }
        let name = ext.isEmpty ? fileID.uuidString : "\(fileID.uuidString).\(ext)"
        guard ManagedLeafName(rawValue: name) != nil else {
            throw ManagedFileCoordinatorError.unsafeRelativeName(name)
        }
        return ManagedFileSource(
            kind: .book,
            sourceURL: sourceURL,
            data: nil,
            finalRelativeName: name,
            replacesExisting: false,
            expectedDestinationIdentity: nil
        )
    }

    static func cover(
        data: Data,
        bookID: UUID,
        replacing identity: ManagedFileIdentitySnapshot? = nil
    ) -> ManagedFileSource {
        ManagedFileSource(
            kind: .cover,
            sourceURL: nil,
            data: data,
            finalRelativeName: "\(bookID.uuidString).jpg",
            replacesExisting: identity != nil,
            expectedDestinationIdentity: identity
        )
    }
}

nonisolated struct ManagedFileCleanup: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let kind: ManagedFileKind
    let relativeName: String
    let disposition: ManagedFileCleanupDisposition
    /// Exact physical generation authorized for deletion. Optional only for
    /// decoding journals written before file generations were introduced.
    let expectedIdentity: ManagedFileIdentitySnapshot?
    /// When set, cleanup is permitted only while this file still has the
    /// expected digest. An optional retained equivalent adds the stronger
    /// reconciliation invariant that another managed file has the same bytes.
    /// This prevents stale journals from deleting a newer file generation.
    let expectedSHA256: String?
    let retainedEquivalentRelativeName: String?

    private init(
        id: UUID = UUID(),
        kind: ManagedFileKind,
        relativeName: String,
        disposition: ManagedFileCleanupDisposition = .delete,
        expectedIdentity: ManagedFileIdentitySnapshot? = nil,
        expectedSHA256: String? = nil,
        retainedEquivalentRelativeName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.relativeName = relativeName
        self.disposition = disposition
        self.expectedIdentity = expectedIdentity
        self.expectedSHA256 = expectedSHA256
        self.retainedEquivalentRelativeName = retainedEquivalentRelativeName
    }

    static func file(
        _ identity: ManagedFileIdentitySnapshot,
        disposition: ManagedFileCleanupDisposition = .delete,
        retainedEquivalentFileName: String? = nil
    ) -> ManagedFileCleanup {
        ManagedFileCleanup(
            kind: identity.reference.kind,
            relativeName: identity.reference.relativeName,
            disposition: disposition,
            expectedIdentity: identity,
            expectedSHA256: identity.generation?.sha256,
            retainedEquivalentRelativeName: retainedEquivalentFileName
        )
    }

}

/// Conditions that must be true in the durable catalog before staged files are
/// published or retired files are removed.
nonisolated struct ManagedFileRequirement: Codable, Sendable, Equatable {
    var presentBookIDs: Set<UUID>
    var absentBookIDs: Set<UUID>
    var referencedBookFileNames: Set<String>
    var unreferencedBookFileNames: Set<String>
    var coverVersions: [UUID: Int]

    init(
        presentBookIDs: Set<UUID> = [],
        absentBookIDs: Set<UUID> = [],
        referencedBookFileNames: Set<String> = [],
        unreferencedBookFileNames: Set<String> = [],
        coverVersions: [UUID: Int] = [:]
    ) {
        self.presentBookIDs = presentBookIDs
        self.absentBookIDs = absentBookIDs
        self.referencedBookFileNames = referencedBookFileNames
        self.unreferencedBookFileNames = unreferencedBookFileNames
        self.coverVersions = coverVersions
    }
}

nonisolated struct ManagedFileCatalogSnapshot: Sendable, Equatable {
    let presentBookIDs: Set<UUID>
    let referencedBookFileNames: Set<String>
    let coverVersions: [UUID: Int]

    init(
        presentBookIDs: Set<UUID>,
        referencedBookFileNames: Set<String>,
        coverVersions: [UUID: Int]
    ) {
        self.presentBookIDs = presentBookIDs
        self.referencedBookFileNames = referencedBookFileNames
        self.coverVersions = coverVersions
    }

    func satisfies(_ requirement: ManagedFileRequirement) -> Bool {
        requirement.presentBookIDs.isSubset(of: presentBookIDs)
            && requirement.absentBookIDs.isDisjoint(with: presentBookIDs)
            && requirement.referencedBookFileNames.isSubset(of: referencedBookFileNames)
            && requirement.unreferencedBookFileNames.isDisjoint(with: referencedBookFileNames)
            && requirement.coverVersions.allSatisfy { coverVersions[$0.key] == $0.value }
    }
}

nonisolated struct StagedManagedFile: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let kind: ManagedFileKind
    let originalSourceURL: URL?
    let stagedURL: URL
    let finalRelativeName: String
    let sha256: String
    let byteCount: Int64
    let generation: UUID
    let physicalGeneration: ManagedFileGeneration?
    let replacesExisting: Bool?
    let expectedDestinationIdentity: ManagedFileIdentitySnapshot?
    /// Number of sequential source reads used to create this immutable
    /// generation. Optional so journals written by older versions still decode.
    let sourceReadPassCount: Int?
}

nonisolated struct ManagedFileTransaction: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let intent: ManagedFileIntent
    let createdAt: Date
    let files: [StagedManagedFile]
    let requirement: ManagedFileRequirement
    let cleanups: [ManagedFileCleanup]
}

nonisolated enum ManagedFileReconcileOutcome: Sendable, Equatable {
    case completed
    case abortedCatalogDidNotCommit
}

nonisolated struct ManagedFileRecoveryReport: Sendable, Equatable {
    var completedTransactionIDs: [UUID] = []
    var abortedTransactionIDs: [UUID] = []
    var failedTransactionIDs: [UUID] = []
    var unreadableJournalURLs: [URL] = []
    var removedOrphanStagingURLs: [URL] = []
    var failureMessages: [String] = []

    var hasPendingWork: Bool {
        !failedTransactionIDs.isEmpty
            || !unreadableJournalURLs.isEmpty
            || !failureMessages.isEmpty
    }
}

nonisolated enum ManagedFileFaultPoint: Sendable, Equatable {
    case beforeStagingWrite(relativeName: String)
    case afterStaging
    case beforeCatalogSave
    case afterCatalogSave
    case duringPublish(fileID: UUID)
    case afterPublishBeforeCheckpoint(fileID: UUID)
    case duringCleanup(cleanupID: UUID)
    case afterCleanupBeforeCheckpoint(cleanupID: UUID)
}

nonisolated enum ManagedFileCoordinatorError: Error, Equatable {
    case unsafeRelativeName(String)
    case missingStagedFile(String)
    case destinationConflict(String)
    case journalNotFound(UUID)
    case catalogRequirementMismatch(UUID)
    case cleanupContentChanged(String)
    case fileGenerationChanged(String)
    case unsupportedManagedFile(String)
    case injectedFailure(ManagedFileFaultPoint)
}

nonisolated enum ManagedFileOperationPhase: Sendable, Equatable, Hashable {
    case preparing
    case copying
    case hashing
    case publishing
    case cleaning
    case finished
}

nonisolated struct ManagedFileProgress: Sendable, Equatable {
    let transactionID: UUID
    let intent: ManagedFileIntent
    let phase: ManagedFileOperationPhase
    let completedItems: Int
    let totalItems: Int
    let completedBytes: Int64
    let totalBytes: Int64?

    static func initial(
        transactionID: UUID,
        intent: ManagedFileIntent
    ) -> ManagedFileProgress {
        ManagedFileProgress(
            transactionID: transactionID,
            intent: intent,
            phase: .preparing,
            completedItems: 0,
            totalItems: 1,
            completedBytes: 0,
            totalBytes: nil
        )
    }

    var phaseFraction: Double {
        if let totalBytes, totalBytes > 0 {
            let currentItemFraction = min(1, max(0, Double(completedBytes) / Double(totalBytes)))
            guard totalItems > 0 else { return currentItemFraction }
            return min(
                1,
                max(0, (Double(completedItems) + currentItemFraction) / Double(totalItems))
            )
        }
        guard totalItems > 0 else { return phase == .finished ? 1 : 0 }
        return min(1, max(0, Double(completedItems) / Double(totalItems)))
    }

    /// Coarse end-to-end progress for UI. The byte-accurate part covers the
    /// potentially long copy; commit, publication and cleanup use item counts.
    var overallFraction: Double {
        switch phase {
        case .preparing:
            0.02
        case .copying:
            0.02 + 0.67 * stagingFraction(baseWeight: 0, currentWeight: 0.8)
        case .hashing:
            0.02 + 0.67 * stagingFraction(baseWeight: 0.8, currentWeight: 0.2)
        case .publishing:
            0.70 + 0.15 * phaseFraction
        case .cleaning:
            0.85 + 0.14 * phaseFraction
        case .finished:
            1
        }
    }

    private func stagingFraction(baseWeight: Double, currentWeight: Double) -> Double {
        guard totalItems > 0 else { return 0 }
        let byteFraction: Double
        if let totalBytes, totalBytes > 0 {
            byteFraction = min(1, max(0, Double(completedBytes) / Double(totalBytes)))
        } else {
            byteFraction = 0
        }
        let completed = Double(completedItems)
            + baseWeight
            + currentWeight * byteFraction
        return min(1, max(0, completed / Double(totalItems)))
    }
}

typealias ManagedFileProgressHandler = @Sendable (ManagedFileProgress) -> Void

actor ManagedFileCoordinator {
    typealias FaultInjector = @Sendable (ManagedFileFaultPoint) throws -> Void

    static let shared = ManagedFileCoordinator()

    private struct Journal: Codable {
        let transaction: ManagedFileTransaction
        var catalogCommitConfirmed: Bool?
        var publishedFileIDs: Set<UUID>
        var completedCleanupIDs: Set<UUID>
    }

    // Nil means "follow AppPaths". That keeps the process-wide coordinator
    // compatible with TestLibrary's serialized root swap while explicit URLs
    // still give fault-injection tests a completely isolated filesystem.
    private let configuredBooksDirectory: URL?
    private let configuredCoversDirectory: URL?
    private let configuredStateDirectory: URL?
    private let fileManager: FileManager
    private let faultInjector: FaultInjector
    private let executor = DispatchQueueSerialExecutor(label: "cz.annajung.Winston.managed-files")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    private var booksDirectory: URL {
        configuredBooksDirectory ?? AppPaths.booksDirectory
    }

    private var coversDirectory: URL {
        configuredCoversDirectory ?? AppPaths.coversDirectory
    }

    private var stateDirectory: URL {
        configuredStateDirectory ?? AppPaths.managedFilesDirectory
    }

    private var stagingDirectory: URL {
        stateDirectory.appending(path: "Staging", directoryHint: .isDirectory)
    }

    private var journalDirectory: URL {
        stateDirectory.appending(path: "Journal", directoryHint: .isDirectory)
    }

    init(
        booksDirectory: URL? = nil,
        coversDirectory: URL? = nil,
        stateDirectory: URL? = nil,
        fileManager: FileManager = .default,
        faultInjector: @escaping FaultInjector = { _ in }
    ) {
        self.configuredBooksDirectory = booksDirectory
        self.configuredCoversDirectory = coversDirectory
        self.configuredStateDirectory = stateDirectory
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func captureIdentity(
        of reference: ManagedFileReference
    ) throws -> ManagedFileIdentitySnapshot {
        try ensureDirectories()
        return try captureIdentityWithoutCreatingDirectories(of: reference)
    }

    func captureIdentities(
        of references: [ManagedFileReference]
    ) throws -> [ManagedFileIdentitySnapshot] {
        try ensureDirectories()
        var identities: [ManagedFileIdentitySnapshot] = []
        identities.reserveCapacity(references.count)
        for reference in references {
            try Task.checkCancellation()
            identities.append(try captureIdentityWithoutCreatingDirectories(of: reference))
        }
        return identities
    }

    func stage(
        intent: ManagedFileIntent,
        sources: [ManagedFileSource],
        requirement: ManagedFileRequirement,
        cleanups: [ManagedFileCleanup] = [],
        operationID: UUID? = nil,
        progress: ManagedFileProgressHandler? = nil
    ) throws -> ManagedFileTransaction {
        let signposter = Log.persistenceSignposter
        let interval = signposter.beginInterval(
            "ManagedFileStage",
            id: signposter.makeSignpostID(),
            "items=\(sources.count)"
        )
        defer { signposter.endInterval("ManagedFileStage", interval) }

        try Task.checkCancellation()
        try ensureDirectories()
        try validate(requirement: requirement, cleanups: cleanups)

        let transactionID = operationID ?? UUID()
        progress?(ManagedFileProgress.initial(transactionID: transactionID, intent: intent))
        let transactionStaging = stagingDirectory.appending(
            path: transactionID.uuidString,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: transactionStaging, withIntermediateDirectories: true)

        var stagedFiles: [StagedManagedFile] = []
        do {
            for (index, source) in sources.enumerated() {
                try Task.checkCancellation()
                let staged = try stage(
                    source,
                    intent: intent,
                    transactionID: transactionID,
                    transactionStaging: transactionStaging,
                    itemIndex: index,
                    totalItems: sources.count,
                    progress: progress
                )
                stagedFiles.append(staged)
            }
            let transaction = ManagedFileTransaction(
                id: transactionID,
                intent: intent,
                createdAt: Date(),
                files: stagedFiles,
                requirement: requirement,
                cleanups: cleanups
            )
            try write(Journal(
                transaction: transaction,
                catalogCommitConfirmed: false,
                publishedFileIDs: [],
                completedCleanupIDs: []
            ))
            try faultInjector(.afterStaging)
            return transaction
        } catch {
            // Once the journal exists, recovery owns cleanup. Before that point the
            // staging directory has no durable meaning and can be removed safely.
            if !fileManager.fileExists(atPath: journalURL(for: transactionID).path(percentEncoded: false)) {
                try? fileManager.removeItem(at: transactionStaging)
            }
            throw error
        }
    }

    func prepareCleanup(
        intent: ManagedFileIntent,
        requirement: ManagedFileRequirement,
        cleanups: [ManagedFileCleanup],
        operationID: UUID? = nil,
        progress: ManagedFileProgressHandler? = nil
    ) throws -> ManagedFileTransaction {
        try stage(
            intent: intent,
            sources: [],
            requirement: requirement,
            cleanups: cleanups,
            operationID: operationID,
            progress: progress
        )
    }

    func willCommitCatalog(_ transaction: ManagedFileTransaction) throws {
        guard fileManager.fileExists(atPath: journalURL(for: transaction.id).path(percentEncoded: false)) else {
            throw ManagedFileCoordinatorError.journalNotFound(transaction.id)
        }
        try faultInjector(.beforeCatalogSave)
        for file in transaction.files {
            try verifyStagedGeneration(file)
            try verifyPublishDestination(for: file)
        }
        for cleanup in transaction.cleanups {
            try verifyContentGuard(for: cleanup, allowMissingTarget: false)
        }
    }

    func catalogDidCommit(_ transaction: ManagedFileTransaction) throws {
        var journal = try readJournal(id: transaction.id)
        journal.catalogCommitConfirmed = true
        try write(journal)
        try faultInjector(.afterCatalogSave)
    }

    func abort(_ transaction: ManagedFileTransaction) {
        removeTransactionFiles(transaction.id)
    }

    func reconcile(
        _ transaction: ManagedFileTransaction,
        against snapshot: ManagedFileCatalogSnapshot,
        progress: ManagedFileProgressHandler? = nil
    ) throws -> ManagedFileReconcileOutcome {
        var journal = try readJournal(id: transaction.id)
        guard snapshot.satisfies(transaction.requirement) else {
            if journal.catalogCommitConfirmed == true {
                throw ManagedFileCoordinatorError.catalogRequirementMismatch(transaction.id)
            }
            removeTransactionFiles(transaction.id)
            return .abortedCatalogDidNotCommit
        }
        guard journal.transaction == transaction else {
            throw ManagedFileCoordinatorError.destinationConflict(transaction.id.uuidString)
        }

        let unpublished = transaction.files.filter { !journal.publishedFileIDs.contains($0.id) }
        if !unpublished.isEmpty {
            let signposter = Log.persistenceSignposter
            let interval = signposter.beginInterval(
                "ManagedFilePublish",
                id: signposter.makeSignpostID(),
                "items=\(unpublished.count)"
            )
            defer { signposter.endInterval("ManagedFilePublish", interval) }
            for (index, file) in unpublished.enumerated() {
                try Task.checkCancellation()
                if shouldReportProgress(index: index, total: unpublished.count) {
                    progress?(ManagedFileProgress(
                        transactionID: transaction.id,
                        intent: transaction.intent,
                        phase: .publishing,
                        completedItems: index,
                        totalItems: unpublished.count,
                        completedBytes: 0,
                        totalBytes: nil
                    ))
                }
                try faultInjector(.duringPublish(fileID: file.id))
                try publish(file)
                try faultInjector(.afterPublishBeforeCheckpoint(fileID: file.id))
                journal.publishedFileIDs.insert(file.id)
                try write(journal)
            }
        }

        let unfinishedCleanups = transaction.cleanups.filter {
            !journal.completedCleanupIDs.contains($0.id)
        }
        if !unfinishedCleanups.isEmpty {
            let signposter = Log.persistenceSignposter
            let interval = signposter.beginInterval(
                "ManagedFileCleanup",
                id: signposter.makeSignpostID(),
                "items=\(unfinishedCleanups.count)"
            )
            defer { signposter.endInterval("ManagedFileCleanup", interval) }
            for (index, cleanup) in unfinishedCleanups.enumerated() {
                try Task.checkCancellation()
                if shouldReportProgress(index: index, total: unfinishedCleanups.count) {
                    progress?(ManagedFileProgress(
                        transactionID: transaction.id,
                        intent: transaction.intent,
                        phase: .cleaning,
                        completedItems: index,
                        totalItems: unfinishedCleanups.count,
                        completedBytes: 0,
                        totalBytes: nil
                    ))
                }
                try faultInjector(.duringCleanup(cleanupID: cleanup.id))
                try perform(cleanup, snapshot: snapshot)
                try faultInjector(.afterCleanupBeforeCheckpoint(cleanupID: cleanup.id))
                journal.completedCleanupIDs.insert(cleanup.id)
                try write(journal)
            }
        }

        progress?(ManagedFileProgress(
            transactionID: transaction.id,
            intent: transaction.intent,
            phase: .finished,
            completedItems: 1,
            totalItems: 1,
            completedBytes: 0,
            totalBytes: nil
        ))
        removeTransactionFiles(transaction.id)
        return .completed
    }

    func recover(against snapshot: ManagedFileCatalogSnapshot) -> ManagedFileRecoveryReport {
        var report = ManagedFileRecoveryReport()
        do {
            try ensureDirectories()
            let journalURLs = try fileManager.contentsOfDirectory(
                at: journalDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
            let journalIDs = Set(journalURLs.compactMap {
                UUID(uuidString: $0.deletingPathExtension().lastPathComponent)
            })
            report.removedOrphanStagingURLs = removeOrphanedStagingDirectories(
                retaining: journalIDs
            )

            for url in journalURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let journal: Journal
                do {
                    journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
                } catch {
                    report.unreadableJournalURLs.append(url)
                    report.failureMessages.append(error.localizedDescription)
                    continue
                }
                do {
                    switch try reconcile(journal.transaction, against: snapshot) {
                    case .completed:
                        report.completedTransactionIDs.append(journal.transaction.id)
                    case .abortedCatalogDidNotCommit:
                        report.abortedTransactionIDs.append(journal.transaction.id)
                    }
                } catch {
                    report.failedTransactionIDs.append(journal.transaction.id)
                    Log.persistence.error(
                        "Managed file recovery failed for \(journal.transaction.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        } catch {
            report.failureMessages.append(error.localizedDescription)
            Log.persistence.error("Managed file recovery scan failed: \(error.localizedDescription, privacy: .public)")
        }
        return report
    }

    func pendingTransactions() -> [ManagedFileTransaction] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: journalDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let journal = try? JSONDecoder().decode(Journal.self, from: data) else { return nil }
            return journal.transaction
        }
    }

    func createBackup(
        storeURL: URL,
        to folder: URL,
        keepLast: Int = 5
    ) throws -> URL {
        try LibraryBackup.backup(
            storeURL: storeURL,
            coversDirectory: coversDirectory,
            to: folder,
            keepLast: keepLast,
            booksDirectory: booksDirectory,
            managedFilesDirectory: stateDirectory
        )
    }

    /// Removes an ephemeral artifact produced by a trusted in-process worker.
    /// Keeping this on the managed-file executor prevents conversion teardown
    /// from synchronously touching the filesystem on MainActor.
    func removeTemporaryItem(at url: URL) {
        let signposter = Log.persistenceSignposter
        let interval = signposter.beginInterval(
            "ManagedFileTemporaryCleanup",
            id: signposter.makeSignpostID()
        )
        defer { signposter.endInterval("ManagedFileTemporaryCleanup", interval) }
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Log.persistence.error(
                "Removing temporary managed-file artifact failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func stage(
        _ source: ManagedFileSource,
        intent: ManagedFileIntent,
        transactionID: UUID,
        transactionStaging: URL,
        itemIndex: Int,
        totalItems: Int,
        progress: ManagedFileProgressHandler?
    ) throws -> StagedManagedFile {
        guard ManagedLeafName(rawValue: source.finalRelativeName) != nil else {
            throw ManagedFileCoordinatorError.unsafeRelativeName(source.finalRelativeName)
        }
        let finalExtension = URL(filePath: source.finalRelativeName).pathExtension
        let stagedLeaf = finalExtension.isEmpty
            ? "\(UUID().uuidString).payload"
            : "\(UUID().uuidString).\(finalExtension)"
        let stagedURL = transactionStaging.appending(path: stagedLeaf)
        try faultInjector(.beforeStagingWrite(relativeName: source.finalRelativeName))
        let byteCount: Int64
        let digest: String
        let sourceReadPassCount: Int
        switch (source.sourceURL, source.data) {
        case (.some(let sourceURL), nil):
            if source.kind == .book,
               let portableHTML = try HTMLAssetInliner.portableData(for: sourceURL) {
                try Task.checkCancellation()
                progress?(ManagedFileProgress(
                    transactionID: transactionID,
                    intent: intent,
                    phase: .copying,
                    completedItems: itemIndex,
                    totalItems: totalItems,
                    completedBytes: 0,
                    totalBytes: Int64(portableHTML.count)
                ))
                try portableHTML.write(to: stagedURL, options: .atomic)
                progress?(ManagedFileProgress(
                    transactionID: transactionID,
                    intent: intent,
                    phase: .copying,
                    completedItems: itemIndex,
                    totalItems: totalItems,
                    completedBytes: Int64(portableHTML.count),
                    totalBytes: Int64(portableHTML.count)
                ))
                byteCount = Int64(portableHTML.count)
                digest = try hashCancellable(
                    portableHTML,
                    intent: intent,
                    transactionID: transactionID,
                    itemIndex: itemIndex,
                    totalItems: totalItems,
                    progress: progress
                )
                sourceReadPassCount = 1
            } else {
                let copy = try copyCancellable(
                    from: sourceURL,
                    to: stagedURL,
                    intent: intent,
                    transactionID: transactionID,
                    itemIndex: itemIndex,
                    totalItems: totalItems,
                    progress: progress
                )
                byteCount = copy.byteCount
                digest = copy.sha256
                sourceReadPassCount = 1
            }
        case (nil, .some(let data)):
            try Task.checkCancellation()
            progress?(ManagedFileProgress(
                transactionID: transactionID,
                intent: intent,
                phase: .copying,
                completedItems: itemIndex,
                totalItems: totalItems,
                completedBytes: 0,
                totalBytes: Int64(data.count)
            ))
            try data.write(to: stagedURL, options: .atomic)
            progress?(ManagedFileProgress(
                transactionID: transactionID,
                intent: intent,
                phase: .copying,
                completedItems: itemIndex,
                totalItems: totalItems,
                completedBytes: Int64(data.count),
                totalBytes: Int64(data.count)
            ))
            byteCount = Int64(data.count)
            digest = try hashCancellable(
                data,
                intent: intent,
                transactionID: transactionID,
                itemIndex: itemIndex,
                totalItems: totalItems,
                progress: progress
            )
            sourceReadPassCount = 0
        default:
            throw CocoaError(.fileReadUnknown)
        }

        try Task.checkCancellation()
        try makeReadOnly(stagedURL)
        let stagedMetadata = try physicalMetadata(at: stagedURL)
        return StagedManagedFile(
            id: UUID(),
            kind: source.kind,
            originalSourceURL: source.sourceURL,
            stagedURL: stagedURL,
            finalRelativeName: source.finalRelativeName,
            sha256: digest,
            byteCount: byteCount,
            generation: transactionID,
            physicalGeneration: ManagedFileGeneration(
                volumeNumber: stagedMetadata.volumeNumber,
                fileNumber: stagedMetadata.fileNumber,
                byteCount: stagedMetadata.byteCount,
                modificationDate: stagedMetadata.modificationDate,
                sha256: digest
            ),
            replacesExisting: source.replacesExisting,
            expectedDestinationIdentity: source.expectedDestinationIdentity,
            sourceReadPassCount: sourceReadPassCount
        )
    }

    private func copyCancellable(
        from sourceURL: URL,
        to destinationURL: URL,
        intent: ManagedFileIntent,
        transactionID: UUID,
        itemIndex: Int,
        totalItems: Int,
        progress: ManagedFileProgressHandler?
    ) throws -> (byteCount: Int64, sha256: String) {
        let attributes = try fileManager.attributesOfItem(
            atPath: sourceURL.path(percentEncoded: false)
        )
        let totalBytes = (attributes[.size] as? NSNumber)?.int64Value
        guard fileManager.createFile(
            atPath: destinationURL.path(percentEncoded: false),
            contents: nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer { try? destination.close() }

        var copiedBytes: Int64 = 0
        var lastReportedBytes: Int64 = 0
        var hasher = SHA256()
        progress?(ManagedFileProgress(
            transactionID: transactionID,
            intent: intent,
            phase: .copying,
            completedItems: itemIndex,
            totalItems: totalItems,
            completedBytes: 0,
            totalBytes: totalBytes
        ))
        while true {
            try Task.checkCancellation()
            guard let data = try source.read(upToCount: 1_048_576), !data.isEmpty else { break }
            try destination.write(contentsOf: data)
            hasher.update(data: data)
            copiedBytes += Int64(data.count)
            if copiedBytes - lastReportedBytes >= 4 * 1_048_576
                || totalBytes.map({ copiedBytes >= $0 }) == true {
                lastReportedBytes = copiedBytes
                progress?(ManagedFileProgress(
                    transactionID: transactionID,
                    intent: intent,
                    phase: .copying,
                    completedItems: itemIndex,
                    totalItems: totalItems,
                    completedBytes: copiedBytes,
                    totalBytes: totalBytes
                ))
            }
        }
        try Task.checkCancellation()
        if copiedBytes != lastReportedBytes {
            progress?(ManagedFileProgress(
                transactionID: transactionID,
                intent: intent,
                phase: .copying,
                completedItems: itemIndex,
                totalItems: totalItems,
                completedBytes: copiedBytes,
                totalBytes: totalBytes
            ))
        }
        progress?(ManagedFileProgress(
            transactionID: transactionID,
            intent: intent,
            phase: .hashing,
            completedItems: itemIndex,
            totalItems: totalItems,
            completedBytes: copiedBytes,
            totalBytes: copiedBytes
        ))
        let digest = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        return (copiedBytes, digest)
    }

    private func hashCancellable(
        _ data: Data,
        intent: ManagedFileIntent,
        transactionID: UUID,
        itemIndex: Int,
        totalItems: Int,
        progress: ManagedFileProgressHandler?
    ) throws -> String {
        let byteCount = Int64(data.count)
        progress?(ManagedFileProgress(
            transactionID: transactionID,
            intent: intent,
            phase: .hashing,
            completedItems: itemIndex,
            totalItems: totalItems,
            completedBytes: 0,
            totalBytes: byteCount
        ))
        var hasher = SHA256()
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let end = min(offset + 1_048_576, data.count)
            hasher.update(data: data[offset ..< end])
            offset = end
        }
        progress?(ManagedFileProgress(
            transactionID: transactionID,
            intent: intent,
            phase: .hashing,
            completedItems: itemIndex,
            totalItems: totalItems,
            completedBytes: byteCount,
            totalBytes: byteCount
        ))
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func shouldReportProgress(index: Int, total: Int) -> Bool {
        guard total > 100 else { return true }
        return index == 0 || index.isMultiple(of: max(1, total / 100))
    }

    private func publish(_ file: StagedManagedFile) throws {
        let destination = try destinationURL(kind: file.kind, relativeName: file.finalRelativeName)
        let destinationPath = destination.path(percentEncoded: false)
        let stagedURL = resolvedStagedURL(for: file)
        let stagedPath = stagedURL.path(percentEncoded: false)
        if fileManager.fileExists(atPath: destinationPath) {
            if (try? ContentHasher.sha256(of: destination)) == file.sha256 {
                if fileManager.fileExists(atPath: stagedPath) {
                    try fileManager.removeItem(at: stagedURL)
                }
                return
            }
            guard file.replacesExisting == true,
                  fileManager.fileExists(atPath: stagedPath) else {
                throw ManagedFileCoordinatorError.destinationConflict(file.finalRelativeName)
            }
            try verifyStagedGeneration(file)
            try verifyPublishDestination(for: file)
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: stagedURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
            return
        }
        guard fileManager.fileExists(atPath: stagedPath) else {
            throw ManagedFileCoordinatorError.missingStagedFile(file.finalRelativeName)
        }
        try verifyStagedGeneration(file)
        try fileManager.moveItem(at: stagedURL, to: destination)
    }

    private func resolvedStagedURL(for file: StagedManagedFile) -> URL {
        if fileManager.fileExists(atPath: file.stagedURL.path(percentEncoded: false)) {
            return file.stagedURL
        }
        return stagingDirectory
            .appending(path: file.generation.uuidString, directoryHint: .isDirectory)
            .appending(path: file.stagedURL.lastPathComponent)
    }

    private func perform(
        _ cleanup: ManagedFileCleanup,
        snapshot: ManagedFileCatalogSnapshot
    ) throws {
        if cleanup.kind == .book,
           snapshot.referencedBookFileNames.contains(cleanup.relativeName) {
            throw ManagedFileCoordinatorError.catalogRequirementMismatch(cleanup.id)
        }
        let target = try destinationURL(kind: cleanup.kind, relativeName: cleanup.relativeName)
        guard fileManager.fileExists(atPath: target.path(percentEncoded: false)) else { return }
        try verifyContentGuard(for: cleanup, allowMissingTarget: true)
        if cleanup.disposition == .trash,
           cleanup.kind == .book,
           BookFileStore.trashesRemovedBooks {
            _ = try fileManager.trashItem(at: target, resultingItemURL: nil)
        } else {
            try fileManager.removeItem(at: target)
        }
    }

    private func verifyContentGuard(
        for cleanup: ManagedFileCleanup,
        allowMissingTarget: Bool
    ) throws {
        if let expected = cleanup.expectedIdentity {
            try verifyIdentity(expected)
            if !expected.exists {
                return
            }
            if let retainedName = cleanup.retainedEquivalentRelativeName,
               let expectedSHA256 = expected.generation?.sha256 {
                try verifyRetainedEquivalent(
                    relativeName: retainedName,
                    expectedSHA256: expectedSHA256,
                    removing: cleanup.relativeName
                )
            }
            return
        }
        guard let expectedSHA256 = cleanup.expectedSHA256?.lowercased() else { return }
        guard cleanup.kind == .book else {
            throw ManagedFileCoordinatorError.cleanupContentChanged(cleanup.relativeName)
        }
        let target = try destinationURL(kind: .book, relativeName: cleanup.relativeName)
        if allowMissingTarget,
           !fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
            return
        }
        guard fileManager.fileExists(atPath: target.path(percentEncoded: false)),
              (try? ContentHasher.sha256(of: target)) == expectedSHA256 else {
            throw ManagedFileCoordinatorError.cleanupContentChanged(cleanup.relativeName)
        }
        if let retainedName = cleanup.retainedEquivalentRelativeName {
            try verifyRetainedEquivalent(
                relativeName: retainedName,
                expectedSHA256: expectedSHA256,
                removing: cleanup.relativeName
            )
        }
    }

    private func verifyIdentity(_ expected: ManagedFileIdentitySnapshot) throws {
        let url = try destinationURL(
            kind: expected.reference.kind,
            relativeName: expected.reference.relativeName
        )
        let exists = fileManager.fileExists(atPath: url.path(percentEncoded: false))
        guard let generation = expected.generation else {
            guard !exists else {
                throw ManagedFileCoordinatorError.fileGenerationChanged(
                    expected.reference.relativeName
                )
            }
            return
        }
        guard exists else {
            throw ManagedFileCoordinatorError.fileGenerationChanged(
                expected.reference.relativeName
            )
        }
        let metadata = try physicalMetadata(at: url)
        guard metadata.isRegularFile,
              metadata.volumeNumber == generation.volumeNumber,
              metadata.fileNumber == generation.fileNumber,
              metadata.byteCount == generation.byteCount,
              metadata.modificationDate == generation.modificationDate else {
            throw ManagedFileCoordinatorError.fileGenerationChanged(
                expected.reference.relativeName
            )
        }
    }

    private func verifyRetainedEquivalent(
        relativeName: String,
        expectedSHA256: String,
        removing removedName: String
    ) throws {
        guard relativeName != removedName else {
            throw ManagedFileCoordinatorError.cleanupContentChanged(removedName)
        }
        let retained = try destinationURL(kind: .book, relativeName: relativeName)
        guard fileManager.fileExists(atPath: retained.path(percentEncoded: false)),
              (try? ContentHasher.sha256(of: retained)) == expectedSHA256 else {
            throw ManagedFileCoordinatorError.cleanupContentChanged(removedName)
        }
    }

    private func validate(
        requirement: ManagedFileRequirement,
        cleanups: [ManagedFileCleanup]
    ) throws {
        for name in requirement.referencedBookFileNames
            .union(requirement.unreferencedBookFileNames)
            .union(cleanups.map(\.relativeName))
            .union(cleanups.compactMap(\.retainedEquivalentRelativeName)) {
            guard ManagedLeafName(rawValue: name) != nil else {
                throw ManagedFileCoordinatorError.unsafeRelativeName(name)
            }
        }
    }

    private func destinationURL(kind: ManagedFileKind, relativeName: String) throws -> URL {
        guard let leaf = ManagedLeafName(rawValue: relativeName) else {
            throw ManagedFileCoordinatorError.unsafeRelativeName(relativeName)
        }
        let directory = kind == .book ? booksDirectory : coversDirectory
        guard let url = leaf.appending(to: directory) else {
            throw ManagedFileCoordinatorError.unsafeRelativeName(relativeName)
        }
        let resolvedRoot = directory.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedParent = url.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedParent == resolvedRoot else {
            throw ManagedFileCoordinatorError.unsafeRelativeName(relativeName)
        }
        if isSymbolicLink(at: url) {
            throw ManagedFileCoordinatorError.unsafeRelativeName(relativeName)
        }
        return url
    }

    private func captureIdentityWithoutCreatingDirectories(
        of reference: ManagedFileReference
    ) throws -> ManagedFileIdentitySnapshot {
        let url = try destinationURL(
            kind: reference.kind,
            relativeName: reference.relativeName
        )
        let path = url.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) else {
            return ManagedFileIdentitySnapshot(reference: reference, generation: nil)
        }
        let before = try physicalMetadata(at: url)
        guard before.isRegularFile else {
            throw ManagedFileCoordinatorError.unsupportedManagedFile(reference.relativeName)
        }
        let digest = try ContentHasher.sha256Cancellable(of: url)
        try Task.checkCancellation()
        let after = try physicalMetadata(at: url)
        guard before == after else {
            throw ManagedFileCoordinatorError.fileGenerationChanged(reference.relativeName)
        }
        return ManagedFileIdentitySnapshot(
            reference: reference,
            generation: ManagedFileGeneration(
                volumeNumber: before.volumeNumber,
                fileNumber: before.fileNumber,
                byteCount: before.byteCount,
                modificationDate: before.modificationDate,
                sha256: digest
            )
        )
    }

    private struct PhysicalMetadata: Equatable {
        let volumeNumber: UInt64?
        let fileNumber: UInt64?
        let byteCount: Int64
        let modificationDate: Date?
        let isRegularFile: Bool
    }

    private func physicalMetadata(at url: URL) throws -> PhysicalMetadata {
        guard !isSymbolicLink(at: url) else {
            throw ManagedFileCoordinatorError.unsafeRelativeName(url.lastPathComponent)
        }
        let attributes = try fileManager.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )
        return PhysicalMetadata(
            volumeNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date,
            isRegularFile: attributes[.type] as? FileAttributeType == .typeRegular
        )
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func makeReadOnly(_ url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o444))],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    private func verifyStagedGeneration(_ file: StagedManagedFile) throws {
        let staged = resolvedStagedURL(for: file)
        let path = staged.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) else {
            throw ManagedFileCoordinatorError.missingStagedFile(file.finalRelativeName)
        }
        let metadata = try physicalMetadata(at: staged)
        if let expected = file.physicalGeneration {
            guard metadata.isRegularFile,
                  metadata.volumeNumber == expected.volumeNumber,
                  metadata.fileNumber == expected.fileNumber,
                  metadata.byteCount == expected.byteCount,
                  metadata.modificationDate == expected.modificationDate else {
                throw ManagedFileCoordinatorError.fileGenerationChanged(file.finalRelativeName)
            }
        } else {
            // Compatibility path for journals created before physical
            // generations were recorded.
            guard metadata.isRegularFile,
                  metadata.byteCount == file.byteCount,
                  try ContentHasher.sha256Cancellable(of: staged) == file.sha256 else {
                throw ManagedFileCoordinatorError.fileGenerationChanged(file.finalRelativeName)
            }
        }
        guard metadata.byteCount == file.byteCount else {
            throw ManagedFileCoordinatorError.fileGenerationChanged(file.finalRelativeName)
        }
    }

    private func verifyPublishDestination(for file: StagedManagedFile) throws {
        let destination = try destinationURL(
            kind: file.kind,
            relativeName: file.finalRelativeName
        )
        guard fileManager.fileExists(
            atPath: destination.path(percentEncoded: false)
        ) else { return }
        if try ContentHasher.sha256Cancellable(of: destination) == file.sha256 {
            return
        }
        guard file.replacesExisting == true else {
            throw ManagedFileCoordinatorError.destinationConflict(file.finalRelativeName)
        }
        if let expected = file.expectedDestinationIdentity {
            try verifyIdentity(expected)
        }
    }

    private func removeOrphanedStagingDirectories(retaining journalIDs: Set<UUID>) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var removed: [URL] = []
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  !journalIDs.contains(id) else { continue }
            do {
                try fileManager.removeItem(at: entry)
                removed.append(entry)
            } catch {
                Log.persistence.error(
                    "Removing orphaned staging directory failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return removed
    }

    private func ensureDirectories() throws {
        for directory in [booksDirectory, coversDirectory, stateDirectory, stagingDirectory, journalDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func journalURL(for id: UUID) -> URL {
        journalDirectory.appending(path: "\(id.uuidString).json")
    }

    private func write(_ journal: Journal) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: journalURL(for: journal.transaction.id), options: .atomic)
    }

    private func readJournal(id: UUID) throws -> Journal {
        let url = journalURL(for: id)
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw ManagedFileCoordinatorError.journalNotFound(id)
        }
        return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
    }

    private func removeTransactionFiles(_ id: UUID) {
        let journal = journalURL(for: id)
        let staging = stagingDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: journal.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: journal)
        }
        if fileManager.fileExists(atPath: staging.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: staging)
        }
    }
}
