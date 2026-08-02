import Foundation

nonisolated enum TransferQueueResumePolicy: String, Codable, Sendable {
    /// Resume unfinished payloads automatically, but only when the exact same
    /// device identifier is connected and the frozen source generation matches.
    case sameDeviceAutomatically
}

nonisolated enum DurableTransferItemState: String, Codable, Sendable {
    case pending
    case inFlight
    case deliveryUnknown
    case payloadCommitted
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

nonisolated struct DurableTransferPayload: Codable, Equatable, Sendable {
    let attemptID: UUID
    let destinationFileName: String
    /// Present for every schema-v2 transport attempt. Schema-v1 committed
    /// payloads did not persist this evidence, so migration leaves it unknown
    /// and permits post-processing without weakening delivery reconciliation.
    var expectedByteCount: UInt64?
    var artifactFingerprint: String?
    var transportIdentifier: String?
    var payloadCommittedAt: Date?
    var conversionAdopted: Bool
    var staleVariantsRemoved: Bool
    var coverProcessed: Bool
    var coverPushed: Bool
    var receiptPersisted: Bool
}

nonisolated struct DurableTransferItem: Codable, Equatable, Sendable {
    let descriptor: KindleSendDescriptor
    let sourceFileGeneration: TransferFileGeneration
    var state: DurableTransferItemState
    var detail: String?
    var payload: DurableTransferPayload? = nil
}

nonisolated struct DurableTransferJob: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let id: UUID
    let deviceIdentifier: String
    let resumePolicy: TransferQueueResumePolicy
    let createdAt: Date
    var updatedAt: Date
    var items: [DurableTransferItem]

    var pendingItems: [DurableTransferItem] {
        items.filter { $0.state == .pending }
    }

    var unresolvedItems: [DurableTransferItem] {
        items.filter {
            $0.state == .inFlight || $0.state == .deliveryUnknown
        }
    }

    var postProcessingItems: [DurableTransferItem] {
        items.filter { $0.state == .payloadCommitted }
    }

    var isTerminal: Bool {
        items.allSatisfy(\.state.isTerminal)
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && !deviceIdentifier.isEmpty
            && !items.isEmpty
            && Set(items.map(\.descriptor.bookUUID)).count == items.count
            && items.allSatisfy {
                switch $0.state {
                case .pending, .completed, .failed, .cancelled:
                    true
                case .inFlight, .deliveryUnknown, .payloadCommitted:
                    $0.payload != nil
                }
            }
    }
}

nonisolated enum TransferQueueJournalLoadIssue: Equatable, Sendable {
    case corrupt
    case unsupportedSchema(Int)
    case quarantineFailed
}

nonisolated struct TransferQueueJournalLoadResult: Sendable {
    let job: DurableTransferJob?
    let issue: TransferQueueJournalLoadIssue?
    let quarantinedURL: URL?

    static let empty = TransferQueueJournalLoadResult(
        job: nil,
        issue: nil,
        quarantinedURL: nil
    )
}

/// One active durable send job per application library. Writes are atomic and
/// happen synchronously at transport commit points so a crash cannot regress a
/// verified payload back to `pending`.
nonisolated struct TransferQueueJournalStore: Sendable {
    let directory: URL
    private let now: @Sendable () -> Date
    private let beforeSave: @Sendable (DurableTransferJob) throws -> Void
    private let beforeRemove: @Sendable () throws -> Void

    init(
        directory: URL = AppPaths.transferQueueJournalDirectory,
        now: @escaping @Sendable () -> Date = { .now },
        beforeSave: @escaping @Sendable (DurableTransferJob) throws -> Void = { _ in },
        beforeRemove: @escaping @Sendable () throws -> Void = {}
    ) {
        self.directory = directory
        self.now = now
        self.beforeSave = beforeSave
        self.beforeRemove = beforeRemove
    }

    var fileURL: URL {
        directory.appending(path: "active-transfer.json")
    }

    func load() -> TransferQueueJournalLoadResult {
        guard FileManager.default.fileExists(
            atPath: fileURL.path(percentEncoded: false)
        ) else {
            return .empty
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return quarantine(issue: .corrupt)
        }

        do {
            let job = try JSONDecoder().decode(DurableTransferJob.self, from: data)
            if job.schemaVersion == 1 {
                let migrated = migrateV1(job)
                guard migrated.isValid else {
                    return quarantine(issue: .corrupt)
                }
                do {
                    try save(migrated)
                    return TransferQueueJournalLoadResult(
                        job: migrated,
                        issue: nil,
                        quarantinedURL: nil
                    )
                } catch {
                    return TransferQueueJournalLoadResult(
                        job: nil,
                        issue: .quarantineFailed,
                        quarantinedURL: nil
                    )
                }
            }
            guard job.schemaVersion == DurableTransferJob.currentSchemaVersion else {
                return quarantine(issue: .unsupportedSchema(job.schemaVersion))
            }
            guard job.isValid else {
                return quarantine(issue: .corrupt)
            }
            return TransferQueueJournalLoadResult(
                job: job,
                issue: nil,
                quarantinedURL: nil
            )
        } catch {
            return quarantine(issue: .corrupt)
        }
    }

    func save(_ job: DurableTransferJob) throws {
        guard job.isValid else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try beforeSave(job)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(job)
        try data.write(to: fileURL, options: .atomic)
    }

    func remove() throws {
        guard FileManager.default.fileExists(
            atPath: fileURL.path(percentEncoded: false)
        ) else { return }
        try beforeRemove()
        try FileManager.default.removeItem(at: fileURL)
    }

    private func migrateV1(_ job: DurableTransferJob) -> DurableTransferJob {
        DurableTransferJob(
            schemaVersion: DurableTransferJob.currentSchemaVersion,
            id: job.id,
            deviceIdentifier: job.deviceIdentifier,
            resumePolicy: job.resumePolicy,
            createdAt: job.createdAt,
            updatedAt: now(),
            items: job.items.map { item in
                var item = item
                if item.state == .payloadCommitted {
                    item.payload = DurableTransferPayload(
                        attemptID: UUID(),
                        destinationFileName: item.descriptor.targetFileName,
                        expectedByteCount: nil,
                        artifactFingerprint: nil,
                        transportIdentifier: nil,
                        payloadCommittedAt: job.updatedAt,
                        conversionAdopted: false,
                        staleVariantsRemoved: false,
                        coverProcessed: false,
                        coverPushed: false,
                        receiptPersisted: false
                    )
                }
                return item
            }
        )
    }

    private func quarantine(
        issue: TransferQueueJournalLoadIssue
    ) -> TransferQueueJournalLoadResult {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let timestamp = Int(now().timeIntervalSince1970 * 1_000)
            var candidate = directory.appending(
                path: "active-transfer.corrupt-\(timestamp).json"
            )
            var suffix = 0
            while FileManager.default.fileExists(
                atPath: candidate.path(percentEncoded: false)
            ) {
                suffix += 1
                candidate = directory.appending(
                    path: "active-transfer.corrupt-\(timestamp)-\(suffix).json"
                )
            }
            try FileManager.default.moveItem(at: fileURL, to: candidate)
            return TransferQueueJournalLoadResult(
                job: nil,
                issue: issue,
                quarantinedURL: candidate
            )
        } catch {
            return TransferQueueJournalLoadResult(
                job: nil,
                issue: .quarantineFailed,
                quarantinedURL: nil
            )
        }
    }
}
