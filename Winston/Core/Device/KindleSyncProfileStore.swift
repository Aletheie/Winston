import Foundation
import Observation

nonisolated struct KindleSyncReceipt: Codable, Equatable, Identifiable, Sendable {
    var bookID: UUID
    var sourceFingerprint: String
    var sentFileName: String
    var coverVersion: Int?
    var syncedAt: Date

    var id: UUID { bookID }
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
    let sourceFingerprint: String
    let sentFileName: String
    let coverVersion: Int?
    let completedAt: Date
}

@MainActor
@Observable
final class KindleSyncProfileStore {
    private static let defaultStorageKey = "kindleSyncProfiles.v1"

    private(set) var profiles: [KindleSyncProfile]

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = KindleSyncProfileStore.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([KindleSyncProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = []
        }
    }

    @discardableResult
    func ensureProfile(for info: DeviceInfo, now: Date = .now) -> KindleSyncProfile {
        ensureProfile(deviceIdentifier: info.identifier, deviceName: info.name, now: now)
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
    func createProfile(named proposedName: String, for info: DeviceInfo, now: Date = .now) -> KindleSyncProfile {
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

    func assign(profileID: UUID, to info: DeviceInfo, now: Date = .now) {
        guard let targetIndex = profiles.firstIndex(where: { $0.id == profileID }) else { return }
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
            sourceFingerprint: record.sourceFingerprint,
            sentFileName: record.sentFileName,
            coverVersion: record.coverVersion,
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
        on info: DeviceInfo,
        now: Date = .now
    ) {
        record(KindleSyncTransferRecord(
            deviceIdentifier: info.identifier,
            deviceName: info.name,
            bookID: bookID,
            sourceFingerprint: sourceFingerprint,
            sentFileName: sentFileName,
            coverVersion: coverVersion,
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
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
