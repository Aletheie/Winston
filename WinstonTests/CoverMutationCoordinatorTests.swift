import Foundation
import SwiftData
import Testing
@testable import Winston

@Suite("Cover mutation coordinator", .serialized)
@MainActor
struct CoverMutationCoordinatorTests {
    private struct InjectedFailure: Error {}

    @Test
    func lateBackgroundMutationCannotOverwriteNewerUserCover() async throws {
        let library = try await TestLibrary()
        let book = try seedBook(in: library)
        let files = makeManagedFiles()
        let mutations = CatalogMutationService(
            modelContext: library.context,
            managedFiles: files
        )
        let coordinator = CoverMutationCoordinator(
            mutations: mutations,
            managedFiles: files
        )
        let original = book.coverReference
        let backgroundData = Data("background".utf8)
        let userData = Data("user".utf8)

        let background = try await coordinator.prepare(
            payload: backgroundData,
            targetReference: CoverReference(owner: .edition(book.uuid), version: 1),
            selectedBookIDs: [book.uuid],
            expectedBookReferences: [book.uuid: original],
            priority: .background
        )
        let user = try await coordinator.prepare(
            payload: userData,
            targetReference: CoverReference(owner: .edition(book.uuid), version: 1),
            selectedBookIDs: [book.uuid],
            expectedBookReferences: [book.uuid: original],
            priority: .user
        )

        #expect(background.targetReference.version == 1)
        #expect(user.targetReference.version == 2)
        let userResult = try await coordinator.commit(
            user,
            command: .updateCover(
                bookID: book.uuid,
                version: user.targetReference.version
            )
        ) {}
        #expect(userResult.isFullyPublished)
        #expect(book.coverReference == user.targetReference)
        #expect(CoverStore.loadData(for: .edition(book.uuid)) == userData)

        await #expect(throws: CatalogMutationError.self) {
            _ = try await coordinator.commit(
                background,
                command: .updateCover(
                    bookID: book.uuid,
                    version: background.targetReference.version
                )
            ) {}
        }
        #expect(book.coverReference == user.targetReference)
        #expect(CoverStore.loadData(for: .edition(book.uuid)) == userData)
        #expect(await files.pendingTransactions().isEmpty)
    }

    @Test
    func preparedJournalReservesEpochAcrossCoordinatorRestart() async throws {
        let library = try await TestLibrary()
        let book = try seedBook(in: library)
        let original = book.coverReference
        let firstFiles = makeManagedFiles()
        let firstMutations = CatalogMutationService(
            modelContext: library.context,
            managedFiles: firstFiles
        )
        let firstCoordinator = CoverMutationCoordinator(
            mutations: firstMutations,
            managedFiles: firstFiles
        )
        let stale = try await firstCoordinator.prepare(
            payload: Data("stale".utf8),
            targetReference: CoverReference(owner: .edition(book.uuid), version: 1),
            selectedBookIDs: [book.uuid],
            expectedBookReferences: [book.uuid: original],
            priority: .background
        )

        let restartedFiles = makeManagedFiles()
        let restartedMutations = CatalogMutationService(
            modelContext: library.context,
            managedFiles: restartedFiles
        )
        let restartedCoordinator = CoverMutationCoordinator(
            mutations: restartedMutations,
            managedFiles: restartedFiles
        )
        let current = try await restartedCoordinator.prepare(
            payload: Data("current".utf8),
            targetReference: CoverReference(owner: .edition(book.uuid), version: 1),
            selectedBookIDs: [book.uuid],
            expectedBookReferences: [book.uuid: original],
            priority: .user
        )

        #expect(current.targetReference.version == stale.targetReference.version + 1)
        _ = try await restartedCoordinator.commit(
            current,
            command: .updateCover(
                bookID: book.uuid,
                version: current.targetReference.version
            )
        ) {}
        let report = await restartedMutations.recoverManagedFiles()

        #expect(report.supersededTransactionIDs == [stale.transaction.id])
        #expect(!report.hasPendingWork)
        #expect(await restartedFiles.pendingTransactions().isEmpty)
        #expect(book.coverReference == current.targetReference)
        #expect(
            CoverStore.loadData(for: .edition(book.uuid))
                == Data("current".utf8)
        )
    }

    @Test
    func restartDiscardsOlderCommittedJournalAfterNewerUserCover() async throws {
        let library = try await TestLibrary()
        let book = try seedBook(in: library)
        let original = book.coverReference
        let failingFiles = makeManagedFiles {
            if $0 == .afterCatalogSave { throw InjectedFailure() }
        }
        let firstMutations = CatalogMutationService(
            modelContext: library.context,
            managedFiles: failingFiles
        )
        let firstCoordinator = CoverMutationCoordinator(
            mutations: firstMutations,
            managedFiles: failingFiles
        )
        let older = try await firstCoordinator.prepare(
            payload: Data("older".utf8),
            targetReference: CoverReference(owner: .edition(book.uuid), version: 1),
            selectedBookIDs: [book.uuid],
            expectedBookReferences: [book.uuid: original],
            priority: .background
        )
        let olderResult = try await firstCoordinator.commit(
            older,
            command: .updateCover(
                bookID: book.uuid,
                version: older.targetReference.version
            )
        ) {}

        #expect(olderResult.pendingTransactionIDs == [older.transaction.id])
        #expect(book.coverReference == older.targetReference)
        #expect(!CoverStore.exists(for: .edition(book.uuid)))

        let restartedFiles = makeManagedFiles()
        let restartedMutations = CatalogMutationService(
            modelContext: library.context,
            managedFiles: restartedFiles
        )
        let restartedCoordinator = CoverMutationCoordinator(
            mutations: restartedMutations,
            managedFiles: restartedFiles
        )
        let newer = try await restartedCoordinator.prepare(
            payload: Data("newer".utf8),
            targetReference: CoverReference(
                owner: .edition(book.uuid),
                version: older.targetReference.version + 1
            ),
            selectedBookIDs: [book.uuid],
            expectedBookReferences: [book.uuid: older.targetReference],
            priority: .user
        )
        _ = try await restartedCoordinator.commit(
            newer,
            command: .updateCover(
                bookID: book.uuid,
                version: newer.targetReference.version
            )
        ) {}
        let report = await restartedMutations.recoverManagedFiles()

        #expect(report.supersededTransactionIDs == [older.transaction.id])
        #expect(!report.hasPendingWork)
        #expect(await restartedFiles.pendingTransactions().isEmpty)
        #expect(book.coverReference == newer.targetReference)
        #expect(
            CoverStore.loadData(for: .edition(book.uuid))
                == Data("newer".utf8)
        )
    }

    @Test
    func workCoverMutationUpdatesEverySelectedEditionAndChangeSet() async throws {
        let library = try await TestLibrary()
        let work = Work(title: "Shared")
        let first = Book(fileName: "first.epub", originalFileName: "First.epub")
        let second = Book(fileName: "second.epub", originalFileName: "Second.epub")
        library.context.insert(work)
        library.context.insert(first)
        library.context.insert(second)
        first.work = work
        second.work = work
        try library.context.save()

        let files = makeManagedFiles()
        let mutations = CatalogMutationService(
            modelContext: library.context,
            managedFiles: files
        )
        let coordinator = CoverMutationCoordinator(
            mutations: mutations,
            managedFiles: files
        )
        let selectedIDs: Set<UUID> = [first.uuid, second.uuid]
        let prepared = try await coordinator.prepare(
            payload: Data("work cover".utf8),
            targetReference: CoverReference(owner: .work(work.uuid), version: 1),
            selectedBookIDs: selectedIDs,
            expectedBookReferences: [
                first.uuid: first.coverReference,
                second.uuid: second.coverReference,
            ],
            priority: .user
        )
        let result = try await coordinator.commit(
            prepared,
            command: .updateCover(
                bookID: first.uuid,
                version: prepared.targetReference.version
            )
        ) {}

        #expect(result.isFullyPublished)
        #expect(result.changeSet.affectedBookIDs == selectedIDs)
        #expect(result.changeSet.affectedWorkIDs == [work.uuid])
        #expect(work.coverVersion == prepared.targetReference.version)
        #expect(first.coverReference == prepared.targetReference)
        #expect(second.coverReference == prepared.targetReference)
        #expect(first.coverVersion == 0)
        #expect(second.coverVersion == 0)
        #expect(
            CoverStore.loadData(for: .work(work.uuid))
                == Data("work cover".utf8)
        )
    }

    private func makeManagedFiles(
        _ fault: @escaping ManagedFileCoordinator.FaultInjector = { _ in }
    ) -> ManagedFileCoordinator {
        ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory,
            faultInjector: fault
        )
    }

    private func seedBook(in library: TestLibrary) throws -> Book {
        let book = Book(fileName: "cover.epub", originalFileName: "Cover.epub")
        library.context.insert(book)
        try library.context.save()
        return book
    }
}
