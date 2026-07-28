import Foundation

nonisolated struct ImportRecoveryItem: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let sourceURL: URL?
    let requestedBookID: UUID?
    let reason: ImportFailureReason
    let detail: String
    let occurredAt: Date

    init(
        id: UUID = UUID(),
        sourceURL: URL?,
        requestedBookID: UUID?,
        reason: ImportFailureReason,
        detail: String,
        occurredAt: Date = .now
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.requestedBookID = requestedBookID
        self.reason = reason
        self.detail = detail
        self.occurredAt = occurredAt
    }

    init(failure: ImportFailure, occurredAt: Date = .now) {
        self.init(
            sourceURL: failure.sourceURL,
            requestedBookID: failure.requestedBookID,
            reason: failure.reason,
            detail: failure.detail,
            occurredAt: occurredAt
        )
    }

    var canRetry: Bool {
        sourceURL != nil && reason != .recoveryDeferred
    }

    fileprivate var deduplicationKey: String {
        let source = sourceURL?
            .standardizedFileURL
            .path(percentEncoded: false)
            .lowercased() ?? "none"
        return [
            source,
            requestedBookID?.uuidString.lowercased() ?? "none",
            reason.rawValue,
        ].joined(separator: "|")
    }
}

nonisolated enum ImportRecoveryQueueError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            String(localized: "The import recovery queue uses unsupported version \(version).")
        }
    }
}

/// Durable owner of actionable import failures. Managed-file publication
/// remains owned by ManagedFileCoordinator's journal and is intentionally not
/// duplicated here.
actor ImportRecoveryQueueStore {
    static let shared = ImportRecoveryQueueStore()

    private struct Envelope: Codable {
        let version: Int
        var items: [ImportRecoveryItem]
    }

    private static let currentVersion = 1
    private static let maximumItemCount = 500

    private let configuredFileURL: URL?
    private let fileManager: FileManager

    private var fileURL: URL {
        configuredFileURL
            ?? AppPaths.managedFilesDirectory.appending(path: "ImportRecoveryQueue.json")
    }

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        configuredFileURL = fileURL
        self.fileManager = fileManager
    }

    func load() throws -> [ImportRecoveryItem] {
        guard fileManager.fileExists(
            atPath: fileURL.path(percentEncoded: false)
        ) else {
            return []
        }
        let envelope = try JSONDecoder().decode(
            Envelope.self,
            from: Data(contentsOf: fileURL)
        )
        guard envelope.version == Self.currentVersion else {
            throw ImportRecoveryQueueError.unsupportedVersion(envelope.version)
        }
        return Self.sorted(envelope.items)
    }

    @discardableResult
    func record(_ failures: [ImportFailure]) throws -> [ImportRecoveryItem] {
        let actionable = failures.filter { $0.reason != .recoveryDeferred }
        guard !actionable.isEmpty else { return try load() }

        var items = try load()
        var indicesByKey: [String: Int] = [:]
        for (index, item) in items.enumerated()
        where indicesByKey[item.deduplicationKey] == nil {
            indicesByKey[item.deduplicationKey] = index
        }
        let now = Date()
        for failure in actionable {
            let item = ImportRecoveryItem(failure: failure, occurredAt: now)
            if let index = indicesByKey[item.deduplicationKey] {
                let existing = items[index]
                items[index] = ImportRecoveryItem(
                    id: existing.id,
                    sourceURL: item.sourceURL,
                    requestedBookID: item.requestedBookID,
                    reason: item.reason,
                    detail: item.detail,
                    occurredAt: now
                )
            } else {
                indicesByKey[item.deduplicationKey] = items.count
                items.append(item)
            }
        }
        items = Array(Self.sorted(items).prefix(Self.maximumItemCount))
        try write(items)
        return items
    }

    @discardableResult
    func dismiss(ids: Set<UUID>) throws -> [ImportRecoveryItem] {
        guard !ids.isEmpty else { return try load() }
        let retained = try load().filter { !ids.contains($0.id) }
        try write(retained)
        return retained
    }

    private func write(_ items: [ImportRecoveryItem]) throws {
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(
            version: Self.currentVersion,
            items: Self.sorted(items)
        ))
        try data.write(to: fileURL, options: .atomic)
    }

    private static func sorted(
        _ items: [ImportRecoveryItem]
    ) -> [ImportRecoveryItem] {
        items.sorted {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt > $1.occurredAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
