import Foundation
import SwiftData
import Testing
@testable import Winston

@MainActor
@Suite(.serialized)
struct MaintenanceSchedulerTests {
    @Test(arguments: [
        MaintenanceJob.catalogStructure,
        MaintenanceJob.catalogCleanup,
        MaintenanceJob.assetInspection,
        MaintenanceJob.metadataExtraction,
    ])
    func checkpointPersistsOffsetCompletionAndReset(job: MaintenanceJob) throws {
        let suiteName = "MaintenanceSchedulerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = MaintenanceCheckpointStore(defaults: defaults, prefix: "test-maintenance")

        first.setOffset(128, for: job, version: 4)

        let resumed = MaintenanceCheckpointStore(defaults: defaults, prefix: "test-maintenance")
        #expect(resumed.offset(for: job, version: 4) == 128)
        #expect(!resumed.isCompleted(job, version: 4))

        resumed.markCompleted(job, version: 4)
        #expect(resumed.isCompleted(job, version: 4))
        #expect(resumed.offset(for: job, version: 4) == 0)

        resumed.resetAll()
        #expect(!resumed.isCompleted(job, version: 4))
    }

    @Test func catalogStructureChunksResumeAndRemainIdempotent() async throws {
        let library = try await TestLibrary()
        let books = (0 ..< 5).map { index in
            let book = Book(
                fileName: "resume-\(index).epub",
                originalFileName: "Resume \(index).epub",
                dateAdded: Date(timeIntervalSinceReferenceDate: Double(index))
            )
            book.setStatus(.reading)
            library.context.insert(book)
            return book
        }
        try library.context.save()

        let first = try CatalogStructureBackfill.processChunk(
            context: library.context,
            offset: 0,
            limit: 2
        )
        #expect(first.visited == 2)
        #expect(first.hasMore)

        var offset = first.visited
        while offset < books.count {
            let chunk = try CatalogStructureBackfill.processChunk(
                context: library.context,
                offset: offset,
                limit: 2
            )
            offset += chunk.visited
            if chunk.visited == 0 { break }
        }

        #expect(try library.context.fetchCount(FetchDescriptor<BookAsset>()) == books.count)
        #expect(try library.context.fetchCount(FetchDescriptor<Work>()) == books.count)
        #expect(try library.context.fetchCount(FetchDescriptor<ReadingSession>()) == books.count)
        #expect(books.allSatisfy { $0.primaryAssetUUID == $0.uuid })
        #expect(books.allSatisfy { $0.work?.preferredEditionUUID == $0.uuid })

        offset = 0
        while offset < books.count {
            let chunk = try CatalogStructureBackfill.processChunk(
                context: library.context,
                offset: offset,
                limit: 2
            )
            offset += chunk.visited
            if chunk.visited == 0 { break }
        }

        #expect(try library.context.fetchCount(FetchDescriptor<BookAsset>()) == books.count)
        #expect(try library.context.fetchCount(FetchDescriptor<Work>()) == books.count)
        #expect(try library.context.fetchCount(FetchDescriptor<ReadingSession>()) == books.count)
    }

    @Test func catalogStructureRepairsExistingPrimaryAssetDrift() async throws {
        let library = try await TestLibrary()
        let book = Book(fileName: "legacy.epub", originalFileName: "Legacy.epub")
        let asset = BookAsset(
            fileName: "authoritative.pdf",
            sizeBytes: 123,
            validationStatus: .ok,
            book: book
        )
        library.context.insert(book)
        library.context.insert(asset)
        book.primaryAssetUUID = UUID()
        try library.context.save()

        _ = try CatalogStructureBackfill.processChunk(
            context: library.context,
            offset: 0,
            limit: 10
        )

        #expect(book.primaryAssetUUID == asset.uuid)
        #expect(book.fileName == asset.fileName)
        #expect(book.fileSizeBytes == asset.sizeBytes)
    }

    @Test func catalogCleanupPrunesOrphansInChunksAndRemainsIdempotent() async throws {
        let library = try await TestLibrary()
        for index in 0 ..< 3 {
            let book = Book(
                fileName: "linked-\(index).epub",
                originalFileName: "Linked \(index).epub"
            )
            let work = Work(title: "Linked \(index)")
            library.context.insert(book)
            library.context.insert(work)
            book.work = work
        }
        for index in 0 ..< 3 {
            library.context.insert(Work(title: "Orphan \(index)"))
        }
        try library.context.save()

        var offset = 0
        while true {
            let result = try CatalogStructureBackfill.pruneOrphanWorksChunk(
                context: library.context,
                offset: offset,
                limit: 2
            )
            offset = result.nextOffset
            if result.visited == 0 { break }
        }

        #expect(try library.context.fetchCount(FetchDescriptor<Work>()) == 3)
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 3)

        let secondPass = try CatalogStructureBackfill.pruneOrphanWorksChunk(
            context: library.context,
            offset: 0,
            limit: 10
        )
        #expect(secondPass.deleted == 0)
        #expect(try library.context.fetchCount(FetchDescriptor<Work>()) == 3)
    }

    @Test func combinedMobiInspectionReadsBytesOnceForAllDerivedFields() async throws {
        let library = try await TestLibrary()
        let source = library.root.appending(path: "combined.azw3")
        var bytes = [UInt8](repeating: 0, count: 256)
        Array("BOOKMOBI".utf8).enumerated().forEach { offset, byte in
            bytes[60 + offset] = byte
        }
        bytes[76] = 0
        bytes[77] = 1
        bytes[78] = 0
        bytes[79] = 0
        bytes[80] = 0
        bytes[81] = 120
        bytes[132] = 0
        bytes[133] = 2
        try Data(bytes).write(to: source)
        let fileName = "combined.azw3"
        try library.installBookFile(from: source, fileName: fileName)
        let book = Book(fileName: fileName, originalFileName: "Combined.azw3")
        let asset = BookAsset(uuid: book.uuid, fileName: fileName, book: book)
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()
        let input = try #require(AssetInspectionInput(asset: asset, book: book))

        let proposal = try #require(await AssetInspectionPipeline.inspect(input))

        #expect(proposal.output.fileOpenCount == 1)
        #expect(proposal.output.sizeBytes == Int64(bytes.count))
        #expect(proposal.output.contentHash != nil)
        #expect(proposal.output.drmProtected == true)
        #expect(proposal.output.validation == .ok)
    }

    @Test func combinedEPUBInspectionUsesOneSourceOpenForAllDerivedFields() async throws {
        let library = try await TestLibrary()
        let source = try EPUBFixture.make(title: "Single Inspection", author: "Winston")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let fileName = "combined.epub"
        try library.installBookFile(from: source, fileName: fileName)
        let book = Book(fileName: fileName, originalFileName: "Combined.epub")
        let asset = BookAsset(uuid: book.uuid, fileName: fileName, book: book)
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()
        let input = try #require(AssetInspectionInput(asset: asset, book: book))

        let proposal = try #require(await AssetInspectionPipeline.inspect(input))

        #expect(proposal.output.fileOpenCount == 1)
        #expect(proposal.output.sizeBytes > 0)
        #expect(proposal.output.contentHash != nil)
        #expect(proposal.output.drmProtected == false)
        #expect(proposal.output.validation == .ok)
    }

    @Test func assetInspectionChunkCommitsSizeHashDRMAndValidationTogether() async throws {
        let library = try await TestLibrary()
        let source = library.root.appending(path: "inspection.txt")
        try Data("one pipeline, one catalog commit".utf8).write(to: source)
        let fileName = "inspection.txt"
        try library.installBookFile(from: source, fileName: fileName)
        let book = Book(fileName: fileName, originalFileName: "Inspection.txt")
        let asset = BookAsset(uuid: book.uuid, fileName: fileName, book: book)
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()
        let mutations = CatalogMutationService(modelContext: library.context)

        let result = try await AssetInspectionMaintenance.processChunk(
            context: library.context,
            mutations: mutations,
            offset: 0,
            limit: 10
        )

        #expect(result.inspected == 1)
        #expect(result.failed == 0)
        #expect(result.fileOpenCount == 1)
        #expect(asset.sizeBytes > 0)
        #expect(book.fileSizeBytes == asset.sizeBytes)
        #expect(asset.contentHash != nil)
        #expect(book.drmProtected == false)
        #expect(asset.validationStatus == .ok)
    }

    @Test func assetChangedDuringInspectionIsRejectedAndScheduledForRetry() async throws {
        let library = try await TestLibrary()
        let source = library.root.appending(path: "changing.txt")
        try Data("generation one".utf8).write(to: source)
        let fileName = "changing.txt"
        try library.installBookFile(from: source, fileName: fileName)
        let book = Book(fileName: fileName, originalFileName: "Changing.txt")
        let asset = BookAsset(uuid: book.uuid, fileName: fileName, book: book)
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()
        let mutations = CatalogMutationService(modelContext: library.context)
        let gate = AssetInspectionGate()

        let inspection = Task { @MainActor in
            try await AssetInspectionMaintenance.processChunk(
                context: library.context,
                mutations: mutations,
                offset: 0,
                limit: 10,
                inspect: { input in
                    await gate.inspect(input)
                }
            )
        }
        await gate.waitUntilStarted()
        asset.dateAdded = asset.dateAdded.addingTimeInterval(1)
        try library.context.save()
        await gate.resume()

        let result = try await inspection.value
        #expect(result.inspected == 0)
        #expect(result.failed == 1)
        #expect(asset.sizeBytes == 0)
        #expect(asset.contentHash == nil)
        #expect(asset.validationStatus == nil)
        #expect(book.fileSizeBytes == 0)
        #expect(book.drmProtected == nil)
    }
}

private actor AssetInspectionGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func inspect(_ input: AssetInspectionInput) async -> AssetInspectionProposal? {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
        return await AssetInspectionPipeline.inspect(input)
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
