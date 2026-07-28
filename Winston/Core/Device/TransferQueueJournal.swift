import Foundation

nonisolated enum TransferQueueResumePolicy: String, Codable, Sendable {
    /// Resume unfinished payloads automatically, but only when the exact same
    /// device identifier is connected and the frozen source generation matches.
    case sameDeviceAutomatically
}

nonisolated enum DurableTransferItemState: String, Codable, Sendable {
    case pending
    /// The device transport verified the exact destination and byte count.
    /// Resume must never send this payload again, even if post-processing did
    /// not finish before the process exited.
    case payloadCommitted
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        self != .pending
    }
}

nonisolated struct DurableTransferItem: Codable, Equatable, Sendable {
    let descriptor: KindleSendDescriptor
    let sourceFileGeneration: TransferFileGeneration
    var state: DurableTransferItemState
    var detail: String?
}

nonisolated struct DurableTransferJob: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

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

    var isTerminal: Bool {
        items.allSatisfy(\.state.isTerminal)
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && !deviceIdentifier.isEmpty
            && !items.isEmpty
            && Set(items.map(\.descriptor.bookUUID)).count == items.count
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

    init(
        directory: URL = AppPaths.transferQueueJournalDirectory,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.directory = directory
        self.now = now
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
        try FileManager.default.removeItem(at: fileURL)
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
