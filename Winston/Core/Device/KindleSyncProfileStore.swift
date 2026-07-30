import Foundation
import Observation
import OSLog

nonisolated struct KindleSyncReceipt: Codable, Equatable, Identifiable, Sendable {
    var bookID: UUID
    var assetID: UUID?
    var sourceFormat: String?
    var sourceSizeBytes: UInt64?
    var sourceFingerprint: String
    var artifactFormat: String?
    var artifactSizeBytes: UInt64?
    var artifactFingerprint: String?
    var sentFileName: String
    var transportIdentifier: String?
    var coverVersion: Int?
    var coverIdentity: String?
    var syncedAt: Date

    var id: UUID { bookID }

    init(
        bookID: UUID,
        assetID: UUID? = nil,
        sourceFormat: String? = nil,
        sourceSizeBytes: UInt64? = nil,
        sourceFingerprint: String,
        artifactFormat: String? = nil,
        artifactSizeBytes: UInt64? = nil,
        artifactFingerprint: String? = nil,
        sentFileName: String,
        transportIdentifier: String? = nil,
        coverVersion: Int?,
        coverIdentity: String? = nil,
        syncedAt: Date
    ) {
        self.bookID = bookID
        self.assetID = assetID
        self.sourceFormat = sourceFormat
        self.sourceSizeBytes = sourceSizeBytes
        self.sourceFingerprint = sourceFingerprint
        self.artifactFormat = artifactFormat
        self.artifactSizeBytes = artifactSizeBytes
        self.artifactFingerprint = artifactFingerprint
        self.sentFileName = sentFileName
        self.transportIdentifier = transportIdentifier
        self.coverVersion = coverVersion
        self.coverIdentity = coverIdentity
        self.syncedAt = syncedAt
    }
}

nonisolated struct KindleSyncProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var deviceIdentifiers: [String]
    var receipts: [KindleSyncReceipt]
    var lastSeenAt: Date
}

nonisolated struct KindleSyncTransferRecord: Equatable, Sendable {
    let deviceIdentifier: String
    let deviceName: String
    let bookID: UUID
    let assetID: UUID?
    let sourceFormat: String?
    let sourceSizeBytes: UInt64?
    let sourceFingerprint: String
    let artifactFormat: String?
    let artifactSizeBytes: UInt64?
    let artifactFingerprint: String?
    let sentFileName: String
    let transportIdentifier: String?
    let coverVersion: Int?
    let coverIdentity: String?
    let completedAt: Date

    init(
        deviceIdentifier: String,
        deviceName: String,
        bookID: UUID,
        assetID: UUID? = nil,
        sourceFormat: String? = nil,
        sourceSizeBytes: UInt64? = nil,
        sourceFingerprint: String,
        artifactFormat: String? = nil,
        artifactSizeBytes: UInt64? = nil,
        artifactFingerprint: String? = nil,
        sentFileName: String,
        transportIdentifier: String? = nil,
        coverVersion: Int?,
        coverIdentity: String? = nil,
        completedAt: Date
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.deviceName = deviceName
        self.bookID = bookID
        self.assetID = assetID
        self.sourceFormat = sourceFormat
        self.sourceSizeBytes = sourceSizeBytes
        self.sourceFingerprint = sourceFingerprint
        self.artifactFormat = artifactFormat
        self.artifactSizeBytes = artifactSizeBytes
        self.artifactFingerprint = artifactFingerprint
        self.sentFileName = sentFileName
        self.transportIdentifier = transportIdentifier
        self.coverVersion = coverVersion
        self.coverIdentity = coverIdentity
        self.completedAt = completedAt
    }
}

nonisolated enum KindleSyncProfileLoadIssue: Equatable, Sendable {
    case corruptDataQuarantined(key: String)
    case unsupportedSchemaQuarantined(version: Int, key: String)
}

@MainActor
@Observable
final class KindleSyncProfileStore {
    private static let defaultStorageKey = "kindleSyncProfiles.v1"
    private static let currentSchemaVersion = 1

    private struct Envelope: Codable {
        let schemaVersion: Int
        let profiles: [KindleSyncProfile]
    }

    private(set) var profiles: [KindleSyncProfile]
    private(set) var lastLoadIssue: KindleSyncProfileLoadIssue?

    private let defaults: UserDefaults
    private let storageKey: String
    private let now: @Sendable () -> Date

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = KindleSyncProfileStore.defaultStorageKey,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.now = now

        var loadedProfiles: [KindleSyncProfile] = []
        var loadIssue: KindleSyncProfileLoadIssue?
        var shouldPersistMigratedData = false
        if let data = defaults.data(forKey: storageKey) {
            do {
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                if envelope.schemaVersion == Self.currentSchemaVersion {
                    loadedProfiles = envelope.profiles
                } else {
                    let key = Self.quarantine(
                        data,
                        storageKey: storageKey,
                        defaults: defaults,
                        now: now()
                    )
                    loadIssue = .unsupportedSchemaQuarantined(
                        version: envelope.schemaVersion,
                        key: key
                    )
                }
            } catch {
                if let legacy = try? JSONDecoder().decode(
                    [KindleSyncProfile].self,
                    from: data
                ) {
                    loadedProfiles = legacy
                    shouldPersistMigratedData = true
                } else {
                    let key = Self.quarantine(
                        data,
                        storageKey: storageKey,
                        defaults: defaults,
                        now: now()
                    )
                    loadIssue = .corruptDataQuarantined(key: key)
                }
            }
        }
        profiles = loadedProfiles
        lastLoadIssue = loadIssue
        if shouldPersistMigratedData {
            persist()
        }
    }

    @discardableResult
    func ensureProfile(for info: DeviceInfo, now: Date? = nil) -> KindleSyncProfile {
        ensureProfile(
            deviceIdentifier: info.identifier,
            deviceName: info.name,
            now: now ?? self.now()
        )
    }

    func profile(for info: DeviceInfo) -> KindleSyncProfile? {
        profiles.first { $0.deviceIdentifiers.contains(info.identifier) }
    }

    func profile(id: UUID) -> KindleSyncProfile? {
        profiles.first { $0.id == id }
    }

    func receipts(for profileID: UUID) -> [UUID: KindleSyncReceipt] {
        guard let profile = profile(id: profileID) else { return [:] }
        return Dictionary(
            profile.receipts.map { ($0.bookID, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.syncedAt >= rhs.syncedAt ? lhs : rhs }
        )
    }

    @discardableResult
    func createProfile(
        named proposedName: String,
        for info: DeviceInfo,
        now: Date? = nil
    ) -> KindleSyncProfile {
        let now = now ?? self.now()
        detach(info.identifier)
        let profile = KindleSyncProfile(
            id: UUID(),
            name: uniqueName(proposedName, fallback: info.name),
            deviceIdentifiers: [info.identifier],
            receipts: [],
            lastSeenAt: now
        )
        profiles.append(profile)
        persist()
        return profile
    }

    func assign(profileID: UUID, to info: DeviceInfo, now: Date? = nil) {
        guard let targetIndex = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let now = now ?? self.now()
        detach(info.identifier, persisting: false)
        profiles[targetIndex].deviceIdentifiers.append(info.identifier)
        profiles[targetIndex].deviceIdentifiers.sort()
        profiles[targetIndex].lastSeenAt = now
        persist()
    }

    func rename(profileID: UUID, to proposedName: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profiles[index].name = uniqueName(trimmed, excluding: profileID)
        persist()
    }

    func record(_ record: KindleSyncTransferRecord) {
        let profile = ensureProfile(
            deviceIdentifier: record.deviceIdentifier,
            deviceName: record.deviceName,
            now: record.completedAt
        )
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let receipt = KindleSyncReceipt(
            bookID: record.bookID,
            assetID: record.assetID,
            sourceFormat: record.sourceFormat,
            sourceSizeBytes: record.sourceSizeBytes,
            sourceFingerprint: record.sourceFingerprint,
            artifactFormat: record.artifactFormat,
            artifactSizeBytes: record.artifactSizeBytes,
            artifactFingerprint: record.artifactFingerprint,
            sentFileName: record.sentFileName,
            transportIdentifier: record.transportIdentifier,
            coverVersion: record.coverVersion,
            coverIdentity: record.coverIdentity,
            syncedAt: record.completedAt
        )
        if let receiptIndex = profiles[profileIndex].receipts.firstIndex(where: { $0.bookID == record.bookID }) {
            profiles[profileIndex].receipts[receiptIndex] = receipt
        } else {
            profiles[profileIndex].receipts.append(receipt)
        }
        profiles[profileIndex].lastSeenAt = record.completedAt
        persist()
    }

    func recordCoverRepair(
        bookID: UUID,
        sourceFingerprint: String,
        sentFileName: String,
        coverVersion: Int,
        coverIdentity: String? = nil,
        on info: DeviceInfo,
        now: Date? = nil
    ) {
        let now = now ?? self.now()
        record(KindleSyncTransferRecord(
            deviceIdentifier: info.identifier,
            deviceName: info.name,
            bookID: bookID,
            sourceFingerprint: sourceFingerprint,
            sentFileName: sentFileName,
            coverVersion: coverVersion,
            coverIdentity: coverIdentity,
            completedAt: now
        ))
    }

    func recordRemoval(fileNames: Set<String>, from info: DeviceInfo) {
        guard !fileNames.isEmpty,
              let profileIndex = profiles.firstIndex(where: {
                  $0.deviceIdentifiers.contains(info.identifier)
              }) else { return }
        let lowered = Set(fileNames.map { $0.lowercased() })
        profiles[profileIndex].receipts.removeAll { lowered.contains($0.sentFileName.lowercased()) }
        persist()
    }

    private func ensureProfile(
        deviceIdentifier: String,
        deviceName: String,
        now: Date
    ) -> KindleSyncProfile {
        if let index = profiles.firstIndex(where: { $0.deviceIdentifiers.contains(deviceIdentifier) }) {
            profiles[index].lastSeenAt = now
            persist()
            return profiles[index]
        }
        let profile = KindleSyncProfile(
            id: UUID(),
            name: uniqueName(deviceName, fallback: "Kindle"),
            deviceIdentifiers: [deviceIdentifier],
            receipts: [],
            lastSeenAt: now
        )
        profiles.append(profile)
        persist()
        return profile
    }

    private func detach(_ deviceIdentifier: String, persisting: Bool = true) {
        for index in profiles.indices {
            profiles[index].deviceIdentifiers.removeAll { $0 == deviceIdentifier }
        }
        if persisting { persist() }
    }

    private func uniqueName(
        _ proposedName: String,
        fallback: String = "Kindle",
        excluding excludedID: UUID? = nil
    ) -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? fallback : trimmed
        let existing = Set(profiles.filter { $0.id != excludedID }.map { $0.name.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(Envelope(
                schemaVersion: Self.currentSchemaVersion,
                profiles: profiles
            ))
            defaults.set(data, forKey: storageKey)
        } catch {
            Log.persistence.error(
                "Could not encode Kindle sync profiles: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func quarantine(
        _ data: Data,
        storageKey: String,
        defaults: UserDefaults,
        now: Date
    ) -> String {
        let timestamp = Int64(now.timeIntervalSince1970 * 1_000)
        let base = "\(storageKey).corrupt.\(timestamp)"
        var key = base
        var suffix = 2
        while defaults.object(forKey: key) != nil {
            key = "\(base).\(suffix)"
            suffix += 1
        }
        defaults.set(data, forKey: key)
        defaults.removeObject(forKey: storageKey)
        return key
    }
}
