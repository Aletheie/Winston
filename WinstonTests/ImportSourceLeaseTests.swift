import Foundation
import Testing
@testable import Winston

@MainActor
@Suite(.serialized)
struct ImportSourceLeaseTests {
    @Test func duplicateDeviceNamesReceiveUniqueLeasesUntilImportFinishes() async throws {
        let library = try await TestLibrary()
        let store = ImportSourceLeaseStore(
            rootDirectory: AppPaths.deviceImportLeasesDirectory
        )
        let fake = FakeKindleConnection()
        let monitor = DeviceMonitor()
        monitor.adoptConnectionForTesting(
            fake,
            info: FakeKindleConnection.fakeInfo
        )
        let queue = TransferQueue(
            toasts: ToastCenter(),
            importSourceLeases: store
        )
        let deviceBook = DeviceBook(
            path: "documents/Same.epub",
            fileName: "Same.epub",
            sizeBytes: 9
        )

        let first = try #require(
            await queue.copyToLibrary(deviceBook, via: monitor)
        )
        let second = try #require(
            await queue.copyToLibrary(deviceBook, via: monitor)
        )

        #expect(first.directoryURL != second.directoryURL)
        #expect(first.fileURL.lastPathComponent == second.fileURL.lastPathComponent)
        try await Task.sleep(for: .milliseconds(30))
        #expect(FileManager.default.fileExists(
            atPath: first.fileURL.path(percentEncoded: false)
        ))
        #expect(FileManager.default.fileExists(
            atPath: second.fileURL.path(percentEncoded: false)
        ))

        let importer = makeImporter(in: library, leaseStore: store)
        let importedCount = await withCheckedContinuation { continuation in
            importer.addBooks(from: [
                .winstonOwned(first),
                .winstonOwned(second),
            ]) {
                continuation.resume(returning: $0.count)
            }
        }

        #expect(importedCount == 1)
        #expect(!FileManager.default.fileExists(
            atPath: first.directoryURL.path(percentEncoded: false)
        ))
        #expect(!FileManager.default.fileExists(
            atPath: second.directoryURL.path(percentEncoded: false)
        ))
    }

    @Test func cancellationCleansOwnedLeaseAfterTheSessionTerminates() async throws {
        let library = try await TestLibrary()
        let store = ImportSourceLeaseStore(
            rootDirectory: AppPaths.deviceImportLeasesDirectory
        )
        let lease = try makeLease(
            named: "Cancelled.epub",
            contents: "cancel me",
            store: store
        )
        let (analysisEvents, analysisContinuation) = AsyncStream<Void>.makeStream()
        let importer = makeImporter(
            in: library,
            leaseStore: store,
            analyzeBook: { _ in
                analysisContinuation.yield()
                try? await Task.sleep(for: .seconds(60))
                return ImportBookAnalysis(
                    metadata: BookMetadata(),
                    drmProtected: false
                )
            }
        )
        let (completionEvents, completionContinuation) =
            AsyncStream<Int>.makeStream()
        let session = try #require(importer.addBooks(
            from: [.winstonOwned(lease)]
        ) {
            completionContinuation.yield($0.count)
            completionContinuation.finish()
        })

        for await _ in analysisEvents { break }
        #expect(FileManager.default.fileExists(
            atPath: lease.fileURL.path(percentEncoded: false)
        ))
        session.cancel()
        var completedBookCount = -1
        for await count in completionEvents {
            completedBookCount = count
            break
        }

        #expect(completedBookCount == 0)
        #expect(session.step == .cancelled)
        #expect(!FileManager.default.fileExists(
            atPath: lease.directoryURL.path(percentEncoded: false)
        ))
    }

    @Test func rejectedOwnedSourceIsCleanedButExternalSourceIsNeverDeleted() async throws {
        let library = try await TestLibrary()
        let store = ImportSourceLeaseStore(
            rootDirectory: library.root.appending(
                path: "ManagedFiles/DeviceImportLeases",
                directoryHint: .isDirectory
            )
        )
        let rejected = try makeLease(
            named: "Rejected.invalid",
            contents: "unsupported",
            store: store
        )
        let external = library.root.appending(path: "External.epub")
        try Data("external".utf8).write(to: external)
        let importer = makeImporter(in: library, leaseStore: store)

        #expect(importer.addBooks(from: [.winstonOwned(rejected)]) == nil)
        _ = await withCheckedContinuation { continuation in
            importer.addBooks(from: [external]) { _ in
                continuation.resume(returning: ())
            }
        }

        #expect(!FileManager.default.fileExists(
            atPath: rejected.directoryURL.path(percentEncoded: false)
        ))
        #expect(FileManager.default.fileExists(
            atPath: external.path(percentEncoded: false)
        ))
    }

    @Test func failedDeviceCopyRemovesItsNewLease() async throws {
        let library = try await TestLibrary()
        let store = ImportSourceLeaseStore(
            rootDirectory: library.root.appending(
                path: "ManagedFiles/DeviceImportLeases",
                directoryHint: .isDirectory
            )
        )
        let fake = FakeKindleConnection()
        await fake.setFailCopies(true)
        let monitor = DeviceMonitor()
        monitor.adoptConnectionForTesting(
            fake,
            info: FakeKindleConnection.fakeInfo
        )
        let queue = TransferQueue(
            toasts: ToastCenter(),
            importSourceLeases: store
        )

        let result = await queue.copyToLibrary(
            DeviceBook(
                path: "documents/Failure.epub",
                fileName: "Failure.epub",
                sizeBytes: 1
            ),
            via: monitor
        )
        let remaining = try FileManager.default.contentsOfDirectory(
            at: store.rootDirectory,
            includingPropertiesForKeys: nil
        )

        #expect(result == nil)
        #expect(remaining.isEmpty)
    }

    @Test func stalePruningRequiresAnOldValidOwnershipMarker() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WinstonLeasePrune-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportSourceLeaseStore(rootDirectory: root)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = try makeLease(
            named: "Old.epub",
            contents: "old",
            store: store,
            createdAt: now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        let recent = try makeLease(
            named: "Recent.epub",
            contents: "recent",
            store: store,
            createdAt: now.addingTimeInterval(-60)
        )
        let unowned = root.appending(
            path: "user-folder",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: unowned,
            withIntermediateDirectories: false
        )
        try Data("keep".utf8).write(to: unowned.appending(path: "keep.txt"))

        let removed = try store.pruneStaleLeases(
            before: now.addingTimeInterval(-7 * 24 * 60 * 60)
        )

        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(
            atPath: old.directoryURL.path(percentEncoded: false)
        ))
        #expect(FileManager.default.fileExists(
            atPath: recent.directoryURL.path(percentEncoded: false)
        ))
        #expect(FileManager.default.fileExists(
            atPath: unowned.appending(path: "keep.txt").path(percentEncoded: false)
        ))
    }

    private func makeImporter(
        in library: TestLibrary,
        leaseStore: ImportSourceLeaseStore,
        analyzeBook: @escaping @Sendable (URL) async -> ImportBookAnalysis =
            ImportService.defaultAnalysis
    ) -> ImportService {
        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let toasts = ToastCenter()
        return ImportService(
            modelContext: library.context,
            settings: settings,
            metadata: MetadataService(
                modelContext: library.context,
                settings: settings
            ),
            wishlist: WishlistService(
                modelContext: library.context,
                toasts: toasts
            ),
            toasts: toasts,
            importSourceLeases: leaseStore,
            analyzeBook: analyzeBook
        )
    }

    private func makeLease(
        named name: String,
        contents: String,
        store: ImportSourceLeaseStore,
        createdAt: Date = .now
    ) throws -> WinstonImportSourceLease {
        let leaf = try #require(ManagedLeafName(rawValue: name))
        let lease = try store.create(fileName: leaf, createdAt: createdAt)
        try Data(contents.utf8).write(to: lease.fileURL)
        return lease
    }
}
