import Foundation
import Testing
@testable import Winston

@MainActor
@Suite("Kindle sync plan", .serialized)
struct KindleSyncPlanTests {
    private func candidate(
        id: UUID = UUID(),
        title: String = "Dune",
        matchKey: String = "dune",
        targetFileName: String? = nil,
        sourceFormat: String = "EPUB",
        targetFormat: String = "AZW3",
        fingerprint: String = "source-v2",
        lineageFingerprint: String? = nil,
        size: UInt64 = 0,
        requiresConversion: Bool = true,
        staleConversion: Bool = false,
        coverVersion: Int = 1,
        coverIdentity: String? = nil,
        hasCover: Bool = true,
        blockReason: KindleSyncReason? = nil
    ) -> KindleSyncCandidate {
        KindleSyncCandidate(
            id: id,
            title: title,
            author: "Frank Herbert",
            matchKey: matchKey,
            sourceFormat: sourceFormat,
            targetFileName: targetFileName ?? "\(title).\(targetFormat.lowercased())",
            targetFormat: targetFormat,
            sourceFingerprint: fingerprint,
            sourceLineageFingerprint: lineageFingerprint,
            sendSizeBytes: size,
            requiresConversion: requiresConversion,
            hasStaleTargetConversion: staleConversion,
            coverVersion: coverVersion,
            coverIdentity: coverIdentity,
            hasCover: hasCover,
            blockReason: blockReason
        )
    }

    private func profile(receipts: [KindleSyncReceipt] = []) -> KindleSyncProfile {
        KindleSyncProfile(
            id: UUID(),
            name: "My Kindle",
            deviceIdentifiers: ["kindle-1"],
            receipts: receipts,
            lastSeenAt: .now
        )
    }

    @Test func missingLibraryBookIsAddedWhileDeviceOnlyRemovalIsOptIn() {
        let local = candidate(title: "Dune", matchKey: "dune")
        let deviceOnly = DeviceBook(
            path: "/documents/Foundation.azw3",
            fileName: "Foundation.azw3",
            sizeBytes: 800
        )

        let plan = KindleSyncPlanner.makePlan(
            candidates: [local],
            deviceBooks: [deviceOnly],
            profile: profile()
        )

        #expect(plan.items.first(where: { $0.bookID == local.id })?.action == .add)
        let removal = plan.items.first { $0.deviceBookID == deviceOnly.id }
        #expect(removal?.action == .remove)
        #expect(removal?.reason == .onlyOnDevice)
        #expect(removal?.selectedByDefault == false)
        #expect(plan.selectedByDefault.count == 1)
    }

    @Test func modifiedEPUBWithOldAZW3IsRegeneratedAndReplacedNotDuplicated() {
        let local = candidate(staleConversion: true)
        let oldAZW3 = DeviceBook(
            path: "/documents/Dune.azw3",
            fileName: "Dune.azw3",
            sizeBytes: 1_000
        )

        let plan = KindleSyncPlanner.makePlan(
            candidates: [local],
            deviceBooks: [oldAZW3],
            profile: profile()
        )

        let item = plan.items.first { $0.bookID == local.id }
        #expect(item?.action == .update)
        #expect(item?.reason == .outdatedConversion)
        #expect(plan.count(for: .add) == 0)
        #expect(plan.count(for: .remove) == 0)
    }

    @Test func preparationDetectsGeneratedFormatWhoseSourceHashIsStale() async throws {
        let library = try await TestLibrary()
        let primarySource = library.root.appending(path: "source.epub")
        try Data("new source".utf8).write(to: primarySource)
        let primaryName = "\(UUID().uuidString).epub"
        try library.installBookFile(from: primarySource, fileName: primaryName)
        let book = Book(fileName: primaryName, originalFileName: "Dune.epub")
        let primary = BookAsset(
            uuid: book.uuid,
            fileName: primaryName,
            contentHash: "new-source-hash",
            validationStatus: .ok,
            book: book
        )
        let targetFormat = EbookConverter.kindleTarget(forFormat: "epub").ext
        let staleSource = library.root.appending(path: "old.\(targetFormat)")
        try Data("old conversion".utf8).write(to: staleSource)
        let staleName = try TestManagedFileFixtureStore.importCopy(of: staleSource, uuid: UUID())
        let stale = BookAsset(
            fileName: staleName,
            origin: .generated,
            generatedFromContentHash: "old-source-hash",
            validationStatus: .ok,
            book: book
        )
        library.context.insert(book)
        library.context.insert(primary)
        library.context.insert(stale)
        try library.context.save()

        let candidate = KindleSendPreparation.candidate(for: book)
        let device = DeviceBook(
            path: "/documents/Dune.\(targetFormat)",
            fileName: "Dune.\(targetFormat)",
            sizeBytes: 1_000
        )
        let plan = KindleSyncPlanner.makePlan(
            candidates: [candidate],
            deviceBooks: [device],
            profile: profile()
        )

        #expect(candidate.hasStaleTargetConversion)
        #expect(plan.items.first?.action == .update)
        #expect(plan.items.first?.reason == .outdatedConversion)
    }

    @Test func changedSourceFingerprintUpdatesExistingDeviceCopy() {
        let local = candidate(fingerprint: "new-source")
        let receipt = KindleSyncReceipt(
            bookID: local.id,
            sourceFingerprint: "old-source",
            sentFileName: "Dune.azw3",
            coverVersion: 1,
            syncedAt: .now
        )
        let device = DeviceBook(path: "/documents/Dune.azw3", fileName: "Dune.azw3", sizeBytes: 900)

        let plan = KindleSyncPlanner.makePlan(
            candidates: [local],
            deviceBooks: [device],
            profile: profile(receipts: [receipt])
        )

        #expect(plan.items.first?.action == .update)
        #expect(plan.items.first?.reason == .sourceChanged)
    }

    @Test func generatedArtifactMatchesReceiptForItsSourceGeneration() {
        let local = candidate(
            fingerprint: "generated-artifact-hash",
            lineageFingerprint: "primary-source-hash"
        )
        let target = DevicePathAllocator.allocate(
            proposedFileName: local.targetFileName,
            ownerID: local.id
        )
        let receipt = KindleSyncReceipt(
            bookID: local.id,
            sourceFingerprint: "primary-source-hash",
            sentFileName: target,
            coverVersion: 1,
            syncedAt: .now
        )
        let device = DeviceBook(
            path: "/documents/\(target)",
            fileName: target,
            sizeBytes: 900
        )

        let plan = KindleSyncPlanner.makePlan(
            candidates: [local],
            deviceBooks: [device],
            profile: profile(receipts: [receipt])
        )

        #expect(plan.items.first?.action == .keep)
    }

    @Test func changedCoverRepairsThumbnailWithoutReplacingBook() {
        let local = candidate(fingerprint: "same", coverVersion: 3)
        let receipt = KindleSyncReceipt(
            bookID: local.id,
            sourceFingerprint: "same",
            sentFileName: "Dune.azw3",
            coverVersion: 2,
            syncedAt: .now
        )
        let device = DeviceBook(path: "/documents/Dune.azw3", fileName: "Dune.azw3", sizeBytes: 900)

        let plan = KindleSyncPlanner.makePlan(
            candidates: [local],
            deviceBooks: [device],
            profile: profile(receipts: [receipt])
        )

        #expect(plan.items.first?.action == .repairCover)
        #expect(plan.items.first?.reason == .coverChanged)
    }

    @Test func matchingReceiptKeepsDeviceBookUntouched() {
        let local = candidate(fingerprint: "same", coverVersion: 2)
        let receipt = KindleSyncReceipt(
            bookID: local.id,
            sourceFingerprint: "same",
            sentFileName: "Dune.azw3",
            coverVersion: 2,
            syncedAt: .now
        )
        let device = DeviceBook(path: "/documents/Dune.azw3", fileName: "Dune.azw3", sizeBytes: 900)

        let plan = KindleSyncPlanner.makePlan(
            candidates: [local],
            deviceBooks: [device],
            profile: profile(receipts: [receipt])
        )

        #expect(plan.items.first?.action == .keep)
        #expect(plan.selectedByDefault.isEmpty)
    }

    @Test func changingCoverOwnerRepairsThumbnailEvenWhenVersionMatches() {
        let local = candidate(
            fingerprint: "same",
            coverVersion: 2,
            coverIdentity: "work:22222222-2222-2222-2222-222222222222"
        )
        let receipt = KindleSyncReceipt(
            bookID: local.id,
            sourceFingerprint: "same",
            sentFileName: "Dune.azw3",
            coverVersion: 2,
            coverIdentity: "edition:11111111-1111-1111-1111-111111111111",
            syncedAt: .now
        )
        let device = DeviceBook(
            path: "/documents/Dune.azw3",
            fileName: "Dune.azw3",
            sizeBytes: 900
        )

        let plan = KindleSyncPlanner.makePlan(
            candidates: [local],
            deviceBooks: [device],
            profile: profile(receipts: [receipt])
        )

        #expect(plan.items.first?.action == .repairCover)
        #expect(plan.items.first?.reason == .coverChanged)
    }

    @Test func duplicateDeviceFormatBecomesOptionalRemoval() {
        let local = candidate(fingerprint: "same", coverVersion: 2)
        let receipt = KindleSyncReceipt(
            bookID: local.id,
            sourceFingerprint: "same",
            sentFileName: "Dune.azw3",
            coverVersion: 2,
            syncedAt: .now
        )
        let preferred = DeviceBook(path: "/documents/Dune.azw3", fileName: "Dune.azw3", sizeBytes: 900)
        let duplicate = DeviceBook(path: "/documents/Dune.mobi", fileName: "Dune.mobi", sizeBytes: 850)

        let plan = KindleSyncPlanner.makePlan(
            candidates: [local],
            deviceBooks: [preferred, duplicate],
            profile: profile(receipts: [receipt])
        )

        let removal = plan.items.first { $0.deviceBookID == duplicate.id }
        #expect(removal?.action == .remove)
        #expect(removal?.reason == .duplicateVariant)
        #expect(removal?.selectedByDefault == false)
    }

    @Test func collidingLibraryFilenamesReceiveStableDistinctPaths() {
        let first = candidate(
            title: "Dune First Edition",
            matchKey: "book",
            targetFileName: "book.azw3"
        )
        let second = candidate(
            title: "Dune Translation",
            matchKey: "book",
            targetFileName: "book.azw3"
        )
        let firstTarget = DevicePathAllocator.allocate(
            proposedFileName: first.targetFileName,
            ownerID: first.id
        )
        let secondTarget = DevicePathAllocator.allocate(
            proposedFileName: second.targetFileName,
            ownerID: second.id
        )
        let deviceBooks = [
            DeviceBook(
                path: "/documents/\(firstTarget)",
                fileName: firstTarget,
                sizeBytes: 900
            ),
            DeviceBook(
                path: "/documents/\(secondTarget)",
                fileName: secondTarget,
                sizeBytes: 900
            ),
        ]
        let receipts = [first, second].map { candidate in
            KindleSyncReceipt(
                bookID: candidate.id,
                sourceFingerprint: candidate.sourceFingerprint,
                sentFileName: DevicePathAllocator.allocate(
                    proposedFileName: candidate.targetFileName,
                    ownerID: candidate.id
                ),
                coverVersion: candidate.coverVersion,
                syncedAt: .now
            )
        }

        let plan = KindleSyncPlanner.makePlan(
            candidates: [first, second],
            deviceBooks: deviceBooks,
            profile: profile(receipts: receipts)
        )

        #expect(firstTarget != secondTarget)
        #expect(plan.count(for: .keep) == 2)
        #expect(plan.count(for: .blocked) == 0)
        #expect(plan.count(for: .add) == 0)
        #expect(plan.count(for: .remove) == 0)
    }

    @Test func planningScalesToLargeLibrariesAndDevices() {
        let candidates = (0..<4_000).map { index in
            candidate(title: "Library \(index)", matchKey: "library-\(index)")
        }
        let deviceBooks = (0..<4_000).map { index in
            DeviceBook(
                path: "/documents/Device \(index).azw3",
                fileName: "Device \(index).azw3",
                sizeBytes: 1_000
            )
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let plan = KindleSyncPlanner.makePlan(
            candidates: candidates,
            deviceBooks: deviceBooks,
            profile: profile()
        )
        let elapsed = startedAt.duration(to: clock.now)

        print("Kindle sync planning benchmark: \(elapsed)")
        #expect(plan.items.count == 8_000)
        #expect(elapsed < .seconds(2))
    }

    @Test func profilesPersistSeparateTransferHistoriesForTwoKindles() throws {
        let suiteName = "KindleSyncPlanTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "profiles"
        let firstInfo = DeviceInfo(
            name: "Travel Kindle",
            model: "Paperwhite",
            kind: .mtp,
            totalBytes: 8_000,
            freeBytes: 4_000,
            identifier: "mtp:first"
        )
        let secondInfo = DeviceInfo(
            name: "Home Kindle",
            model: "Scribe",
            kind: .mtp,
            totalBytes: 16_000,
            freeBytes: 9_000,
            identifier: "mtp:second"
        )
        let bookID = UUID()
        let store = KindleSyncProfileStore(defaults: defaults, storageKey: storageKey)
        let firstProfile = store.ensureProfile(for: firstInfo)
        let secondProfile = store.ensureProfile(for: secondInfo)
        store.record(KindleSyncTransferRecord(
            deviceIdentifier: firstInfo.identifier,
            deviceName: firstInfo.name,
            bookID: bookID,
            sourceFingerprint: "source",
            sentFileName: "Dune.azw3",
            coverVersion: 1,
            completedAt: .now
        ))

        let reloaded = KindleSyncProfileStore(defaults: defaults, storageKey: storageKey)

        #expect(reloaded.profiles.count == 2)
        #expect(reloaded.receipts(for: firstProfile.id)[bookID] != nil)
        #expect(reloaded.receipts(for: secondProfile.id)[bookID] == nil)
    }

    @Test func legacyReceiptsDecodeWithUnknownArtifactMetadata() throws {
        struct LegacyReceipt: Codable {
            let bookID: UUID
            let sourceFingerprint: String
            let sentFileName: String
            let coverVersion: Int?
            let syncedAt: Date
        }
        struct LegacyProfile: Codable {
            let id: UUID
            let name: String
            let deviceIdentifiers: [String]
            let receipts: [LegacyReceipt]
            let lastSeenAt: Date
        }

        let suiteName = "KindleSyncLegacyReceipt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "profiles"
        let bookID = UUID()
        let legacy = LegacyProfile(
            id: UUID(),
            name: "Legacy Kindle",
            deviceIdentifiers: ["legacy-device"],
            receipts: [LegacyReceipt(
                bookID: bookID,
                sourceFingerprint: "legacy-source",
                sentFileName: "Legacy.mobi",
                coverVersion: 1,
                syncedAt: .now
            )],
            lastSeenAt: .now
        )
        defaults.set(try JSONEncoder().encode([legacy]), forKey: storageKey)

        let store = KindleSyncProfileStore(defaults: defaults, storageKey: storageKey)
        let receipt = try #require(store.receipts(for: legacy.id)[bookID])

        #expect(receipt.assetID == nil)
        #expect(receipt.sourceFormat == nil)
        #expect(receipt.sourceSizeBytes == nil)
        #expect(receipt.artifactFormat == nil)
        #expect(receipt.artifactSizeBytes == nil)
        #expect(receipt.artifactFingerprint == nil)
        #expect(receipt.transportIdentifier == nil)
        #expect(receipt.coverIdentity == nil)
        #expect(receipt.sourceFingerprint == "legacy-source")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                [LegacyProfile].self,
                from: try #require(defaults.data(forKey: storageKey))
            )
        }
    }

    @Test func corruptProfilePayloadIsQuarantinedWithoutLosingItsBytes() throws {
        let suiteName = "KindleSyncCorrupt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "profiles"
        let corrupt = Data("{ definitely-not-json".utf8)
        defaults.set(corrupt, forKey: storageKey)
        let fixedNow = Date(timeIntervalSince1970: 1_725_000_000)

        let store = KindleSyncProfileStore(
            defaults: defaults,
            storageKey: storageKey,
            now: { fixedNow }
        )

        #expect(store.profiles.isEmpty)
        let quarantineKey: String
        switch store.lastLoadIssue {
        case .corruptDataQuarantined(let key):
            quarantineKey = key
        default:
            Issue.record("Expected corrupt profile data to be quarantined")
            return
        }
        #expect(defaults.data(forKey: storageKey) == nil)
        #expect(defaults.data(forKey: quarantineKey) == corrupt)
        #expect(quarantineKey.contains("1725000000000"))
    }

    @Test func injectedProfileClockControlsLastSeenAt() throws {
        let suiteName = "KindleSyncClock-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let store = KindleSyncProfileStore(
            defaults: defaults,
            storageKey: "profiles",
            now: { fixedNow }
        )
        let info = DeviceInfo(
            name: "Clock Kindle",
            model: "Paperwhite",
            kind: .mtp,
            totalBytes: 1,
            freeBytes: 1,
            identifier: "clock-device"
        )

        #expect(store.ensureProfile(for: info).lastSeenAt == fixedNow)
    }

    @Test func executionReportPreservesEveryOutcomeAndRetriesOnlyProvenSafeWork() {
        let succeededID = UUID()
        let failedID = UUID()
        let unknownID = UUID()
        let selected = [
            executionPlanItem(id: "add|succeeded", bookID: succeededID, title: "Sent"),
            executionPlanItem(id: "add|failed", bookID: failedID, title: "Failed"),
            executionPlanItem(id: "add|unknown", bookID: unknownID, title: "Unknown"),
        ]
        let info = DeviceInfo(
            name: "Test Kindle",
            model: "Paperwhite",
            kind: .massStorage,
            totalBytes: 1,
            freeBytes: 1,
            identifier: "kindle:test"
        )
        var state = KindleSyncExecutionState(selectedItems: selected, deviceInfo: info)
        state.markSucceeded(selected[0].id)
        state.mergeTransferSnapshots([
            failedID: KindleTransferExecutionSnapshot(
                bookID: failedID,
                outcome: .failed,
                progress: 1,
                detail: "Source disappeared",
                retryEligibility: .safe
            ),
            unknownID: KindleTransferExecutionSnapshot(
                bookID: unknownID,
                outcome: .deliveryUnknown,
                progress: 1,
                detail: "Connection ended during delivery",
                retryEligibility: .deliveryUnknown
            ),
        ])

        let report = state.makeReport()

        #expect(report.items.map(\.outcome) == [.succeeded, .failed, .deliveryUnknown])
        #expect(report.safeRetryPlanItemIDs == Set([selected[1].id]))
        #expect(report.succeededCount == 1)
        #expect(report.failedCount == 1)
        #expect(report.deliveryUnknownCount == 1)
        #expect(report.needsMassStorageEjectGuidance)
    }

    @Test func executionProgressIsDeterminateAndCancellationStopsAtItemBoundaries() {
        let selected = [
            executionPlanItem(id: "remove|one", action: .remove, title: "One"),
            executionPlanItem(id: "remove|two", action: .remove, title: "Two"),
            executionPlanItem(id: "remove|three", action: .remove, title: "Three"),
        ]
        let info = DeviceInfo(
            name: "Test Kindle",
            model: "Paperwhite",
            kind: .mtp,
            totalBytes: 1,
            freeBytes: 1,
            identifier: "mtp:test"
        )
        var state = KindleSyncExecutionState(selectedItems: selected, deviceInfo: info)
        state.markSucceeded(selected[0].id)
        state.markRunning(selected[1].id)

        #expect(state.progress.completedCount == 1)
        #expect(state.progress.totalCount == 3)
        #expect(state.progress.fractionCompleted == 1.0 / 3.0)
        #expect(state.progress.currentTitle == "Two")

        state.requestCancellation()
        state.cancelUnfinished()
        let report = state.makeReport()

        #expect(report.cancelledCount == 2)
        #expect(report.safeRetryPlanItemIDs == Set([selected[1].id, selected[2].id]))
        #expect(!report.needsMassStorageEjectGuidance)
    }

    @Test func verifiedPayloadRecoveryIsNeverOfferedAsPlanRetry() {
        let bookID = UUID()
        let item = executionPlanItem(id: "update|book", action: .update, bookID: bookID)
        var state = KindleSyncExecutionState(
            selectedItems: [item],
            deviceInfo: DeviceInfo(
                name: "Test Kindle",
                model: "Scribe",
                kind: .mtp,
                totalBytes: 1,
                freeBytes: 1,
                identifier: "mtp:test"
            )
        )
        state.mergeTransferSnapshots([
            bookID: KindleTransferExecutionSnapshot(
                bookID: bookID,
                outcome: .failed,
                progress: 1,
                detail: "Receipt persistence pending",
                retryEligibility: .durableRecovery
            ),
        ])

        #expect(state.makeReport().safeRetryPlanItemIDs.isEmpty)
    }

    private func executionPlanItem(
        id: String,
        action: KindleSyncAction = .add,
        bookID: UUID? = nil,
        title: String = "Book"
    ) -> KindleSyncPlanItem {
        KindleSyncPlanItem(
            id: id,
            action: action,
            reason: action == .remove ? .onlyOnDevice : .notOnDevice,
            bookID: bookID,
            deviceBookID: action == .remove ? "device|\(id)" : nil,
            deviceFileName: action == .remove ? "\(title).azw3" : nil,
            title: title,
            author: nil,
            sourceFormat: action == .remove ? nil : "EPUB",
            targetFormat: action == .remove ? nil : "AZW3",
            selectedByDefault: true
        )
    }
}
