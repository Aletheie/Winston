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

nonisolated struct ManagedFileSource: Sendable {
    let kind: ManagedFileKind
    let sourceURL: URL?
    let data: Data?
    let finalRelativeName: String
    let replacesExisting: Bool

    static func book(sourceURL: URL, fileID: UUID = UUID()) throws -> ManagedFileSource {
        let ext = sourceURL.pathExtension.lowercased()
        let name = ext.isEmpty ? fileID.uuidString : "\(fileID.uuidString).\(ext)"
        guard ManagedLeafName(rawValue: name) != nil else {
            throw ManagedFileCoordinatorError.unsafeRelativeName(name)
        }
        return ManagedFileSource(
            kind: .book,
            sourceURL: sourceURL,
            data: nil,
            finalRelativeName: name,
            replacesExisting: false
        )
    }

    static func cover(data: Data, bookID: UUID) -> ManagedFileSource {
        ManagedFileSource(
            kind: .cover,
            sourceURL: nil,
            data: data,
            finalRelativeName: "\(bookID.uuidString).jpg",
            replacesExisting: true
        )
    }
}

nonisolated struct ManagedFileCleanup: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let kind: ManagedFileKind
    let relativeName: String
    let disposition: ManagedFileCleanupDisposition

    init(
        id: UUID = UUID(),
        kind: ManagedFileKind,
        relativeName: String,
        disposition: ManagedFileCleanupDisposition = .delete
    ) {
        self.id = id
        self.kind = kind
        self.relativeName = relativeName
        self.disposition = disposition
    }

    static func book(
        _ fileName: String,
        disposition: ManagedFileCleanupDisposition = .delete
    ) -> ManagedFileCleanup {
        ManagedFileCleanup(kind: .book, relativeName: fileName, disposition: disposition)
    }

    static func cover(
        bookID: UUID,
        disposition: ManagedFileCleanupDisposition = .delete
    ) -> ManagedFileCleanup {
        ManagedFileCleanup(
            kind: .cover,
            relativeName: "\(bookID.uuidString).jpg",
            disposition: disposition
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
    let replacesExisting: Bool?
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
    var failureMessages: [String] = []

    var hasPendingWork: Bool {
        !failedTransactionIDs.isEmpty
            || !unreadableJournalURLs.isEmpty
            || !failureMessages.isEmpty
    }
}

nonisolated enum ManagedFileFaultPoint: Sendable, Equatable {
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
    case injectedFailure(ManagedFileFaultPoint)
}

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

    func stage(
        intent: ManagedFileIntent,
        sources: [ManagedFileSource],
        requirement: ManagedFileRequirement,
        cleanups: [ManagedFileCleanup] = []
    ) throws -> ManagedFileTransaction {
        try ensureDirectories()
        try validate(requirement: requirement, cleanups: cleanups)

        let transactionID = UUID()
        let transactionStaging = stagingDirectory.appending(
            path: transactionID.uuidString,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: transactionStaging, withIntermediateDirectories: true)

        var stagedFiles: [StagedManagedFile] = []
        do {
            for source in sources {
                let staged = try stage(
                    source,
                    transactionID: transactionID,
                    transactionStaging: transactionStaging
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
        cleanups: [ManagedFileCleanup]
    ) throws -> ManagedFileTransaction {
        try stage(intent: intent, sources: [], requirement: requirement, cleanups: cleanups)
    }

    func willCommitCatalog(_ transaction: ManagedFileTransaction) throws {
        guard fileManager.fileExists(atPath: journalURL(for: transaction.id).path(percentEncoded: false)) else {
            throw ManagedFileCoordinatorError.journalNotFound(transaction.id)
        }
        try faultInjector(.beforeCatalogSave)
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
        against snapshot: ManagedFileCatalogSnapshot
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

        for file in transaction.files where !journal.publishedFileIDs.contains(file.id) {
            try faultInjector(.duringPublish(fileID: file.id))
            try publish(file)
            try faultInjector(.afterPublishBeforeCheckpoint(fileID: file.id))
            journal.publishedFileIDs.insert(file.id)
            try write(journal)
        }

        for cleanup in transaction.cleanups where !journal.completedCleanupIDs.contains(cleanup.id) {
            try faultInjector(.duringCleanup(cleanupID: cleanup.id))
            try perform(cleanup, snapshot: snapshot)
            try faultInjector(.afterCleanupBeforeCheckpoint(cleanupID: cleanup.id))
            journal.completedCleanupIDs.insert(cleanup.id)
            try write(journal)
        }

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

    private func stage(
        _ source: ManagedFileSource,
        transactionID: UUID,
        transactionStaging: URL
    ) throws -> StagedManagedFile {
        guard ManagedLeafName(rawValue: source.finalRelativeName) != nil else {
            throw ManagedFileCoordinatorError.unsafeRelativeName(source.finalRelativeName)
        }
        let stagedURL = transactionStaging.appending(path: "\(UUID().uuidString).payload")
        switch (source.sourceURL, source.data) {
        case (.some(let sourceURL), nil):
            if source.kind == .book,
               let portableHTML = try HTMLAssetInliner.portableData(for: sourceURL) {
                try portableHTML.write(to: stagedURL, options: .atomic)
            } else {
                try fileManager.copyItem(at: sourceURL, to: stagedURL)
            }
        case (nil, .some(let data)):
            try data.write(to: stagedURL, options: .atomic)
        default:
            throw CocoaError(.fileReadUnknown)
        }

        let attributes = try fileManager.attributesOfItem(
            atPath: stagedURL.path(percentEncoded: false)
        )
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return StagedManagedFile(
            id: UUID(),
            kind: source.kind,
            originalSourceURL: source.sourceURL,
            stagedURL: stagedURL,
            finalRelativeName: source.finalRelativeName,
            sha256: try ContentHasher.sha256(of: stagedURL),
            byteCount: byteCount,
            generation: transactionID,
            replacesExisting: source.replacesExisting
        )
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
        if cleanup.disposition == .trash,
           cleanup.kind == .book,
           BookFileStore.trashesRemovedBooks {
            _ = try fileManager.trashItem(at: target, resultingItemURL: nil)
        } else {
            try fileManager.removeItem(at: target)
        }
    }

    private func validate(
        requirement: ManagedFileRequirement,
        cleanups: [ManagedFileCleanup]
    ) throws {
        for name in requirement.referencedBookFileNames
            .union(requirement.unreferencedBookFileNames)
            .union(cleanups.map(\.relativeName)) {
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
        return url
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
