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
}
