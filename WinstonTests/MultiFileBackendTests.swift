import Foundation
import SwiftData
import Testing
@testable import Winston

private actor SuspendedConversionWorker {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run(_ source: URL, _ format: EbookConverter.OutputFormat) async throws -> URL {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
        return try Self.makeOutput(format: format, contents: "converted artifact")
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private nonisolated static func makeOutput(
        format: EbookConverter.OutputFormat,
        contents: String
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "WinstonConversion-\(UUID().uuidString).\(format.ext)")
        try Data(contents.utf8).write(to: url)
        return url
    }
}

private actor ImmediateConversionWorker {
    func run(_ source: URL, _ format: EbookConverter.OutputFormat) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "WinstonConversion-\(UUID().uuidString).\(format.ext)")
        try Data("converted artifact".utf8).write(to: url)
        return url
    }
}

private actor ConversionCheckpointGate {
    private var reached = false
    private var reachWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause(at checkpoint: ConversionCheckpoint) async {
        reached = true
        let waiters = reachWaiters
        reachWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { reachWaiters.append($0) }
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@Suite("Multi-file backend", .serialized)
@MainActor
struct MultiFileBackendTests {
    private struct ConversionFixture {
        let book: Book
        let primary: BookAsset
        let target: BookAsset
        let sourceHash: String
        let targetBytes: Data
    }

    private struct InjectedConversionFailure: Error {}

    private func waitForConversion(_ service: ConversionService, book: Book) async {
        let deadline = Date.now.addingTimeInterval(4)
        while service.convertingUUIDs.contains(book.uuid), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!service.convertingUUIDs.contains(book.uuid))
    }

    private func makeConversionFixture(in library: TestLibrary) throws -> ConversionFixture {
        let sourceURL = library.root.appending(path: "conversion-source.epub")
        let targetURL = library.root.appending(path: "conversion-target.mobi")
        let sourceBytes = Data("source generation".utf8)
        let targetBytes = Data("old generated target".utf8)
        try sourceBytes.write(to: sourceURL)
        try targetBytes.write(to: targetURL)

        let bookID = UUID()
        let sourceName = try BookFileStore.importCopy(of: sourceURL, uuid: bookID)
        let targetName = try BookFileStore.importCopy(of: targetURL, uuid: UUID())
        let sourceHash = try ContentHasher.sha256(of: BookFileStore.url(for: sourceName))
        let targetHash = try ContentHasher.sha256(of: BookFileStore.url(for: targetName))
        let book = Book(uuid: bookID, fileName: sourceName, originalFileName: "Conversion Race.epub")
        book.title = "Conversion Race"
        let primary = BookAsset(
            uuid: bookID,
            fileName: sourceName,
            contentHash: sourceHash,
            sizeBytes: Int64(sourceBytes.count),
            validationStatus: .ok,
            book: book
        )
        let target = BookAsset(
            fileName: targetName,
            origin: .generated,
            contentHash: targetHash,
            generatedFromContentHash: sourceHash,
            sizeBytes: Int64(targetBytes.count),
            validationStatus: .ok,
            book: book
        )
        library.context.insert(book)
        library.context.insert(primary)
        library.context.insert(target)
        try library.context.save()
        return ConversionFixture(
            book: book,
            primary: primary,
            target: target,
            sourceHash: sourceHash,
            targetBytes: targetBytes
        )
    }

    private func replacementFile(
        in library: TestLibrary,
        name: String = "user-replacement.mobi",
        contents: String = "newer user file"
    ) throws -> URL {
        let url = library.root.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeCoordinator(
        faultInjector: @escaping ManagedFileCoordinator.FaultInjector = { _ in }
    ) -> ManagedFileCoordinator {
        ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory,
            faultInjector: faultInjector
        )
    }

    @Test func nativeConversionCreatesAndReusesGeneratedSibling() async throws {
        let library = try await TestLibrary()
        let source = try EPUBFixture.make(title: "Sibling", author: "A")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let uuid = UUID()
        let fileName = try BookFileStore.importCopy(of: source, uuid: uuid)
        let originalBytes = try Data(contentsOf: BookFileStore.url(for: fileName))
        let book = Book(uuid: uuid, fileName: fileName, originalFileName: "Sibling.epub")
        let work = Work(title: "Sibling", author: "A")
        let primary = BookAsset(uuid: uuid, fileName: fileName, sizeBytes: Int64(originalBytes.count), book: book)
        library.context.insert(work)
        library.context.insert(book)
        library.context.insert(primary)
        book.work = work
        try library.context.save()

        let service = ConversionService(modelContext: library.context, toasts: ToastCenter())
        service.convert(book, to: .mobi)
        await waitForConversion(service, book: book)

        let generated = try #require(book.assets.first(where: { $0.origin == .generated }))
        #expect(generated.format == "MOBI")
        #expect(FileManager.default.fileExists(atPath: generated.fileURL.path(percentEncoded: false)))
        #expect(try Data(contentsOf: book.fileURL) == originalBytes)
        #expect(book.fileName == fileName)
        #expect(primary.contentHash != nil)
        #expect(generated.generatedFromContentHash == primary.contentHash)

        let generatedUUID = generated.uuid
        service.convert(book, to: .mobi)
        await waitForConversion(service, book: book)
        #expect(book.assets.filter { $0.origin == .generated && $0.format == "MOBI" }.count == 1)
        #expect(book.assets.first(where: { $0.origin == .generated })?.uuid == generatedUUID)
    }

    @Test func changedTargetDuringConversionIsKeptAndResultIsRejected() async throws {
        let library = try await TestLibrary()
        let fixture = try makeConversionFixture(in: library)
        let worker = SuspendedConversionWorker()
        let toasts = ToastCenter()
        let service = ConversionService(
            modelContext: library.context,
            toasts: toasts,
            worker: { try await worker.run($0, $1) }
        )
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter()
        )

        service.convert(fixture.book, to: .mobi)
        await worker.waitUntilStarted()
        let replacement = try replacementFile(in: library)
        await viewModel.replace(fixture.target, in: fixture.book, from: replacement)
        let replacementName = fixture.target.fileName
        let replacementHash = fixture.target.contentHash
        await worker.resume()
        await waitForConversion(service, book: fixture.book)

        #expect(fixture.target.fileName == replacementName)
        #expect(fixture.target.contentHash == replacementHash)
        #expect(fixture.target.origin == .imported)
        #expect(try Data(contentsOf: fixture.target.fileURL) == Data("newer user file".utf8))
        #expect(fixture.book.assets.filter { $0.format == "MOBI" }.count == 1)
        #expect(toasts.messages.contains { $0.style == .info && $0.text.contains("changed during conversion") })
    }

    @Test func deletedTargetDuringConversionIsNotRecreatedByStaleResult() async throws {
        let library = try await TestLibrary()
        let fixture = try makeConversionFixture(in: library)
        let worker = SuspendedConversionWorker()
        let service = ConversionService(
            modelContext: library.context,
            toasts: ToastCenter(),
            worker: { try await worker.run($0, $1) }
        )
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter()
        )

        service.convert(fixture.book, to: .mobi)
        await worker.waitUntilStarted()
        #expect(await viewModel.removeFile(fixture.target, from: fixture.book))
        await worker.resume()
        await waitForConversion(service, book: fixture.book)

        #expect(fixture.target.modelContext == nil)
        #expect(fixture.book.assets.allSatisfy { $0.format != "MOBI" })
    }

    @Test func targetMadePrimaryDuringConversionIsNeverOverwritten() async throws {
        let library = try await TestLibrary()
        let fixture = try makeConversionFixture(in: library)
        let worker = SuspendedConversionWorker()
        let service = ConversionService(
            modelContext: library.context,
            toasts: ToastCenter(),
            worker: { try await worker.run($0, $1) }
        )
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter()
        )

        service.convert(fixture.book, to: .mobi)
        await worker.waitUntilStarted()
        await viewModel.makePrimary(fixture.target, for: fixture.book)
        let primaryName = fixture.target.fileName
        await worker.resume()
        await waitForConversion(service, book: fixture.book)

        #expect(fixture.book.fileName == primaryName)
        #expect(fixture.target.fileName == primaryName)
        #expect(try Data(contentsOf: fixture.target.fileURL) == fixture.targetBytes)
        #expect(fixture.book.assets.filter { $0.format == "MOBI" }.count == 1)
    }

    @Test func recreatedTargetDuringConversionKeepsTheNewAssetGeneration() async throws {
        let library = try await TestLibrary()
        let fixture = try makeConversionFixture(in: library)
        let worker = SuspendedConversionWorker()
        let service = ConversionService(
            modelContext: library.context,
            toasts: ToastCenter(),
            worker: { try await worker.run($0, $1) }
        )
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter()
        )

        service.convert(fixture.book, to: .mobi)
        await worker.waitUntilStarted()
        #expect(await viewModel.removeFile(fixture.target, from: fixture.book))
        let replacement = try replacementFile(in: library, name: "recreated.mobi")
        let recreated = try #require(await viewModel.addFile(to: fixture.book, from: replacement))
        let recreatedID = recreated.uuid
        let recreatedName = recreated.fileName
        await worker.resume()
        await waitForConversion(service, book: fixture.book)

        #expect(recreated.modelContext != nil)
        #expect(recreated.uuid == recreatedID)
        #expect(recreated.fileName == recreatedName)
        #expect(try Data(contentsOf: recreated.fileURL) == Data("newer user file".utf8))
        #expect(fixture.book.assets.filter { $0.format == "MOBI" }.count == 1)
    }

    @Test func inPlaceTargetEditDuringConversionIsProtectedByPhysicalHash() async throws {
        let library = try await TestLibrary()
        let fixture = try makeConversionFixture(in: library)
        let worker = SuspendedConversionWorker()
        let service = ConversionService(
            modelContext: library.context,
            toasts: ToastCenter(),
            worker: { try await worker.run($0, $1) }
        )

        service.convert(fixture.book, to: .mobi)
        await worker.waitUntilStarted()
        let externalBytes = Data("externally replaced bytes".utf8)
        try externalBytes.write(to: fixture.target.fileURL)
        await worker.resume()
        await waitForConversion(service, book: fixture.book)

        #expect(fixture.target.modelContext != nil)
        #expect(try Data(contentsOf: fixture.target.fileURL) == externalBytes)
        #expect(fixture.book.assets.filter { $0.format == "MOBI" }.count == 1)
    }

    @Test func adoptedArtifactUsesTheSameTargetGenerationValidation() async throws {
        let library = try await TestLibrary()
        let fixture = try makeConversionFixture(in: library)
        let gate = ConversionCheckpointGate()
        let service = ConversionService(
            modelContext: library.context,
            toasts: ToastCenter(),
            checkpoint: { await gate.pause(at: $0) }
        )
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter()
        )
        let artifact = try replacementFile(
            in: library,
            name: "queue-artifact.mobi",
            contents: "queue conversion"
        )
        let adoption = Task {
            await service.adoptArtifact(for: fixture.book.uuid, from: artifact)
        }

        await gate.waitUntilReached()
        let replacement = try replacementFile(
            in: library,
            name: "adoption-race.mobi",
            contents: "user wins adoption race"
        )
        await viewModel.replace(fixture.target, in: fixture.book, from: replacement)
        let replacementName = fixture.target.fileName
        await gate.resume()

        #expect(await adoption.value == .conflict)
        #expect(fixture.target.fileName == replacementName)
        #expect(try Data(contentsOf: fixture.target.fileURL) == Data("user wins adoption race".utf8))
        #expect(fixture.book.assets.filter { $0.format == "MOBI" }.count == 1)
    }

    @Test func conversionSaveFailureRestoresBothAssetGenerations() async throws {
        let library = try await TestLibrary()
        let fixture = try makeConversionFixture(in: library)
        let targetName = fixture.target.fileName
        let targetDate = fixture.target.dateAdded
        let targetHash = fixture.target.contentHash
        let coordinator = makeCoordinator()
        let mutations = CatalogMutationService(
            modelContext: library.context,
            saveAdapter: CatalogSaveAdapter { _ in throw InjectedConversionFailure() },
            managedFiles: coordinator
        )
        let worker = ImmediateConversionWorker()
        let service = ConversionService(
            modelContext: library.context,
            toasts: ToastCenter(),
            mutations: mutations,
            managedFiles: coordinator,
            worker: { try await worker.run($0, $1) }
        )

        service.convert(fixture.book, to: .mobi)
        await waitForConversion(service, book: fixture.book)

        #expect(fixture.target.fileName == targetName)
        #expect(fixture.target.dateAdded == targetDate)
        #expect(fixture.target.contentHash == targetHash)
        #expect(fixture.primary.contentHash == fixture.sourceHash)
        #expect(try Data(contentsOf: fixture.target.fileURL) == fixture.targetBytes)
        #expect(!library.context.hasChanges)
        #expect(await coordinator.pendingTransactions().isEmpty)
    }

    @Test func conversionPublishFailureKeepsOldBytesUntilJournalRecovery() async throws {
        let library = try await TestLibrary()
        let fixture = try makeConversionFixture(in: library)
        let targetID = fixture.target.uuid
        let oldTargetName = fixture.target.fileName
        let oldTargetURL = fixture.target.fileURL
        let coordinator = makeCoordinator {
            if case .duringPublish = $0 { throw InjectedConversionFailure() }
        }
        let mutations = CatalogMutationService(
            modelContext: library.context,
            managedFiles: coordinator
        )
        let worker = ImmediateConversionWorker()
        let service = ConversionService(
            modelContext: library.context,
            toasts: ToastCenter(),
            mutations: mutations,
            managedFiles: coordinator,
            worker: { try await worker.run($0, $1) }
        )

        service.convert(fixture.book, to: .mobi)
        await waitForConversion(service, book: fixture.book)

        let committedName = fixture.target.fileName
        #expect(fixture.target.uuid == targetID)
        #expect(committedName != oldTargetName)
        #expect(FileManager.default.fileExists(atPath: oldTargetURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(
            atPath: BookFileStore.url(for: committedName).path(percentEncoded: false)
        ))
        #expect(await coordinator.pendingTransactions().count == 1)

        let restarted = makeCoordinator()
        let recovery = CatalogMutationService(
            modelContext: library.context,
            managedFiles: restarted
        )
        let report = await recovery.recoverManagedFiles()

        #expect(!report.hasPendingWork)
        #expect(!FileManager.default.fileExists(atPath: oldTargetURL.path(percentEncoded: false)))
        #expect(try Data(contentsOf: BookFileStore.url(for: committedName)) == Data("converted artifact".utf8))
        #expect(await restarted.pendingTransactions().isEmpty)
    }

    @Test func missingFileScanUpdatesEveryAssetStatus() async throws {
        let library = try await TestLibrary()
        let existingSource = library.root.appending(path: "existing.epub")
        try Data("book".utf8).write(to: existingSource)
        let book = Book(fileName: "primary.epub", originalFileName: "Primary.epub")
        try library.installBookFile(from: existingSource, fileName: book.fileName)
        let primary = BookAsset(uuid: book.uuid, fileName: book.fileName, book: book)
        let missing = BookAsset(fileName: "missing.mobi", origin: .generated, book: book)
        library.context.insert(book)
        library.context.insert(primary)
        library.context.insert(missing)
        try library.context.save()

        let health = LibraryHealthService(modelContext: library.context)
        #expect(await health.scanForMissingFiles() == 0)
        #expect(primary.validationStatus == .ok)
        #expect(missing.validationStatus == .missing)
    }

    @Test func missingFileScanPreservesCorruptVerdict() async throws {
        let library = try await TestLibrary()
        let existingSource = library.root.appending(path: "existing.epub")
        try Data("book".utf8).write(to: existingSource)
        let book = Book(fileName: "primary.epub", originalFileName: "Primary.epub")
        try library.installBookFile(from: existingSource, fileName: book.fileName)
        let corrupt = BookAsset(uuid: book.uuid, fileName: book.fileName, validationStatus: .corrupt, book: book)
        library.context.insert(book)
        library.context.insert(corrupt)
        try library.context.save()

        let health = LibraryHealthService(modelContext: library.context)
        _ = await health.scanForMissingFiles()
        #expect(corrupt.validationStatus == .corrupt)
    }

    @Test func startupMaintenanceAppliesSizeAndDRMResultsInBatches() async throws {
        let library = try await TestLibrary()
        let source = try EPUBFixture.make(title: "Maintenance", author: "A")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let fileName = try BookFileStore.importCopy(of: source, uuid: UUID())
        let book = Book(fileName: fileName, originalFileName: "Maintenance.epub")
        let asset = BookAsset(uuid: book.uuid, fileName: fileName, book: book)
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()

        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let importer = ImportService(
            modelContext: library.context,
            settings: settings,
            metadata: MetadataService(modelContext: library.context, settings: settings),
            wishlist: WishlistService(modelContext: library.context, toasts: ToastCenter()),
            toasts: ToastCenter()
        )

        await importer.backfillMissingSizes()
        await importer.detectMissingDRM()

        #expect(book.fileSizeBytes > 0)
        #expect(asset.sizeBytes == book.fileSizeBytes)
        #expect(book.drmProtected == false)
    }

    @Test func sizeBackfillDiscardsAResultForAReplacedPrimaryAsset() async throws {
        let library = try await TestLibrary()
        let source = library.root.appending(path: "size-race.epub")
        try Data("original size bytes".utf8).write(to: source)
        let uuid = UUID()
        let fileName = try BookFileStore.importCopy(of: source, uuid: uuid)
        let book = Book(uuid: uuid, fileName: fileName, originalFileName: "Size Race.epub")
        let asset = BookAsset(
            uuid: uuid,
            fileName: fileName,
            contentHash: "original-hash",
            book: book
        )
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()

        let gate = MaintenanceValueGate<Int64>()
        let settings = AppSettings()
        let importer = ImportService(
            modelContext: library.context,
            settings: settings,
            metadata: MetadataService(modelContext: library.context, settings: settings),
            wishlist: WishlistService(modelContext: library.context, toasts: ToastCenter()),
            toasts: ToastCenter(),
            measureFile: { url in await gate.value(for: url) }
        )
        let task = Task { @MainActor in await importer.backfillMissingSizes() }
        await gate.waitUntilStarted()

        asset.dateAdded = asset.dateAdded.addingTimeInterval(1)
        asset.contentHash = "replacement-hash"
        try library.context.save()
        await gate.resume(with: 123_456)
        await task.value

        #expect(book.fileSizeBytes == 0)
        #expect(asset.sizeBytes == 0)
    }

    @Test func drmBackfillDiscardsAResultForAReplacedPrimaryAsset() async throws {
        let library = try await TestLibrary()
        let source = library.root.appending(path: "drm-race.epub")
        try Data("original drm bytes".utf8).write(to: source)
        let uuid = UUID()
        let fileName = try BookFileStore.importCopy(of: source, uuid: uuid)
        let book = Book(uuid: uuid, fileName: fileName, originalFileName: "DRM Race.epub")
        let asset = BookAsset(
            uuid: uuid,
            fileName: fileName,
            contentHash: "original-hash",
            book: book
        )
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()

        let gate = MaintenanceValueGate<Bool>()
        let settings = AppSettings()
        let importer = ImportService(
            modelContext: library.context,
            settings: settings,
            metadata: MetadataService(modelContext: library.context, settings: settings),
            wishlist: WishlistService(modelContext: library.context, toasts: ToastCenter()),
            toasts: ToastCenter(),
            inspectDRM: { url in await gate.value(for: url) }
        )
        let task = Task { @MainActor in await importer.detectMissingDRM() }
        await gate.waitUntilStarted()

        asset.dateAdded = asset.dateAdded.addingTimeInterval(1)
        asset.contentHash = "replacement-hash"
        try library.context.save()
        await gate.resume(with: true)
        await task.value

        #expect(book.drmProtected == nil)
    }

    @Test func missingMetadataRescanLimitsAnalysisConcurrency() async throws {
        let library = try await TestLibrary()
        let books = (0..<4).map { index in
            Book(fileName: "rescan-\(index).epub", originalFileName: "Rescan \(index).epub")
        }
        for book in books {
            let source = library.root.appending(path: "source-\(book.fileName)")
            try Data("rescan fixture".utf8).write(to: source)
            try library.installBookFile(from: source, fileName: book.fileName)
            let asset = BookAsset(uuid: book.uuid, fileName: book.fileName, book: book)
            library.context.insert(book)
            library.context.insert(asset)
        }
        try library.context.save()

        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let probe = MetadataRescanProbe()
        let importer = ImportService(
            modelContext: library.context,
            settings: settings,
            metadata: MetadataService(modelContext: library.context, settings: settings),
            wishlist: WishlistService(modelContext: library.context, toasts: ToastCenter()),
            toasts: ToastCenter(),
            analyzeBook: { url in await probe.analyze(url) }
        )

        await importer.rescanMissingMetadata()

        #expect(await probe.maximumConcurrency() == 1)
        #expect(books.allSatisfy { $0.title != nil })
    }

    @Test func bulkImportBoundsBackgroundAnalysisConcurrency() async throws {
        let library = try await TestLibrary()
        let sources = try (0..<8).map { index in
            let url = library.root.appending(path: "bulk-\(index).epub")
            try Data("book \(index)".utf8).write(to: url)
            return url
        }
        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let probe = MetadataRescanProbe()
        let importer = ImportService(
            modelContext: library.context,
            settings: settings,
            metadata: MetadataService(modelContext: library.context, settings: settings),
            wishlist: WishlistService(modelContext: library.context, toasts: ToastCenter()),
            toasts: ToastCenter(),
            analyzeBook: { url in await probe.analyze(url) }
        )

        importer.addBooks(from: sources)
        #expect(importer.isExtracting)
        let deadline = Date.now.addingTimeInterval(3)
        while (library.context.allBooks().count < sources.count || importer.isExtracting), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let maximumConcurrency = await probe.maximumConcurrency()

        #expect(library.context.allBooks().count == sources.count)
        #expect(maximumConcurrency > 1)
        #expect(maximumConcurrency <= BookDoctorService.defaultMaximumConcurrentInspections)
    }

    @Test func bulkImportCreatesOnlyTheConfiguredNumberOfAnalysisTasks() async throws {
        let library = try await TestLibrary()
        let sources = try (0..<6).map { index in
            let url = library.root.appending(path: "queued-\(index).epub")
            try Data("book \(index)".utf8).write(to: url)
            return url
        }
        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let gate = MetadataQueueGate()
        let importer = ImportService(
            modelContext: library.context,
            settings: settings,
            metadata: MetadataService(modelContext: library.context, settings: settings),
            wishlist: WishlistService(modelContext: library.context, toasts: ToastCenter()),
            toasts: ToastCenter(),
            maximumConcurrentMetadataJobs: 2,
            analyzeBook: { url in await gate.analyze(url) }
        )

        importer.addBooks(from: sources)
        await gate.waitUntilStarted(2)

        #expect(importer.activeMetadataJobCount == 2)
        #expect(importer.pendingMetadataCount == sources.count)

        await gate.resumeAll()
        let deadline = Date.now.addingTimeInterval(2)
        while importer.isExtracting, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            await gate.resumeAll()
        }

        #expect(!importer.isExtracting)
        #expect(await gate.maximumConcurrency() == 2)
    }

    @Test func relinkAfterMakePrimaryUpdatesTheCurrentPrimaryAsset() async throws {
        let library = try await TestLibrary()
        let epubSource = library.root.appending(path: "a.epub")
        let mobiSource = library.root.appending(path: "a.mobi")
        let replacement = library.root.appending(path: "replacement.azw3")
        try Data("epub-bytes".utf8).write(to: epubSource)
        try Data("mobi-bytes".utf8).write(to: mobiSource)
        try Data("azw3-bytes".utf8).write(to: replacement)

        let bookUUID = UUID()
        let mobiUUID = UUID()
        let epubName = try BookFileStore.importCopy(of: epubSource, uuid: bookUUID)
        let mobiName = try BookFileStore.importCopy(of: mobiSource, uuid: mobiUUID)
        let book = Book(uuid: bookUUID, fileName: epubName, originalFileName: "A.epub")
        let epubAsset = BookAsset(uuid: bookUUID, fileName: epubName, book: book)
        let mobiAsset = BookAsset(uuid: mobiUUID, fileName: mobiName, origin: .imported, book: book)
        library.context.insert(book)
        library.context.insert(epubAsset)
        library.context.insert(mobiAsset)
        book.fileName = mobiName
        try library.context.save()

        let health = LibraryHealthService(modelContext: library.context)
        await health.relink(book, from: replacement)

        #expect(mobiAsset.fileName == "\(mobiUUID.uuidString).azw3")
        #expect(book.fileName == mobiAsset.fileName)
        #expect(epubAsset.fileName == epubName)
        #expect(FileManager.default.fileExists(atPath: BookFileStore.url(for: epubName).path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: BookFileStore.url(for: mobiName).path(percentEncoded: false)))
    }

    @Test func sameBytesWithDifferentNamesCreatesDuplicateProposal() async throws {
        let library = try await TestLibrary()
        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let source = try EPUBFixture.make(title: "Duplicate", author: "A")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let second = source.deletingLastPathComponent().appending(path: "same-content.epub")
        try Data(contentsOf: source).write(to: second)
        let metadata = MetadataService(modelContext: library.context, settings: settings)
        let wishlist = WishlistService(modelContext: library.context, toasts: ToastCenter())
        let editions = CatalogReconciliationService(modelContext: library.context)
        let importer = ImportService(
            modelContext: library.context,
            settings: settings,
            metadata: metadata,
            wishlist: wishlist,
            toasts: ToastCenter(),
            editions: editions
        )

        importer.addBooks(from: [source, second])
        #expect(importer.isExtracting)
        let deadline = Date.now.addingTimeInterval(4)
        while (library.context.allBooks().count < 2 || importer.isExtracting), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(library.context.allBooks().count == 2)
        let hasDuplicate = editions.pendingProposals.contains(where: {
            $0.verdict == .duplicateFile && $0.confidence == .high
        })
        #expect(hasDuplicate)
    }

    @Test func validatorDistinguishesMissingCorruptAndValidAssets() async throws {
        let library = try await TestLibrary()
        let invalidEPUB = library.root.appending(path: "invalid.epub")
        let invalidMOBI = library.root.appending(path: "invalid.mobi")
        let validEPUB = try EPUBFixture.make(title: "Valid", author: "A")
        defer { try? FileManager.default.removeItem(at: validEPUB.deletingLastPathComponent()) }
        try Data("not an archive".utf8).write(to: invalidEPUB)
        try Data(repeating: 0, count: 80).write(to: invalidMOBI)

        #expect(BookAssetValidator.validate(url: library.root.appending(path: "missing.epub")) == .missing)
        #expect(BookAssetValidator.validate(url: invalidEPUB) == .corrupt)
        #expect(BookAssetValidator.validate(url: invalidMOBI) == .corrupt)
        #expect(BookAssetValidator.validate(url: validEPUB) == .ok)
    }

    @Test func awaitedHashBackfillFeedsTheFirstEditionScan() async throws {
        let library = try await TestLibrary()
        let bytes = Data("same bytes, unrelated metadata".utf8)
        let source = library.root.appending(path: "shared.epub")
        try bytes.write(to: source)
        var books: [Book] = []
        for (index, title) in ["Alpha", "Beta"].enumerated() {
            let book = Book(fileName: "hash-\(index).epub", originalFileName: "\(title).epub")
            book.title = title
            book.author = "Author \(index)"
            let work = Work(title: title, author: book.author)
            let asset = BookAsset(uuid: book.uuid, fileName: book.fileName, book: book)
            try library.installBookFile(from: source, fileName: book.fileName)
            library.context.insert(work)
            library.context.insert(book)
            library.context.insert(asset)
            book.work = work
            books.append(book)
        }
        try library.context.save()
        let editions = CatalogReconciliationService(modelContext: library.context)

        await editions.scanLibrary()
        #expect(editions.pendingProposals.isEmpty)
        #expect(await BookAssetMaintenance.backfillMissingHashes(context: library.context) == 2)
        await editions.scanLibrary()

        #expect(editions.pendingProposals.contains(where: { $0.verdict == .duplicateFile }))
        #expect(books.allSatisfy { $0.assets.first?.contentHash != nil })
    }

    @Test func targetedImportAllowsSameBasenameButSkipsIdenticalContent() async throws {
        let library = try await TestLibrary()
        let first = try EPUBFixture.make(title: "First Edition", author: "A")
        let second = try EPUBFixture.make(title: "Second Edition", author: "B")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        #expect(first.lastPathComponent == second.lastPathComponent)
        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let metadata = MetadataService(modelContext: library.context, settings: settings)
        let wishlist = WishlistService(modelContext: library.context, toasts: ToastCenter())
        let editions = CatalogReconciliationService(modelContext: library.context)
        let importer = ImportService(
            modelContext: library.context,
            settings: settings,
            metadata: metadata,
            wishlist: wishlist,
            toasts: ToastCenter(),
            editions: editions
        )
        let work = Work(title: "Collected Work")
        library.context.insert(work)
        try library.context.save()

        importer.addBooks(from: [first, second, first], assigningTo: work)
        #expect(importer.isExtracting)
        let deadline = Date.now.addingTimeInterval(4)
        while (work.editions.count < 2 || importer.isExtracting), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(work.editions.count == 2)
        #expect(Set(work.editions.map(\.originalFileName)) == ["book.epub"])
        #expect(Set(work.editions.map { $0.assets.first?.contentHash }).count == 2)
    }

    @Test func regularImportAllowsDifferentFilesWithTheSameBasename() async throws {
        let library = try await TestLibrary()
        let first = try EPUBFixture.make(title: "First", author: "A")
        let second = try EPUBFixture.make(title: "Second", author: "B")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        #expect(first.lastPathComponent == second.lastPathComponent)

        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let importer = ImportService(
            modelContext: library.context,
            settings: settings,
            metadata: MetadataService(modelContext: library.context, settings: settings),
            wishlist: WishlistService(modelContext: library.context, toasts: ToastCenter()),
            toasts: ToastCenter()
        )

        importer.addBooks(from: [first, second])
        let deadline = Date.now.addingTimeInterval(4)
        while (library.context.allBooks().count < 2 || importer.isExtracting), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(library.context.allBooks().count == 2)
        #expect(Set(library.context.allBooks().map(\.displayTitle)) == ["First", "Second"])
    }

    @Test func switchingPrimaryRefreshesBookDRMState() async throws {
        let library = try await TestLibrary()
        let lockedName = "locked.epub"
        let plainName = "plain.mobi"
        let plainSource = library.root.appending(path: plainName)
        try Data("plain sibling".utf8).write(to: plainSource)
        let book = Book(fileName: lockedName, originalFileName: "Book.epub")
        book.drmProtected = true
        let primary = BookAsset(uuid: book.uuid, fileName: lockedName, book: book)
        let sibling = BookAsset(fileName: plainName, origin: .imported, sizeBytes: 13, book: book)
        try library.installBookFile(from: plainSource, fileName: plainName)
        library.context.insert(book)
        library.context.insert(primary)
        library.context.insert(sibling)
        try library.context.save()
        let viewModel = LibraryViewModel(
            modelContext: library.context, settings: AppSettings(), toasts: ToastCenter()
        )

        await viewModel.makePrimary(sibling, for: book)

        #expect(book.fileName == plainName)
        #expect(book.drmProtected == false)
    }

    @Test func hashBackfillDiscardsAResultForAReplacedAsset() async throws {
        let library = try await TestLibrary()
        let book = Book(fileName: "race.epub", originalFileName: "Race.epub")
        let asset = BookAsset(uuid: book.uuid, fileName: book.fileName, book: book)
        let source = library.root.appending(path: "hash-race-source.epub")
        try Data("hash race".utf8).write(to: source)
        try library.installBookFile(from: source, fileName: book.fileName)
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()
        let gate = AssetHashGate()
        let task = Task { @MainActor in
            await BookAssetMaintenance.backfillMissingHashes(
                context: library.context,
                hashFile: { url in await gate.hash(url) }
            )
        }
        await gate.waitUntilStarted()

        asset.dateAdded = asset.dateAdded.addingTimeInterval(1)
        await gate.resume()

        #expect(await task.value == 0)
        #expect(asset.contentHash == nil)
    }

    @Test func hashBackfillSaveFailureDoesNotLeakAHashIntoALaterSave() async throws {
        struct InjectedFailure: Error {}

        let library = try await TestLibrary()
        let book = Book(fileName: "hash-save-failure.epub", originalFileName: "Hash Failure.epub")
        let asset = BookAsset(uuid: book.uuid, fileName: book.fileName, book: book)
        let source = library.root.appending(path: "hash-save-failure-source.epub")
        try Data("stable bytes".utf8).write(to: source)
        try library.installBookFile(from: source, fileName: book.fileName)
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()
        let mutations = CatalogMutationService(
            modelContext: library.context,
            saveAdapter: CatalogSaveAdapter { _ in throw InjectedFailure() }
        )

        #expect(await BookAssetMaintenance.backfillMissingHashes(
            context: library.context,
            mutations: mutations
        ) == 0)
        #expect(asset.contentHash == nil)
        #expect(!library.context.hasChanges)

        book.notes = "unrelated"
        try library.context.save()
        #expect(asset.contentHash == nil)
    }
}

private actor MaintenanceValueGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func value(for url: URL) async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume(with value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private actor AssetHashGate {
    private var continuation: CheckedContinuation<String?, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hash(_ url: URL) async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        continuation?.resume(returning: "hash-from-old-file")
        continuation = nil
    }
}

private actor MetadataRescanProbe {
    private var activeCount = 0
    private var maximumActiveCount = 0

    func analyze(_ url: URL) async -> ImportBookAnalysis {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        try? await Task.sleep(for: .milliseconds(20))
        activeCount -= 1

        var metadata = BookMetadata()
        metadata.title = url.deletingPathExtension().lastPathComponent
        return ImportBookAnalysis(metadata: metadata, drmProtected: false)
    }

    func maximumConcurrency() -> Int { maximumActiveCount }
}

private actor MetadataQueueGate {
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var startedCount = 0
    private var continuations: [CheckedContinuation<ImportBookAnalysis, Never>] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func analyze(_ url: URL) async -> ImportBookAnalysis {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedCount += 1
        resumeSatisfiedWaiters()
        let result = await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        activeCount -= 1
        return result
    }

    func waitUntilStarted(_ count: Int) async {
        guard startedCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func resumeAll() {
        var metadata = BookMetadata()
        metadata.title = "Queued"
        let result = ImportBookAnalysis(metadata: metadata, drmProtected: false)
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: result) }
    }

    func maximumConcurrency() -> Int { maximumActiveCount }

    private func resumeSatisfiedWaiters() {
        let satisfied = waiters.filter { startedCount >= $0.count }
        waiters.removeAll { startedCount >= $0.count }
        satisfied.forEach { $0.continuation.resume() }
    }
}
