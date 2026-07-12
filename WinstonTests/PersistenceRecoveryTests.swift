import Testing
import Foundation
import SwiftData
@testable import Winston

@MainActor
struct PersistenceRecoveryTests {

    private func makeStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "WinstonStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "Winston.store")
    }

    @Test func healthyStoreOpensWithoutRecovery() throws {
        let storeURL = try makeStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        let (container, recovery) = PersistenceController.makeContainer(storeURL: storeURL)
        #expect(recovery == nil)

        let context = ModelContext(container)
        context.insert(Book(fileName: "a.epub", originalFileName: "A.epub"))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 1)
    }

    @Test func corruptStoreIsMovedAsideAndRecreated() throws {
        let storeURL = try makeStoreURL()
        let dir = storeURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("this is definitely not a sqlite database".utf8).write(to: storeURL)

        let (container, recovery) = PersistenceController.makeContainer(storeURL: storeURL)

        guard case .recreatedAfterCorruption(let backupPath) = try #require(recovery) else {
            Issue.record("expected recreatedAfterCorruption")
            return
        }
        let brokenPath = try #require(backupPath)
        #expect(FileManager.default.fileExists(atPath: brokenPath))
        #expect(brokenPath.contains(".broken-"))

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 0)
        context.insert(Book(fileName: "b.epub", originalFileName: "B.epub"))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 1)
    }
}
