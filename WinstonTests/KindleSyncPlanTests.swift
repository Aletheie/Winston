import Foundation
import Testing
@testable import Winston

@MainActor
@Suite("Kindle sync plan", .serialized)
struct KindleSyncPlanTests {
    private func candidate(
        title: String = "Dune",
        matchKey: String = "dune",
        sourceFormat: String = "EPUB",
        targetFormat: String = "AZW3",
        fingerprint: String = "source-v2",
        size: UInt64 = 0,
        requiresConversion: Bool = true,
        staleConversion: Bool = false,
        coverVersion: Int = 1,
        hasCover: Bool = true,
        blockReason: KindleSyncReason? = nil
    ) -> KindleSyncCandidate {
        KindleSyncCandidate(
            id: UUID(),
            title: title,
            author: "Frank Herbert",
            matchKey: matchKey,
            sourceFormat: sourceFormat,
            targetFileName: "\(title).\(targetFormat.lowercased())",
            targetFormat: targetFormat,
            sourceFingerprint: fingerprint,
            sendSizeBytes: size,
            requiresConversion: requiresConversion,
            hasStaleTargetConversion: staleConversion,
            coverVersion: coverVersion,
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
        let staleName = try BookFileStore.importCopy(of: staleSource, uuid: UUID())
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

    @Test func collidingLibraryFilenamesAreBlockedInsteadOfOverwritingEachOther() {
        let first = candidate(title: "Dune First Edition", matchKey: "dune")
        let second = candidate(title: "Dune Translation", matchKey: "dune")
        let device = DeviceBook(path: "/documents/Dune.azw3", fileName: "Dune.azw3", sizeBytes: 900)

        let plan = KindleSyncPlanner.makePlan(
            candidates: [first, second],
            deviceBooks: [device],
            profile: profile()
        )

        #expect(plan.count(for: .blocked) == 2)
        #expect(plan.items.filter { $0.action == .blocked }.allSatisfy { $0.reason == .fileNameCollision })
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
}
