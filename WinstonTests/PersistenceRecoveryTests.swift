import Foundation
import SwiftData
import Testing
@testable import Winston

@MainActor
@Suite(.serialized)
struct PersistenceRecoveryTests {

    private func makeStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "WinstonStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "Winston.store")
    }

    @Test func `Healthy store opens without recovery`() throws {
        let storeURL = try makeStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        let (container, recovery) = PersistenceController.makeContainer(storeURL: storeURL)
        #expect(recovery == nil)

        let context = ModelContext(container)
        context.insert(Book(fileName: "a.epub", originalFileName: "A.epub"))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 1)
    }

    @Test func `Corrupt store is verified in quarantine before a fresh store opens`() throws {
        let storeURL = try makeStoreURL()
        let dir = storeURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("this is definitely not a sqlite database".utf8).write(to: storeURL)

        let (container, recovery) = PersistenceController.makeContainer(storeURL: storeURL)

        guard case .quarantined(let snapshotURL) = try #require(recovery) else {
            Issue.record("Expected a completed quarantine")
            return
        }
        let snapshotStore = snapshotURL.appending(path: storeURL.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: snapshotStore.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: snapshotURL.appending(path: "manifest.json").path(percentEncoded: false)))

        let manifest = try decodeManifest(at: snapshotURL)
        #expect(manifest.status == .completed)
        #expect(manifest.files.allSatisfy { $0.copySucceeded && $0.originalRemovalSucceeded })
        #expect(manifest.files.allSatisfy { $0.checksum != nil })

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 0)
        context.insert(Book(fileName: "b.epub", originalFileName: "B.epub"))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 1)
    }

    @Test(
        "Operational failures leave every store file untouched",
        arguments: [EACCES, EBUSY, ENOSPC]
    )
    func operationalFailureLeavesStoreUntouched(errno: Int32) throws {
        let storeURL = try makeStoreURL()
        let dir = storeURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("catalog".utf8)
        let wal = Data("pending transaction".utf8)
        try original.write(to: storeURL)
        try wal.write(to: URL(filePath: storeURL.path(percentEncoded: false) + "-wal"))

        var openCount = 0
        let inspector = StoreIntegrityInspector { _ in .healthy }
        let outcome = StoreRecoveryCoordinator(inspector: inspector).open(storeURL: storeURL) { _ in
            openCount += 1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        guard case .retryableFailure(let failure) = outcome else {
            Issue.record("Expected retryable failure for errno \(errno)")
            return
        }
        #expect(failure.kind == .retryable)
        #expect(openCount == 1)
        #expect(try Data(contentsOf: storeURL) == original)
        #expect(try Data(contentsOf: URL(filePath: storeURL.path(percentEncoded: false) + "-wal")) == wal)
        #expect(try recoveryDirectories(in: dir).isEmpty)
    }

    @Test func `Unknown opening failure does not create an active empty store`() throws {
        let storeURL = try makeStoreURL()
        let dir = storeURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("catalog".utf8)
        try original.write(to: storeURL)

        var openCount = 0
        let inspector = StoreIntegrityInspector { _ in .healthy }
        let outcome = StoreRecoveryCoordinator(inspector: inspector).open(storeURL: storeURL) { _ in
            openCount += 1
            throw NSError(domain: "UnexpectedStoreFailure", code: 9001)
        }

        guard case .retryableFailure = outcome else {
            Issue.record("Expected an unknown error to fail closed")
            return
        }
        #expect(openCount == 1)
        #expect(try Data(contentsOf: storeURL) == original)
        #expect(try recoveryDirectories(in: dir).isEmpty)
    }

    @Test func `Incompatible schema requests migration without changing the store`() throws {
        let storeURL = try makeStoreURL()
        let dir = storeURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("older schema".utf8)
        try original.write(to: storeURL)

        let outcome = StoreRecoveryCoordinator().open(storeURL: storeURL) { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: 134100)
        }

        guard case .migrationRequired(let failure) = outcome else {
            Issue.record("Expected migrationRequired")
            return
        }
        #expect(failure.kind == .migrationRequired)
        #expect(try Data(contentsOf: storeURL) == original)
        #expect(try recoveryDirectories(in: dir).isEmpty)
    }

    @Test func `Sidecar cleanup failure preserves a complete snapshot and never opens fresh store`() throws {
        let storeURL = try makeStoreURL()
        let dir = storeURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let walURL = URL(filePath: storeURL.path(percentEncoded: false) + "-wal")
        try Data("corrupt database".utf8).write(to: storeURL)
        try Data("important wal".utf8).write(to: walURL)

        var fileSystem = StoreRecoveryFileSystem.live
        let liveRemove = fileSystem.removeItem
        fileSystem.removeItem = { url in
            if url.lastPathComponent.hasSuffix("-wal") {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
            }
            try liveRemove(url)
        }
        var openCount = 0
        let outcome = StoreRecoveryCoordinator(fileSystem: fileSystem).open(storeURL: storeURL) { _ in
            openCount += 1
            throw NSError(domain: "NSSQLiteErrorDomain", code: 11)
        }

        guard case .readOnlyRecovery(let optionalSnapshotURL, _) = outcome else {
            Issue.record("Expected recovery to stop after partial cleanup")
            return
        }
        let snapshotURL = try #require(optionalSnapshotURL)
        #expect(openCount == 1)
        #expect(FileManager.default.fileExists(atPath: snapshotURL.appending(path: storeURL.lastPathComponent).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: snapshotURL.appending(path: walURL.lastPathComponent).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: walURL.path(percentEncoded: false)))
        let manifest = try decodeManifest(at: snapshotURL)
        #expect(manifest.status == .cleanupFailed)
        #expect(manifest.files.first(where: { $0.originalPath.hasSuffix("-wal") })?.originalRemovalSucceeded == false)
    }

    @Test func `Failure before atomic quarantine commit leaves originals and partial snapshot traceable`() throws {
        let storeURL = try makeStoreURL()
        let dir = storeURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("corrupt database".utf8)
        try original.write(to: storeURL)

        var fileSystem = StoreRecoveryFileSystem.live
        fileSystem.moveItem = { _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        }
        var openCount = 0
        let outcome = StoreRecoveryCoordinator(fileSystem: fileSystem).open(storeURL: storeURL) { _ in
            openCount += 1
            throw NSError(domain: "NSSQLiteErrorDomain", code: 26)
        }

        guard case .readOnlyRecovery(let optionalSnapshotURL, _) = outcome else {
            Issue.record("Expected recovery to stop before cleanup")
            return
        }
        let snapshotURL = try #require(optionalSnapshotURL)
        #expect(openCount == 1)
        #expect(try Data(contentsOf: storeURL) == original)
        #expect(FileManager.default.fileExists(atPath: snapshotURL.appending(path: storeURL.lastPathComponent).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: snapshotURL.appending(path: "manifest.json").path(percentEncoded: false)))

        let relaunchedOutcome = StoreRecoveryCoordinator().open(storeURL: storeURL) { _ in
            openCount += 1
            throw NSError(domain: "ShouldNotOpen", code: 1)
        }
        guard case .readOnlyRecovery(let relaunchedSnapshot, _) = relaunchedOutcome else {
            Issue.record("Expected the persisted recovery checkpoint to block relaunch")
            return
        }
        #expect(relaunchedSnapshot?.lastPathComponent == snapshotURL.lastPathComponent)
        #expect(openCount == 1)
    }

    private func decodeManifest(at snapshotURL: URL) throws -> StoreQuarantineManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            StoreQuarantineManifest.self,
            from: Data(contentsOf: snapshotURL.appending(path: "manifest.json"))
        )
    }

    private func recoveryDirectories(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".recovery-") }
    }
}
