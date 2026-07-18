import Testing
import Foundation
import SwiftData
@testable import Winston

@MainActor
@Suite(.serialized)
struct TransferQueueTests {

    private func makeMonitor(_ fake: FakeKindleConnection) -> DeviceMonitor {
        let monitor = DeviceMonitor()
        monitor.adoptConnectionForTesting(fake, info: FakeKindleConnection.fakeInfo)
        return monitor
    }

    private func makeMOBIBook(in lib: TestLibrary, title: String) throws -> Book {
        let epub = try EPUBFixture.make(title: title, author: "A")
        defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent()) }
        let mobi = try MOBIWriter.write(epub: epub)
        defer { try? FileManager.default.removeItem(at: mobi) }

        let book = Book(fileName: "\(UUID().uuidString).mobi", originalFileName: "\(title).mobi")
        try lib.installBookFile(from: mobi, fileName: book.fileName)
        return book
    }

    private func makeEPUBBook(in lib: TestLibrary, title: String) throws -> Book {
        let epub = try EPUBFixture.make(title: title, author: "A")
        defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent()) }
        let book = Book(fileName: "\(UUID().uuidString).epub", originalFileName: "\(title).epub")
        try lib.installBookFile(from: epub, fileName: book.fileName)
        return book
    }

    @Test func deviceMonitorCachesMatchKeysAndPublishesACheapRevision() async {
        let fake = FakeKindleConnection()
        let monitor = makeMonitor(fake)
        let books = [
            DeviceBook(path: "/documents/First.epub", fileName: "First.epub", sizeBytes: 10),
            DeviceBook(path: "/documents/Second.azw3", fileName: "Second.azw3", sizeBytes: 20),
        ]
        await fake.setBooks(books)
        let before = monitor.booksRevision

        await monitor.refreshBooks()

        #expect(monitor.booksRevision == before + 1)
        #expect(monitor.deviceFileNames == ["first", "second"])

        await monitor.refreshBooks()
        #expect(monitor.booksRevision == before + 1)

        monitor.removeBooksLocally([books[0].id])
        #expect(monitor.booksRevision == before + 2)
        #expect(monitor.deviceFileNames == ["second"])
    }

    @Test func sendsMOBIAsIsWithThumbnailAndStaleVariantCleanup() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Fox Book")
        let fake = FakeKindleConnection()
        let queue = TransferQueue(toasts: ToastCenter())

        await queue.send(books: [book], via: makeMonitor(fake))

        let sent = await fake.sentFiles
        #expect(sent.map(\.fileName) == ["Fox Book.mobi"])
        #expect(sent.first?.byteCount ?? 0 > 0)

        #expect(await fake.staleVariantCalls == [["Fox Book", "Fox Book.mobi"]])

        let thumbnails = await fake.pushedThumbnails
        #expect(thumbnails.count == 1)
        #expect(thumbnails.first?.hasPrefix("thumbnail_") == true)
        #expect(thumbnails.first?.hasSuffix("_EBOK_portrait.jpg") == true)

        #expect(queue.items.allSatisfy { $0.stage == .done })
        #expect(queue.failedCount == 0)
        #expect(queue.completedCount == 1)
        #expect(queue.overallProgress == 1)
    }

    @Test func successfulSendRecordsReceiptForTheConnectedKindleProfile() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Receipt Book")
        let suiteName = "TransferQueueReceipt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profiles = KindleSyncProfileStore(defaults: defaults, storageKey: "profiles")
        let fake = FakeKindleConnection()
        let monitor = makeMonitor(fake)
        let queue = TransferQueue(
            toasts: ToastCenter(),
            onTransferCompleted: { profiles.record($0) }
        )

        await queue.send(books: [book], via: monitor)

        let profile = try #require(profiles.profile(for: FakeKindleConnection.fakeInfo))
        let receipt = try #require(profiles.receipts(for: profile.id)[book.uuid])
        #expect(receipt.sentFileName == "Receipt Book.mobi")
        #expect(receipt.coverVersion == book.coverVersion)
    }

    @Test(.enabled(if: !EbookConverter.prefersAZW3ForKindle))
    func convertsEPUBBeforeSending() async throws {
        let lib = try await TestLibrary()
        let book = try makeEPUBBook(in: lib, title: "Epub Book")
        let temporaryOutput = FileManager.default.temporaryDirectory
            .appending(path: "WinstonConversions", directoryHint: .isDirectory)
            .appending(path: book.fileURL.deletingPathExtension().lastPathComponent + ".mobi")
        try? FileManager.default.removeItem(at: temporaryOutput)
        let fake = FakeKindleConnection()
        let queue = TransferQueue(toasts: ToastCenter())

        await queue.send(books: [book], via: makeMonitor(fake))

        let sent = await fake.sentFiles
        #expect(sent.map(\.fileName) == ["Epub Book.mobi"])
        #expect(queue.items.allSatisfy { $0.stage == .done })
        #expect(!FileManager.default.fileExists(atPath: temporaryOutput.path(percentEncoded: false)))
    }

    @Test func skipsDRMProtectedBookWithoutSending() async throws {
        let lib = try await TestLibrary()
        let book = try makeEPUBBook(in: lib, title: "Locked Book")
        book.drmProtected = true
        let fake = FakeKindleConnection()
        let queue = TransferQueue(toasts: ToastCenter())

        await queue.send(books: [book], via: makeMonitor(fake))

        #expect(await fake.sentFiles.isEmpty)
        #expect(queue.items.first?.stage == .failed)
        #expect(queue.lastError == "DRM-protected")
    }

    @Test func skipsDRMProtectedNativeKindleFormatWithoutSending() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Locked Native")
        book.drmProtected = true
        let fake = FakeKindleConnection()
        let queue = TransferQueue(toasts: ToastCenter())

        await queue.send(books: [book], via: makeMonitor(fake))

        #expect(await fake.sentFiles.isEmpty)
        #expect(queue.items.first?.stage == .failed)
        #expect(queue.lastError == "DRM-protected")
    }

    @Test func deviceVanishingFailsRemainderAndDisconnects() async throws {
        let lib = try await TestLibrary()
        let books = [try makeMOBIBook(in: lib, title: "One"),
                     try makeMOBIBook(in: lib, title: "Two")]
        let fake = FakeKindleConnection()
        await fake.setAlive(false)
        let monitor = makeMonitor(fake)
        let queue = TransferQueue(toasts: ToastCenter())

        await queue.send(books: books, via: monitor)

        #expect(await fake.sentFiles.isEmpty)
        #expect(queue.items.allSatisfy { $0.stage == .failed })
        #expect(queue.lastError == "Device disconnected")
        #expect(monitor.connection == nil)
        #expect(!monitor.isConnected)
    }

    @Test func transportFailureMarksItemsFailed() async throws {
        let lib = try await TestLibrary()
        let books = [try makeMOBIBook(in: lib, title: "One"),
                     try makeMOBIBook(in: lib, title: "Two")]
        let fake = FakeKindleConnection()
        await fake.setFailSends(true)
        let queue = TransferQueue(toasts: ToastCenter())

        await queue.send(books: books, via: makeMonitor(fake))

        #expect(await fake.sentFiles.isEmpty)
        #expect(queue.items.allSatisfy { $0.stage == .failed })
        #expect(queue.failedCount == 2)
        #expect(queue.completedCount == 0)
        #expect(queue.lastError != nil)
        #expect(await fake.staleVariantCalls.isEmpty)
        #expect(await fake.pushedThumbnails.isEmpty)
    }

    @Test func cancelKeepsQueueReservedUntilUninterruptibleSendReturns() async throws {
        let lib = try await TestLibrary()
        let first = try makeMOBIBook(in: lib, title: "First")
        let second = try makeMOBIBook(in: lib, title: "Second")
        let fake = FakeKindleConnection()
        await fake.setBlockSends(true)
        let queue = TransferQueue(toasts: ToastCenter())
        let monitor = makeMonitor(fake)

        queue.beginSend(books: [first], via: monitor)
        await fake.waitUntilSendStarts()
        queue.cancel()

        #expect(queue.isTransferring)
        queue.beginSend(books: [second], via: monitor)
        await fake.releaseBlockedSend()

        let deadline = Date.now.addingTimeInterval(2)
        while queue.isTransferring, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(!queue.isTransferring)
        #expect(await fake.sentFiles.map(\.fileName) == ["First.mobi"])
        #expect(queue.items.first?.stage == .failed)
    }

    @Test func deletingLibraryBookDuringSendDoesNotInvalidateQueue() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Delete Mid Send")
        let managedFileName = book.fileName
        lib.context.insert(book)
        try lib.context.save()

        let fake = FakeKindleConnection()
        await fake.setBlockSends(true)
        let queue = TransferQueue(toasts: ToastCenter())
        queue.beginSend(books: [book], via: makeMonitor(fake))
        await fake.waitUntilSendStarts()

        lib.context.delete(book)
        try lib.context.save()
        BookFileStore.delete(fileName: managedFileName)
        await fake.releaseBlockedSend()

        let deadline = Date.now.addingTimeInterval(2)
        while queue.isTransferring, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(!queue.isTransferring)
        #expect(await fake.sentFiles.map(\.fileName) == ["Delete Mid Send.mobi"])
        #expect(queue.items.first?.stage == .done)
    }

    @Test func usesMOBISiblingWithoutConversionWhenPrimaryIsEPUB() async throws {
        let lib = try await TestLibrary()
        let book = try makeEPUBBook(in: lib, title: "Sibling Pick")
        let sourceHash = try ContentHasher.sha256(of: book.fileURL)
        let primary = BookAsset(
            uuid: book.uuid, fileName: book.fileName, contentHash: sourceHash,
            validationStatus: .ok, book: book
        )
        let mobiURL = lib.root.appending(path: "sibling.mobi")
        try Data("mobi sibling".utf8).write(to: mobiURL)
        let siblingName = try BookFileStore.importCopy(of: mobiURL, uuid: UUID())
        let sibling = BookAsset(
            fileName: siblingName, origin: .generated,
            generatedFromContentHash: sourceHash, validationStatus: .ok, book: book
        )
        lib.context.insert(book)
        lib.context.insert(primary)
        lib.context.insert(sibling)
        try lib.context.save()
        let fake = FakeKindleConnection()

        await TransferQueue(toasts: ToastCenter()).send(books: [book], via: makeMonitor(fake))

        #expect(await fake.sentFiles.map(\.fileName) == ["Sibling Pick.mobi"])
        #expect(await fake.sentFiles.first?.byteCount == Data("mobi sibling".utf8).count)
    }

    @Test func AZW3SiblingWinsWhenPreferenceIsEnabled() async throws {
        let lib = try await TestLibrary()
        let old = UserDefaults.standard.bool(forKey: "preferKindleAZW3")
        UserDefaults.standard.set(true, forKey: "preferKindleAZW3")
        defer { UserDefaults.standard.set(old, forKey: "preferKindleAZW3") }
        let book = try makeEPUBBook(in: lib, title: "Preferred")
        let sourceHash = try ContentHasher.sha256(of: book.fileURL)
        let primary = BookAsset(
            uuid: book.uuid, fileName: book.fileName, contentHash: sourceHash,
            validationStatus: .ok, book: book
        )
        for (ext, bytes) in [("mobi", "mobi"), ("azw3", "azw3 preferred")] {
            let source = lib.root.appending(path: "sibling.\(ext)")
            try Data(bytes.utf8).write(to: source)
            let name = try BookFileStore.importCopy(of: source, uuid: UUID())
            lib.context.insert(BookAsset(
                fileName: name, origin: .generated,
                generatedFromContentHash: sourceHash, validationStatus: .ok, book: book
            ))
        }
        lib.context.insert(book)
        lib.context.insert(primary)
        try lib.context.save()
        let fake = FakeKindleConnection()

        await TransferQueue(toasts: ToastCenter()).send(books: [book], via: makeMonitor(fake))

        #expect(await fake.sentFiles.map(\.fileName) == ["Preferred.azw3"])
        #expect(await fake.sentFiles.first?.byteCount == Data("azw3 preferred".utf8).count)
    }

    @Test(.enabled(if: !EbookConverter.prefersAZW3ForKindle))
    func staleGeneratedSiblingIsIgnoredAfterPrimaryChanges() async throws {
        let lib = try await TestLibrary()
        let book = try makeEPUBBook(in: lib, title: "Fresh Source")
        let sourceHash = try ContentHasher.sha256(of: book.fileURL)
        let primary = BookAsset(
            uuid: book.uuid, fileName: book.fileName, contentHash: sourceHash,
            validationStatus: .ok, book: book
        )
        let staleBytes = Data("stale mobi".utf8)
        let staleURL = lib.root.appending(path: "stale.mobi")
        try staleBytes.write(to: staleURL)
        let staleName = try BookFileStore.importCopy(of: staleURL, uuid: UUID())
        let stale = BookAsset(
            fileName: staleName, origin: .generated,
            generatedFromContentHash: "previous-primary-hash", validationStatus: .ok, book: book
        )
        lib.context.insert(book)
        lib.context.insert(primary)
        lib.context.insert(stale)
        try lib.context.save()
        let fake = FakeKindleConnection()

        await TransferQueue(toasts: ToastCenter()).send(books: [book], via: makeMonitor(fake))

        #expect(await fake.sentFiles.map(\.fileName) == ["Fresh Source.mobi"])
        #expect(await fake.sentFiles.first?.byteCount != staleBytes.count)
    }

    @Test(.enabled(if: !EbookConverter.prefersAZW3ForKindle))
    func missingSiblingIsSkippedAndConversionArtifactIsAdopted() async throws {
        let lib = try await TestLibrary()
        let book = try makeEPUBBook(in: lib, title: "Adopt")
        let primary = BookAsset(uuid: book.uuid, fileName: book.fileName, validationStatus: .ok, book: book)
        let missing = BookAsset(fileName: "missing.mobi", origin: .generated, validationStatus: .missing, book: book)
        lib.context.insert(book)
        lib.context.insert(primary)
        lib.context.insert(missing)
        try lib.context.save()
        let settings = AppSettings()
        let viewModel = LibraryViewModel(modelContext: lib.context, settings: settings, toasts: ToastCenter())
        let queue = TransferQueue(
            toasts: ToastCenter(),
            onConversionArtifact: { uuid, url in await viewModel.adoptConversionArtifact(for: uuid, from: url) }
        )
        let fake = FakeKindleConnection()

        await queue.send(books: [book], via: makeMonitor(fake))

        #expect(await fake.sentFiles.map(\.fileName) == ["Adopt.mobi"])
        let adopted = book.assets.first(where: {
            $0.origin == .generated && $0.format == "MOBI" && $0.validationStatus == .ok
        })
        #expect(adopted != nil)
        #expect(primary.contentHash != nil)
        #expect(adopted?.contentHash != nil)
        #expect(adopted?.generatedFromContentHash == primary.contentHash)
    }
}
