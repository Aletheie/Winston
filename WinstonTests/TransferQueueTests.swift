import AppKit
import CoreGraphics
import CoreText
import Testing
import Foundation
import SwiftData
@testable import Winston

private struct InjectedJournalFailure: Error {}

private final class JournalCheckpointFault: @unchecked Sendable {
    private let lock = NSLock()
    private let state: DurableTransferItemState
    private var failuresRemaining: Int

    init(
        state: DurableTransferItemState,
        failuresRemaining: Int = 1
    ) {
        self.state = state
        self.failuresRemaining = failuresRemaining
    }

    func check(_ job: DurableTransferJob) throws {
        lock.lock()
        defer { lock.unlock() }
        guard failuresRemaining > 0,
              job.items.contains(where: { $0.state == state }) else {
            return
        }
        failuresRemaining -= 1
        throw InjectedJournalFailure()
    }
}

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

    private func makeJournalDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(
                path: "WinstonTransferJournal-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
    }

    private func waitUntilFinished(_ queue: TransferQueue) async {
        let deadline = Date.now.addingTimeInterval(2)
        while queue.isTransferring, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func durableItem(
        for book: Book,
        state: DurableTransferItemState
    ) throws -> DurableTransferItem {
        let descriptor = KindleSendPreparation.descriptor(for: book)
        let generation = try #require(
            TransferFileGeneration.capture(at: descriptor.sourceURL)
        )
        let payload: DurableTransferPayload? = switch state {
        case .inFlight, .deliveryUnknown, .payloadCommitted:
            DurableTransferPayload(
                attemptID: UUID(),
                destinationFileName: descriptor.targetFileName,
                expectedByteCount: UInt64(max(0, generation.fileSize)),
                artifactFingerprint: nil,
                transportIdentifier: state == .payloadCommitted
                    ? "test-transport"
                    : nil,
                payloadCommittedAt: state == .payloadCommitted ? .now : nil,
                conversionAdopted: false,
                staleVariantsRemoved: false,
                coverProcessed: false,
                coverPushed: false,
                receiptPersisted: false
            )
        case .pending, .completed, .failed, .cancelled:
            nil
        }
        return DurableTransferItem(
            descriptor: descriptor,
            sourceFileGeneration: generation,
            state: state,
            detail: nil,
            payload: payload
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
        #expect(monitor.lastInventoryDelta.fromGeneration == before)
        #expect(monitor.lastInventoryDelta.toGeneration == before + 1)
        #expect(Set(monitor.lastInventoryDelta.inserted.map(\.id)) == Set(books.map(\.id)))
        #expect(monitor.lastInventoryDelta.updated.isEmpty)
        #expect(monitor.lastInventoryDelta.removed.isEmpty)

        await monitor.refreshBooks()
        #expect(monitor.booksRevision == before + 1)

        monitor.removeBooksLocally([books[0].id])
        #expect(monitor.booksRevision == before + 2)
        #expect(monitor.deviceFileNames == ["second"])
        #expect(monitor.lastInventoryDelta.fromGeneration == before + 1)
        #expect(monitor.lastInventoryDelta.toGeneration == before + 2)
        #expect(monitor.lastInventoryDelta.removed.map(\.id) == [books[0].id])
        #expect(monitor.lastInventoryDelta.changedMatchKeys == ["first"])
    }

    @Test func successfulEjectClearsTheMonitorOnlyAfterAcknowledgement() async throws {
        let fake = FakeKindleConnection()
        let monitor = makeMonitor(fake)
        let book = DeviceBook(
            path: "documents/book.epub",
            fileName: "book.epub",
            sizeBytes: 10
        )
        await fake.setBooks([book])
        await monitor.refreshBooks()

        try await monitor.userDisconnect()

        #expect(await fake.ejected)
        #expect(!monitor.isEjecting)
        #expect(monitor.connection == nil)
        #expect(monitor.state == .disconnected)
        #expect(monitor.books.isEmpty)
        #expect(monitor.lastError == nil)
    }

    @Test func failedEjectKeepsTheLiveConnectionAndInventory() async {
        let fake = FakeKindleConnection()
        let monitor = makeMonitor(fake)
        let book = DeviceBook(
            path: "documents/book.epub",
            fileName: "book.epub",
            sizeBytes: 10
        )
        await fake.setBooks([book])
        await fake.setFailEject(true)
        await monitor.refreshBooks()

        await #expect(throws: CocoaError.self) {
            try await monitor.userDisconnect()
        }

        #expect(await fake.ejected)
        #expect(!monitor.isEjecting)
        #expect(monitor.connection != nil)
        #expect(monitor.info == FakeKindleConnection.fakeInfo)
        #expect(monitor.books == [book])
        #expect(monitor.lastError != nil)
    }

    @Test func physicalDisconnectDuringFailedEjectReconcilesAsSuccess() async throws {
        let fake = FakeKindleConnection()
        let monitor = makeMonitor(fake)
        let book = DeviceBook(
            path: "documents/book.epub",
            fileName: "book.epub",
            sizeBytes: 10
        )
        await fake.setBooks([book])
        await fake.setFailEject(true)
        await fake.setBlockEject(true)
        await monitor.refreshBooks()

        let eject = Task {
            try await monitor.userDisconnect()
        }
        await fake.waitUntilEjectStarts()
        #expect(monitor.isEjecting)
        await fake.setAlive(false)
        await fake.releaseBlockedEject()
        try await eject.value

        #expect(!monitor.isEjecting)
        #expect(monitor.connection == nil)
        #expect(monitor.state == .disconnected)
        #expect(monitor.books.isEmpty)
        #expect(monitor.lastError == nil)
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

    @Test func transferPlannerFreezesAssetGenerationAndDeviceDestination() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Immutable Plan")
        let descriptor = KindleSendPreparation.descriptor(for: book)
        let destination = targetFileName(for: book, format: "mobi")
        let existing = DeviceBook(
            path: "documents/\(destination)",
            fileName: destination,
            sizeBytes: 10
        )

        let plan = TransferPlanner.makePlan(
            readModel: [descriptor],
            inventory: DeviceInventorySnapshot(
                info: FakeKindleConnection.fakeInfo,
                books: [existing]
            )
        )

        let item = try #require(plan.items.first)
        #expect(plan.deviceIdentifier == FakeKindleConnection.fakeInfo.identifier)
        #expect(item.destination.fileName == destination)
        #expect(item.existingDeviceBookID == existing.id)
        #expect(item.sourceFileGeneration == TransferFileGeneration.capture(at: book.fileURL))

        try Data("new generation".utf8).write(to: book.fileURL)
        #expect(item.sourceFileGeneration != TransferFileGeneration.capture(at: book.fileURL))
    }

    @Test func durableJournalExistsBeforeTransportAndIsRemovedAfterCancellation() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Durable Pending")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TransferQueueJournalStore(directory: directory)
        let fake = FakeKindleConnection()
        await fake.setBlockSends(true)
        let queue = TransferQueue(
            toasts: ToastCenter(),
            journalDirectory: directory
        )

        queue.beginSend(books: [book], via: makeMonitor(fake))
        await fake.waitUntilSendStarts()

        let pending = try #require(store.load().job)
        #expect(pending.items.map(\.state) == [.inFlight])
        #expect(pending.items.first?.sourceFileGeneration == TransferFileGeneration.capture(at: book.fileURL))

        queue.cancel()
        await fake.releaseBlockedSend()
        let deadline = Date.now.addingTimeInterval(2)
        while queue.isTransferring, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(!queue.isTransferring)
        #expect(store.load().job == nil)
    }

    @Test func initialJournalSaveFailureTouchesNoDevice() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Initial Checkpoint")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = JournalCheckpointFault(state: .pending)
        let store = TransferQueueJournalStore(
            directory: directory,
            beforeSave: fault.check
        )
        let fake = FakeKindleConnection()
        let queue = TransferQueue(
            toasts: ToastCenter(),
            journalStoreOverride: store
        )

        await queue.send(books: [book], via: makeMonitor(fake))

        #expect(await fake.transferAttempts == 0)
        #expect(await fake.sentFiles.isEmpty)
        #expect(queue.lastError != nil)
        #expect(store.load().job == nil)
    }

    @Test func inFlightCheckpointFailureStopsBeforeTransport() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "In Flight Checkpoint")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = JournalCheckpointFault(state: .inFlight)
        let store = TransferQueueJournalStore(
            directory: directory,
            beforeSave: fault.check
        )
        let fake = FakeKindleConnection()
        let queue = TransferQueue(
            toasts: ToastCenter(),
            journalStoreOverride: store
        )

        await queue.send(books: [book], via: makeMonitor(fake))

        #expect(await fake.transferAttempts == 0)
        #expect(store.load().job?.items.map(\.state) == [.pending])
        #expect(queue.items.first?.stage == .failed)
        #expect(queue.pendingTransferCount == 1)
    }

    @Test func payloadCheckpointFailureNeverResendsAfterRestart() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Payload Checkpoint")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = JournalCheckpointFault(state: .payloadCommitted)
        let failingStore = TransferQueueJournalStore(
            directory: directory,
            beforeSave: fault.check
        )
        let fake = FakeKindleConnection()
        let firstQueue = TransferQueue(
            toasts: ToastCenter(),
            journalStoreOverride: failingStore
        )

        await firstQueue.send(books: [book], via: makeMonitor(fake))

        #expect(await fake.transferAttempts == 1)
        #expect(failingStore.load().job?.items.map(\.state) == [.inFlight])
        let restarted = TransferQueue(
            toasts: ToastCenter(),
            journalDirectory: directory
        )
        #expect(restarted.hasUnresolvedDelivery)

        await restarted.resumePending(via: makeMonitor(fake))

        #expect(await fake.transferAttempts == 1)
        #expect(restarted.pendingTransferCount == 0)
        #expect(TransferQueueJournalStore(directory: directory).load().job == nil)
    }

    @Test func committedThenThrownTransportReconcilesWithoutResend() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Uncertain Commit")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeKindleConnection()
        await fake.setUncertainTransferMode(.committedThenThrows)
        let firstQueue = TransferQueue(
            toasts: ToastCenter(),
            journalDirectory: directory
        )

        await firstQueue.send(books: [book], via: makeMonitor(fake))

        #expect(await fake.transferAttempts == 1)
        #expect(TransferQueueJournalStore(
            directory: directory
        ).load().job?.items.map(\.state) == [.deliveryUnknown])
        await fake.setUncertainTransferMode(.none)
        let restarted = TransferQueue(
            toasts: ToastCenter(),
            journalDirectory: directory
        )

        await restarted.resumePending(via: makeMonitor(fake))
        await restarted.resumePending(via: makeMonitor(fake))

        #expect(await fake.transferAttempts == 1)
        #expect(restarted.pendingTransferCount == 0)
    }

    @Test func staleInFlightWithAbsentDestinationRetriesExactlyOnce() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Interrupted Before Write")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TransferQueueJournalStore(directory: directory)
        try store.save(DurableTransferJob(
            schemaVersion: DurableTransferJob.currentSchemaVersion,
            id: UUID(),
            deviceIdentifier: FakeKindleConnection.fakeInfo.identifier,
            resumePolicy: .sameDeviceAutomatically,
            createdAt: .now,
            updatedAt: .now,
            items: [try durableItem(for: book, state: .inFlight)]
        ))
        let fake = FakeKindleConnection()
        let restarted = TransferQueue(
            toasts: ToastCenter(),
            journalDirectory: directory
        )

        #expect(restarted.hasUnresolvedDelivery)
        await restarted.resumePending(via: makeMonitor(fake))
        await restarted.resumePending(via: makeMonitor(fake))

        #expect(await fake.transferAttempts == 1)
        #expect(restarted.pendingTransferCount == 0)
        #expect(store.load().job == nil)
    }

    @Test func wrongSizedDestinationRemainsUnresolvedAndIsNotResent() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Partial Delivery")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeKindleConnection()
        await fake.setUncertainTransferMode(.partialThenThrows)
        let firstQueue = TransferQueue(
            toasts: ToastCenter(),
            journalDirectory: directory
        )

        await firstQueue.send(books: [book], via: makeMonitor(fake))
        let restarted = TransferQueue(
            toasts: ToastCenter(),
            journalDirectory: directory
        )
        await restarted.resumePending(via: makeMonitor(fake))

        #expect(await fake.transferAttempts == 1)
        #expect(restarted.hasUnresolvedDelivery)
        #expect(restarted.pendingTransferCount == 1)
        #expect(TransferQueueJournalStore(
            directory: directory
        ).load().job?.items.map(\.state) == [.deliveryUnknown])
    }

    @Test func receiptFailureResumesOnlyPostProcessing() async throws {
        struct ReceiptFailure: Error {}

        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Receipt Resume")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeKindleConnection()
        let firstQueue = TransferQueue(
            toasts: ToastCenter(),
            onTransferCompleted: { _ in throw ReceiptFailure() },
            journalDirectory: directory
        )

        await firstQueue.send(books: [book], via: makeMonitor(fake))
        let cleanupCount = await fake.staleVariantCalls.count
        let thumbnailCount = await fake.pushedThumbnails.count
        var resumedReceipts = 0
        let restarted = TransferQueue(
            toasts: ToastCenter(),
            onTransferCompleted: { _ in resumedReceipts += 1 },
            journalDirectory: directory
        )

        await restarted.resumePending(via: makeMonitor(fake))

        #expect(await fake.transferAttempts == 1)
        #expect(await fake.staleVariantCalls.count == cleanupCount)
        #expect(await fake.pushedThumbnails.count == thumbnailCount)
        #expect(resumedReceipts == 1)
        #expect(restarted.pendingTransferCount == 0)
    }

    @Test func completionCheckpointFailureIsIdempotentlyRecovered() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Completion Resume")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = JournalCheckpointFault(state: .completed)
        let failingStore = TransferQueueJournalStore(
            directory: directory,
            beforeSave: fault.check
        )
        let fake = FakeKindleConnection()
        var receiptCount = 0
        let firstQueue = TransferQueue(
            toasts: ToastCenter(),
            onTransferCompleted: { _ in receiptCount += 1 },
            journalStoreOverride: failingStore
        )

        await firstQueue.send(books: [book], via: makeMonitor(fake))
        #expect(failingStore.load().job?.items.map(\.state) == [.payloadCommitted])
        let restarted = TransferQueue(
            toasts: ToastCenter(),
            onTransferCompleted: { _ in receiptCount += 1 },
            journalDirectory: directory
        )

        await restarted.resumePending(via: makeMonitor(fake))

        #expect(await fake.transferAttempts == 1)
        #expect(receiptCount == 1)
        #expect(restarted.pendingTransferCount == 0)
    }

    @Test func completedJournalRemovalFailureIsCleanedOnNextLaunch() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Removal Retry")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let removalFault = JournalCheckpointFault(state: .completed)
        let store = TransferQueueJournalStore(
            directory: directory,
            beforeRemove: {
                let terminal = try #require(
                    TransferQueueJournalStore(directory: directory).load().job
                )
                try removalFault.check(terminal)
            }
        )
        let fake = FakeKindleConnection()
        let firstQueue = TransferQueue(
            toasts: ToastCenter(),
            journalStoreOverride: store
        )

        await firstQueue.send(books: [book], via: makeMonitor(fake))
        #expect(TransferQueueJournalStore(
            directory: directory
        ).load().job?.isTerminal == true)

        let restarted = TransferQueue(
            toasts: ToastCenter(),
            journalDirectory: directory
        )

        #expect(restarted.pendingTransferCount == 0)
        #expect(TransferQueueJournalStore(directory: directory).load().job == nil)
        #expect(await fake.transferAttempts == 1)
    }

    @Test func resumeSkipsPayloadCommittedItemAndSendsOnlyPendingItem() async throws {
        let lib = try await TestLibrary()
        let committed = try makeMOBIBook(in: lib, title: "Already Committed")
        let pending = try makeMOBIBook(in: lib, title: "Still Pending")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let store = TransferQueueJournalStore(directory: directory, now: { fixedNow })
        try store.save(DurableTransferJob(
            schemaVersion: DurableTransferJob.currentSchemaVersion,
            id: UUID(),
            deviceIdentifier: FakeKindleConnection.fakeInfo.identifier,
            resumePolicy: .sameDeviceAutomatically,
            createdAt: fixedNow,
            updatedAt: fixedNow,
            items: [
                try durableItem(for: committed, state: .payloadCommitted),
                try durableItem(for: pending, state: .pending),
            ]
        ))
        let fake = FakeKindleConnection()
        let queue = TransferQueue(
            toasts: ToastCenter(),
            journalDirectory: directory,
            now: { fixedNow }
        )

        #expect(queue.pendingTransferCount == 2)
        await queue.resumePending(via: makeMonitor(fake))

        #expect(await fake.sentFiles.map(\.fileName) == [
            targetFileName(for: pending, format: "mobi"),
        ])
        #expect(queue.items.map(\.displayName) == [
            committed.displayTitle,
            pending.displayTitle,
        ])
        #expect(queue.items.map(\.stage) == [.done, .done])
        #expect(queue.pendingTransferCount == 0)
        #expect(store.load().job == nil)
    }

    @Test func resumeFailsClosedWhenFrozenSourceGenerationChanged() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Changed While Offline")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let store = TransferQueueJournalStore(directory: directory, now: { fixedNow })
        try store.save(DurableTransferJob(
            schemaVersion: DurableTransferJob.currentSchemaVersion,
            id: UUID(),
            deviceIdentifier: FakeKindleConnection.fakeInfo.identifier,
            resumePolicy: .sameDeviceAutomatically,
            createdAt: fixedNow,
            updatedAt: fixedNow,
            items: [try durableItem(for: book, state: .pending)]
        ))
        try Data("same catalog, different file generation".utf8).write(to: book.fileURL)
        let fake = FakeKindleConnection()
        let queue = TransferQueue(
            toasts: ToastCenter(),
            journalDirectory: directory,
            now: { fixedNow }
        )

        await queue.resumePending(via: makeMonitor(fake))

        #expect(await fake.sentFiles.isEmpty)
        #expect(queue.items.map(\.stage) == [.failed])
        #expect(queue.lastError == TransferArtifactError.sourceChanged.localizedDescription)
        #expect(store.load().job == nil)
    }

    @Test func resumeDoesNothingForDifferentDevice() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Wrong Device")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TransferQueueJournalStore(directory: directory)
        try store.save(DurableTransferJob(
            schemaVersion: DurableTransferJob.currentSchemaVersion,
            id: UUID(),
            deviceIdentifier: FakeKindleConnection.fakeInfo.identifier,
            resumePolicy: .sameDeviceAutomatically,
            createdAt: .now,
            updatedAt: .now,
            items: [try durableItem(for: book, state: .pending)]
        ))
        let fake = FakeKindleConnection()
        let differentInfo = DeviceInfo(
            name: "Other Kindle",
            model: "Test",
            kind: .massStorage,
            totalBytes: 8_000_000_000,
            freeBytes: 6_000_000_000
        )
        let monitor = DeviceMonitor()
        monitor.adoptConnectionForTesting(fake, info: differentInfo)
        let queue = TransferQueue(
            toasts: ToastCenter(),
            journalDirectory: directory
        )

        await queue.resumePending(via: monitor)

        #expect(await fake.transferAttempts == 0)
        #expect(queue.pendingTransferCount == 1)
        #expect(store.load().job?.items.map(\.state) == [.pending])
    }

    @Test func v1StatesMigrateWithoutDiscardingCommittedPayload() async throws {
        let lib = try await TestLibrary()
        let pendingBook = try makeMOBIBook(in: lib, title: "V1 Pending")
        let committedBook = try makeEPUBBook(in: lib, title: "V1 Committed")
        let completedBook = try makeMOBIBook(in: lib, title: "V1 Completed")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = TransferQueueJournalStore(directory: directory)
        let v1 = DurableTransferJob(
            schemaVersion: 1,
            id: UUID(),
            deviceIdentifier: FakeKindleConnection.fakeInfo.identifier,
            resumePolicy: .sameDeviceAutomatically,
            createdAt: .now,
            updatedAt: .now,
            items: [
                try durableItem(for: pendingBook, state: .pending),
                DurableTransferItem(
                    descriptor: KindleSendPreparation.descriptor(for: committedBook),
                    sourceFileGeneration: try #require(
                        TransferFileGeneration.capture(at: committedBook.fileURL)
                    ),
                    state: .payloadCommitted,
                    detail: nil,
                    payload: nil
                ),
                try durableItem(for: completedBook, state: .completed),
            ]
        )
        try JSONEncoder().encode(v1).write(to: store.fileURL)

        let result = store.load()
        let migrated = try #require(result.job)

        #expect(result.issue == nil)
        #expect(migrated.schemaVersion == DurableTransferJob.currentSchemaVersion)
        #expect(migrated.items.map(\.state) == [
            .pending, .payloadCommitted, .completed,
        ])
        #expect(migrated.items[1].payload?.destinationFileName
            == migrated.items[1].descriptor.targetFileName)
        #expect(migrated.items[1].payload?.expectedByteCount == nil)
        #expect(!migrated.isTerminal)
        #expect(store.load().job == migrated)
    }

    @Test func unsupportedJournalIsQuarantinedByteForByte() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Future Journal")
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = TransferQueueJournalStore(directory: directory)
        let unsupported = DurableTransferJob(
            schemaVersion: 999,
            id: UUID(),
            deviceIdentifier: FakeKindleConnection.fakeInfo.identifier,
            resumePolicy: .sameDeviceAutomatically,
            createdAt: .now,
            updatedAt: .now,
            items: [try durableItem(for: book, state: .pending)]
        )
        let bytes = try JSONEncoder().encode(unsupported)
        try bytes.write(to: store.fileURL)

        let result = store.load()

        #expect(result.issue == .unsupportedSchema(999))
        #expect(result.job == nil)
        let quarantinedURL = try #require(result.quarantinedURL)
        #expect(try Data(contentsOf: quarantinedURL) == bytes)
    }

    @Test func corruptDurableJournalIsQuarantinedByteForByte() async throws {
        let directory = makeJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let bytes = Data([0x00, 0xFF, 0x7B, 0x01])
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let store = TransferQueueJournalStore(directory: directory, now: { fixedNow })
        try bytes.write(to: store.fileURL)

        let result = store.load()

        #expect(result.issue == .corrupt)
        let quarantinedURL = try #require(result.quarantinedURL)
        #expect(try Data(contentsOf: quarantinedURL) == bytes)
        #expect(!FileManager.default.fileExists(
            atPath: store.fileURL.path(percentEncoded: false)
        ))
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

    @Test func allSendEntryPointsShareDescriptorAndTaskBehavior() async throws {
        let lib = try await TestLibrary()
        let book = try makeMOBIBook(in: lib, title: "Shared Entry")
        let descriptor = KindleSendPreparation.descriptor(for: book)
        let asset = BookAsset(
            uuid: book.uuid,
            fileName: book.fileName,
            validationStatus: .ok,
            book: book
        )
        var sentNames: [[String]] = []

        let directBooks = FakeKindleConnection()
        await TransferQueue(toasts: ToastCenter()).send(
            books: [book],
            via: makeMonitor(directBooks)
        )
        sentNames.append(await directBooks.sentFiles.map(\.fileName))

        let directDescriptors = FakeKindleConnection()
        await TransferQueue(toasts: ToastCenter()).send(
            readModel: [descriptor],
            via: makeMonitor(directDescriptors)
        )
        sentNames.append(await directDescriptors.sentFiles.map(\.fileName))

        let directAsset = FakeKindleConnection()
        await TransferQueue(toasts: ToastCenter()).send(
            asset: asset,
            for: book,
            via: makeMonitor(directAsset)
        )
        sentNames.append(await directAsset.sentFiles.map(\.fileName))

        let begunBooks = FakeKindleConnection()
        let begunBooksQueue = TransferQueue(toasts: ToastCenter())
        begunBooksQueue.beginSend(books: [book], via: makeMonitor(begunBooks))
        await waitUntilFinished(begunBooksQueue)
        sentNames.append(await begunBooks.sentFiles.map(\.fileName))

        let begunDescriptors = FakeKindleConnection()
        let begunDescriptorsQueue = TransferQueue(toasts: ToastCenter())
        begunDescriptorsQueue.beginSend(
            readModel: [descriptor],
            via: makeMonitor(begunDescriptors)
        )
        await waitUntilFinished(begunDescriptorsQueue)
        sentNames.append(await begunDescriptors.sentFiles.map(\.fileName))

        let begunAsset = FakeKindleConnection()
        let begunAssetQueue = TransferQueue(toasts: ToastCenter())
        begunAssetQueue.beginSend(
            asset: asset,
            for: book,
            via: makeMonitor(begunAsset)
        )
        await waitUntilFinished(begunAssetQueue)
        sentNames.append(await begunAsset.sentFiles.map(\.fileName))

        let expected = [descriptor.targetFileName]
        #expect(sentNames.allSatisfy { $0 == expected })
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

        let sent = await fake.sentFiles
        let profile = try #require(profiles.profile(for: FakeKindleConnection.fakeInfo))
        let receipt = try #require(profiles.receipts(for: profile.id)[book.uuid])
        #expect(receipt.sentFileName == targetFileName(for: book, format: "mobi"))
        #expect(receipt.artifactFormat == "mobi")
        #expect(receipt.artifactSizeBytes == sent.first.map { UInt64($0.byteCount) })
        #expect(receipt.artifactFingerprint == receipt.sourceFingerprint)
        #expect(receipt.transportIdentifier == "fake-1")
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
        var records: [KindleSyncTransferRecord] = []
        let queue = TransferQueue(
            toasts: ToastCenter(),
            onTransferCompleted: { records.append($0) }
        )

        await queue.send(books: [book], via: makeMonitor(fake))

        let sent = await fake.sentFiles
        let record = try #require(records.first)
        #expect(sent.map(\.fileName) == [targetFileName(for: book, format: "mobi")])
        #expect(record.artifactFormat == "mobi")
        #expect(record.artifactSizeBytes == sent.first.map { UInt64($0.byteCount) })
        #expect(record.artifactFingerprint != nil)
        #expect(record.artifactFingerprint != record.sourceFingerprint)
        #expect(record.transportIdentifier == "fake-1")
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

    @Test func sendPlanReportsUnavailableBooksWithoutHidingValidTransfers() async throws {
        let lib = try await TestLibrary()
        let unavailable = Book(fileName: "", originalFileName: "Physical")
        unavailable.title = "Physical"
        unavailable.hasPhysicalCopy = true
        let available = try makeMOBIBook(in: lib, title: "Available")
        let fake = FakeKindleConnection()
        let queue = TransferQueue(toasts: ToastCenter())

        await queue.send(
            books: [unavailable, available],
            via: makeMonitor(fake)
        )

        let result = try #require(queue.lastBulkOperationResult)
        #expect(result.plan.affectedTargetCount == 1)
        #expect(result.plan.conflicts == [
            BulkOperationConflict(
                targetID: .catalogBook(unavailable.uuid),
                reason: .unavailable
            ),
        ])
        #expect(result.appliedTargetIDs == [.catalogBook(available.uuid)])
        #expect(queue.items.map(\.stage) == [.failed, .done])
        #expect(await fake.sentFiles.count == 1)
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

    @Test func cleanupFailureAfterVerifiedPayloadFinishesWithWarningAndReceipt() async throws {
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
        #expect(queue.failedCount == 1)
        #expect(queue.lastError != nil)
        #expect(queue.lastWarning != nil)
        #expect(receipts.count == 1)
        #expect(queue.pendingTransferCount == 1)
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

        #expect(queue.items.first?.stage == .failed)
        #expect(queue.completedCount == 0)
        #expect(receipts.count == 1)
        #expect(receipts.first?.coverVersion == nil)
        #expect(queue.pendingTransferCount == 1)
    }

    @Test func receiptFailureAfterVerifiedPayloadFinishesWithWarning() async throws {
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
        #expect(queue.failedCount == 1)
        #expect(queue.lastError != nil)
        #expect(queue.lastWarning != nil)
        #expect(queue.pendingTransferCount == 1)
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
        #expect(queue.items.first?.stage == .failed)
        #expect(await fake.sentFiles.isEmpty)
        #expect(receipts.isEmpty)
        #expect(queue.failedCount == 1)
        #expect(queue.hasUnresolvedDelivery)
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
        TestManagedFileFixtureStore.delete(fileName: managedFileName)
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
        let siblingName = try TestManagedFileFixtureStore.importCopy(of: mobiURL, uuid: UUID())
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
            let name = try TestManagedFileFixtureStore.importCopy(of: source, uuid: UUID())
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
        let staleName = try TestManagedFileFixtureStore.importCopy(of: staleURL, uuid: UUID())
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
