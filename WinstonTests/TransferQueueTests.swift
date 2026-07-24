import AppKit
import CoreGraphics
import CoreText
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

    private func targetFileName(for book: Book, format: String) -> String {
        DevicePathAllocator.allocate(
            originalFileName: book.originalFileName,
            targetFormat: format,
            ownerID: book.uuid
        )
    }

    private func makeTextPDF(text: String, at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 24)]
        )
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
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

    @Test func allocatedMatchKeyRemovesOnlyTheIntendedCollidingBook() async {
        let first = Book(fileName: "first.mobi", originalFileName: "book.mobi")
        let second = Book(fileName: "second.mobi", originalFileName: "book.mobi")
        let firstName = targetFileName(for: first, format: "mobi")
        let secondName = targetFileName(for: second, format: "mobi")
        let fake = FakeKindleConnection()
        await fake.setBooks([
            DeviceBook(
                path: "/documents/\(firstName)",
                fileName: firstName,
                sizeBytes: 10
            ),
            DeviceBook(
                path: "/documents/\(secondName)",
                fileName: secondName,
                sizeBytes: 20
            ),
        ])
        let monitor = makeMonitor(fake)
        await monitor.refreshBooks()
        let keys = first.deviceMatchKeys.intersection(monitor.deviceFileNames)

        let removed = await monitor.removeFromDevice(matching: keys)

        #expect(removed == 1)
        #expect(await fake.deletedFileNames == [firstName])
        #expect(monitor.books.map(\.fileName) == [secondName])
    }

    @Test func copyFromDeviceRejectsUnsafeFileName() async {
        let fake = FakeKindleConnection()
        let queue = TransferQueue(toasts: ToastCenter())
        let book = DeviceBook(
            mtpItemID: 1,
            path: nil,
            fileName: "../outside.epub",
            sizeBytes: 10
        )

        let copied = await queue.copyToLibrary(book, via: makeMonitor(fake))

        #expect(copied == nil)
        #expect(queue.items.first?.stage == .failed)
        #expect(queue.lastError == DeviceError.invalidFileName.localizedDescription)
    }

    @Test func sendsMOBIAsIsWithThumbnailAndStaleVariantCleanup() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Fox Book")
        let fake = FakeKindleConnection()
        let queue = TransferQueue(toasts: ToastCenter())

        await queue.send(books: [book], via: makeMonitor(fake))

        let sent = await fake.sentFiles
        let targetName = targetFileName(for: book, format: "mobi")
        #expect(sent.map(\.fileName) == [targetName])
        #expect(sent.first?.byteCount ?? 0 > 0)

        #expect(await fake.staleVariantCalls == [[
            (targetName as NSString).deletingPathExtension,
            targetName,
        ]])

        let thumbnails = await fake.pushedThumbnails
        #expect(thumbnails.count == 1)
        #expect(thumbnails.first?.hasPrefix("thumbnail_") == true)
        #expect(thumbnails.first?.hasSuffix("_EBOK_portrait.jpg") == true)

        #expect(queue.items.allSatisfy { $0.stage == .done })
        #expect(queue.failedCount == 0)
        #expect(queue.completedCount == 1)
        #expect(queue.overallProgress == 1)
    }

    @Test func bulkSendAllocatesDistinctPathsForEqualBasenames() async throws {
        let lib = try await TestLibrary()
        let first = try makeMOBIBook(in: lib, title: "First Collision")
        let second = try makeMOBIBook(in: lib, title: "Second Collision")
        first.originalFileName = "book.mobi"
        second.originalFileName = "book.mobi"
        let fake = FakeKindleConnection()

        await TransferQueue(toasts: ToastCenter()).send(
            books: [first, second],
            via: makeMonitor(fake)
        )

        let sentNames = await fake.sentFiles.map(\.fileName)
        #expect(sentNames == [
            targetFileName(for: first, format: "mobi"),
            targetFileName(for: second, format: "mobi"),
        ])
        #expect(Set(sentNames).count == 2)
        let cleanupBases = await fake.staleVariantCalls.map { $0[0] }
        #expect(Set(cleanupBases).count == 2)
    }

    @Test func separateDirectSendsKeepStableDistinctPathsForEqualBasenames() async throws {
        let lib = try await TestLibrary()
        let first = try makeMOBIBook(in: lib, title: "Direct First")
        let second = try makeMOBIBook(in: lib, title: "Direct Second")
        first.originalFileName = "book.mobi"
        second.originalFileName = "book.mobi"
        let fake = FakeKindleConnection()
        let queue = TransferQueue(toasts: ToastCenter())
        let monitor = makeMonitor(fake)

        await queue.send(books: [first], via: monitor)
        await queue.send(books: [second], via: monitor)

        let sentNames = await fake.sentFiles.map(\.fileName)
        #expect(sentNames == [
            targetFileName(for: first, format: "mobi"),
            targetFileName(for: second, format: "mobi"),
        ])
        #expect(Set(sentNames).count == 2)
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
        #expect(receipt.sentFileName == targetFileName(for: book, format: "mobi"))
        #expect(receipt.coverVersion == book.coverVersion)
    }

    @Test func unhashedCatalogCandidateUsesAssetIdentityWithoutReadingFileDuringPlanning() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Unhashed Receipt")
        var records: [KindleSyncTransferRecord] = []
        let fake = FakeKindleConnection()
        let queue = TransferQueue(
            toasts: ToastCenter(),
            onTransferCompleted: { records.append($0) }
        )

        await queue.send(books: [book], via: makeMonitor(fake))

        let record = try #require(records.first)
        let candidate = KindleSendPreparation.candidate(for: book)
        let deviceBook = DeviceBook(
            path: "/documents/\(record.sentFileName)",
            fileName: record.sentFileName,
            sizeBytes: record.sourceSizeBytes ?? 0
        )
        let receipt = KindleSyncReceipt(
            bookID: record.bookID,
            assetID: record.assetID,
            sourceFormat: record.sourceFormat,
            sourceSizeBytes: record.sourceSizeBytes,
            sourceFingerprint: record.sourceFingerprint,
            sentFileName: record.sentFileName,
            coverVersion: record.coverVersion,
            syncedAt: record.completedAt
        )
        let plan = KindleSyncPlanner.makePlan(
            candidates: [candidate],
            deviceBooks: [deviceBook],
            profile: KindleSyncProfile(
                id: UUID(),
                name: "My Kindle",
                deviceIdentifiers: [FakeKindleConnection.fakeInfo.identifier],
                receipts: [receipt],
                lastSeenAt: .now
            )
        )

        #expect(candidate.sourceFingerprint.hasPrefix("fallback:"))
        #expect(candidate.sourceFingerprint != record.sourceFingerprint)
        #expect(plan.items.first?.action == .keep)
    }

    @Test func selectedSecondaryPDFUsesItsOwnBytesAndReceiptWhenPrimaryIsMissing() async throws {
        let lib = try await TestLibrary()
        let book = Book(
            fileName: "missing-primary.epub",
            originalFileName: "book.epub"
        )
        let primary = BookAsset(
            uuid: book.uuid,
            fileName: book.fileName,
            contentHash: "missing-primary-hash",
            validationStatus: .missing,
            book: book
        )
        let pdfSource = lib.root.appending(path: "secondary.pdf")
        try makeTextPDF(text: "Secondary PDF content.", at: pdfSource)
        let secondaryName = "\(UUID().uuidString).pdf"
        try lib.installBookFile(from: pdfSource, fileName: secondaryName)
        let secondary = BookAsset(
            fileName: secondaryName,
            origin: .generated,
            generatedFromContentHash: "unavailable-primary-generation",
            validationStatus: .ok,
            book: book
        )
        lib.context.insert(book)
        lib.context.insert(primary)
        lib.context.insert(secondary)
        try lib.context.save()
        let expectedHash = try ContentHasher.sha256(of: secondary.fileURL)
        let expectedSize = UInt64(try Data(contentsOf: secondary.fileURL).count)
        var receipts: [KindleSyncTransferRecord] = []
        let fake = FakeKindleConnection()
        let queue = TransferQueue(
            toasts: ToastCenter(),
            onTransferCompleted: { receipts.append($0) }
        )

        await queue.send(asset: secondary, for: book, via: makeMonitor(fake))

        #expect(await fake.sentFiles.count == 1)
        #expect(queue.items.first?.stage == .done)
        let receipt = try #require(receipts.first)
        #expect(receipt.assetID == secondary.uuid)
        #expect(receipt.sourceFormat == "PDF")
        #expect(receipt.sourceSizeBytes == expectedSize)
        #expect(receipt.sourceFingerprint == expectedHash)
        #expect(receipt.sourceFingerprint != primary.contentHash)
        let targetFormat = EbookConverter.needsConversion(format: "PDF")
            ? EbookConverter.kindleTarget(forFormat: "PDF").ext
            : "pdf"
        #expect(receipt.sentFileName == targetFileName(for: book, format: targetFormat))
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
        #expect(sent.map(\.fileName) == [targetFileName(for: book, format: "mobi")])
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

    @Test func cleanupFailurePreventsDoneAndReceipt() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Cleanup Failure")
        let fake = FakeKindleConnection()
        await fake.setFailCleanup(true)
        var receipts: [KindleSyncTransferRecord] = []
        let queue = TransferQueue(
            toasts: ToastCenter(),
            onTransferCompleted: { receipts.append($0) }
        )

        await queue.send(books: [book], via: makeMonitor(fake))

        #expect(await fake.sentFiles.count == 1)
        #expect(queue.items.first?.stage == .failed)
        #expect(queue.completedCount == 0)
        #expect(receipts.isEmpty)
        #expect(await fake.pushedThumbnails.isEmpty)
    }

    @Test func thumbnailFailureFinishesWithReceiptWithoutCoverVersion() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Thumbnail Failure")
        let fake = FakeKindleConnection()
        await fake.setFailThumbnails(true)
        var receipts: [KindleSyncTransferRecord] = []
        let queue = TransferQueue(
            toasts: ToastCenter(),
            onTransferCompleted: { receipts.append($0) }
        )

        await queue.send(books: [book], via: makeMonitor(fake))

        #expect(queue.items.first?.stage == .done)
        #expect(queue.completedCount == 1)
        #expect(receipts.count == 1)
        #expect(receipts.first?.coverVersion == nil)
    }

    @Test func receiptFailurePreventsDoneAfterDevicePostProcessing() async throws {
        struct ReceiptFailure: Error {}

        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Receipt Failure")
        let fake = FakeKindleConnection()
        let queue = TransferQueue(
            toasts: ToastCenter(),
            onTransferCompleted: { _ in throw ReceiptFailure() }
        )

        await queue.send(books: [book], via: makeMonitor(fake))

        #expect(await fake.sentFiles.count == 1)
        #expect(await fake.staleVariantCalls.count == 1)
        #expect(await fake.pushedThumbnails.count == 1)
        #expect(queue.items.first?.stage == .failed)
        #expect(queue.completedCount == 0)
    }

    @Test func cancelKeepsQueueReservedUntilUninterruptibleSendReturns() async throws {
        let lib = try await TestLibrary()
        let first = try makeMOBIBook(in: lib, title: "First")
        let second = try makeMOBIBook(in: lib, title: "Second")
        let fake = FakeKindleConnection()
        await fake.setBlockSends(true)
        var receipts: [KindleSyncTransferRecord] = []
        let queue = TransferQueue(
            toasts: ToastCenter(),
            onTransferCompleted: { receipts.append($0) }
        )
        let monitor = makeMonitor(fake)

        queue.beginSend(books: [first, second], via: monitor)
        await fake.waitUntilSendStarts()
        queue.cancel()

        #expect(queue.isTransferring)
        #expect(queue.items.map(\.stage) == [.cancelling, .cancelled])
        queue.beginSend(books: [second], via: monitor)
        await fake.releaseBlockedSend()

        let deadline = Date.now.addingTimeInterval(2)
        while queue.isTransferring, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(!queue.isTransferring)
        let firstTarget = targetFileName(for: first, format: "mobi")
        #expect(await fake.sentFiles.map(\.fileName) == [firstTarget])
        #expect(queue.items.map(\.stage) == [.done, .cancelled])
        #expect(receipts.map(\.sentFileName) == [firstTarget])
        #expect(queue.failedCount == 0)
    }

    @Test func cooperativeCancellationEndsAsCancelledWithoutReceipt() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Cancelled")
        let fake = FakeKindleConnection()
        await fake.setBlockSendsCooperatively(true)
        var receipts: [KindleSyncTransferRecord] = []
        let queue = TransferQueue(
            toasts: ToastCenter(),
            onTransferCompleted: { receipts.append($0) }
        )

        queue.beginSend(books: [book], via: makeMonitor(fake))
        await fake.waitUntilSendStarts()
        queue.cancel()

        let deadline = Date.now.addingTimeInterval(2)
        while queue.isTransferring, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(!queue.isTransferring)
        #expect(queue.items.first?.stage == .cancelled)
        #expect(await fake.sentFiles.isEmpty)
        #expect(receipts.isEmpty)
        #expect(queue.failedCount == 0)
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
        #expect(await fake.sentFiles.map(\.fileName) == [
            targetFileName(for: book, format: "mobi"),
        ])
        #expect(queue.items.first?.stage == .done)
    }

    @Test func replacingLaterAssetBeforeItsTurnFailsGenerationCheck() async throws {
        let lib = try await TestLibrary()
        let first = try makeMOBIBook(in: lib, title: "Generation First")
        let second = try makeMOBIBook(in: lib, title: "Generation Second")
        let fake = FakeKindleConnection()
        await fake.setBlockSends(true)
        let queue = TransferQueue(toasts: ToastCenter())
        let monitor = makeMonitor(fake)

        queue.beginSend(books: [first, second], via: monitor)
        await fake.waitUntilSendStarts()
        try Data("replacement generation".utf8).write(to: second.fileURL)
        await fake.releaseBlockedSend()

        let deadline = Date.now.addingTimeInterval(2)
        while queue.isTransferring, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(await fake.sentFiles.map(\.fileName) == [
            targetFileName(for: first, format: "mobi"),
        ])
        #expect(queue.items.map(\.stage) == [.done, .failed])
        #expect(queue.lastError == TransferArtifactError.sourceChanged.localizedDescription)
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

        #expect(await fake.sentFiles.map(\.fileName) == [
            targetFileName(for: book, format: "mobi"),
        ])
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

        #expect(await fake.sentFiles.map(\.fileName) == [
            targetFileName(for: book, format: "azw3"),
        ])
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

        #expect(await fake.sentFiles.map(\.fileName) == [
            targetFileName(for: book, format: "mobi"),
        ])
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

        #expect(await fake.sentFiles.map(\.fileName) == [
            targetFileName(for: book, format: "mobi"),
        ])
        let adopted = book.assets.first(where: {
            $0.origin == .generated && $0.format == "MOBI" && $0.validationStatus == .ok
        })
        #expect(adopted != nil)
        #expect(primary.contentHash != nil)
        #expect(adopted?.contentHash != nil)
        #expect(adopted?.generatedFromContentHash == primary.contentHash)
    }
}
