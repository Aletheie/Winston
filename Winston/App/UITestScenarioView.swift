#if DEBUG
import SwiftUI
import SwiftData

/// Deterministic launch fixtures used only by the UI-test host. The XCTest
/// environment guard keeps these paths unreachable in ordinary debug runs.
struct UITestScenarioView: View {
    let viewModel: LibraryViewModel

    @Environment(DeviceMonitor.self) private var deviceMonitor
    @Environment(\.modelContext) private var modelContext
    @State private var didRun = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task {
                guard !didRun else { return }
                didRun = true
                await runScenarioIfRequested()
            }
    }

    private func runScenarioIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] != nil else { return }

        if environment["WINSTON_UI_TEST_FORCE_DISCONNECTED"] == "1" {
            deviceMonitor.suspendPolling()
            await deviceMonitor.disconnect()
        } else if environment["WINSTON_UI_TEST_FAKE_KINDLE"] == "1" {
            let connection = UITestKindleConnection()
            deviceMonitor.adoptConnectionForTesting(
                connection,
                info: UITestKindleConnection.deviceInfo
            )
        }

        if environment["WINSTON_UI_TEST_HIGHLIGHTS"] == "1" {
            installHighlightsFixture()
        }

        if environment["WINSTON_UI_TEST_BROWSING"] == "1" {
            await installBrowsingFixture()
        }

        guard let importPath = environment["WINSTON_UI_TEST_IMPORT_PATH"],
              !importPath.isEmpty else { return }
        viewModel.addBooks(
            from: [URL(fileURLWithPath: importPath, isDirectory: false)]
        )
    }

    /// Installs a deterministic, in-memory fixture for end-to-end highlights UI tests.
    private func installHighlightsFixture() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] != nil,
              environment["WINSTON_UI_TEST_HIGHLIGHTS"] == "1",
              (try? modelContext.fetchCount(FetchDescriptor<Highlight>())) == 0 else {
            return
        }

        let attention = Book(
            fileName: "attention.epub",
            originalFileName: "Attention.epub"
        )
        attention.title = "A Book of Attention"
        attention.author = "Ada Reader"
        let memory = Book(
            fileName: "memory.epub",
            originalFileName: "Memory.epub"
        )
        memory.title = "B Book of Memory"
        memory.author = "Milo Reader"
        modelContext.insert(attention)
        modelContext.insert(memory)

        let fixtures: [(
            book: Book,
            text: String,
            location: String,
            favorite: Bool,
            tags: [String],
            reflection: String?,
            lastReviewedAt: Date?
        )] = [
            (attention, "Attention shapes the day.", "10", true, ["Focus"], "Seeded reflection", nil),
            (attention, "A second unreviewed passage.", "20", false, [], nil, nil),
            (attention, "A third passage for review.", "30", false, ["Practice"], nil, nil),
            (memory, "Memory changes each time it is recalled.", "40", true, ["Memory"], nil, nil),
            (memory, "The oldest reviewed passage.", "50", false, [], nil, Date(timeIntervalSince1970: 100)),
            (memory, "The newest reviewed passage.", "60", false, [], nil, Date(timeIntervalSince1970: 200)),
        ]

        for (offset, fixture) in fixtures.enumerated() {
            let highlight = Highlight(
                text: fixture.text,
                isNote: false,
                location: fixture.location,
                addedDate: Date(timeIntervalSince1970: Double(offset + 1))
            )
            highlight.dateImported = Date(timeIntervalSince1970: Double(offset + 1))
            highlight.isFavorite = fixture.favorite
            highlight.userTags = fixture.tags
            highlight.reflection = fixture.reflection
            highlight.lastReviewedAt = fixture.lastReviewedAt
            highlight.book = fixture.book
            modelContext.insert(highlight)
        }

        do {
            try modelContext.save()
            LibraryMutationLog.shared.bump(
                catalogChanged: true,
                affectedBookIDs: [attention.uuid, memory.uuid],
                fields: [.identity, .displayMetadata],
                changesBookMembership: true,
                fullTextAffectedBookIDs: []
            )
        } catch {
            modelContext.rollback()
        }
    }

    private func installBrowsingFixture() async {
        // The UI test supplies an isolated on-disk cover root and in-memory catalog.
        guard ProcessInfo.processInfo.environment[
            LibraryPerformanceConfiguration.rootEnvironmentKey
        ] != nil else { return }
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 1200,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 24
        )!
        bitmap.bitmapData?.initialize(repeating: 120, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [:]) else { return }
        let ids = (0..<1_000).map { index in
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
        }
        let coverIDs = ids
        await Task.detached(priority: .utility) {
            try? AppPaths.ensureRequiredDirectories()
            for id in coverIDs {
                try? jpeg.write(to: CoverStore.url(for: .edition(id)))
            }
        }.value
        guard !Task.isCancelled else { return }
        for (index, id) in ids.enumerated() {
            let book = Book(uuid: id, fileName: "", originalFileName: "Paper")
            book.title = String(format: "Browsing Book %05d", index)
            book.author = "Browsing Author"
            book.dateAdded = Date(timeIntervalSince1970: Double(1_000 - index))
            modelContext.insert(book)
        }
        do {
            try modelContext.save()
            LibraryMutationLog.shared.bump(
                catalogChanged: true, affectedBookIDs: Set(ids),
                fields: [.identity, .displayMetadata], changesBookMembership: true,
                fullTextAffectedBookIDs: []
            )
        } catch {
            modelContext.rollback()
        }
    }
}

private actor UITestKindleConnection: KindleDeviceConnection {
    nonisolated static let deviceInfo = DeviceInfo(
        name: "UI Test Kindle",
        model: "UI Test Device",
        kind: .massStorage,
        totalBytes: 8_000_000_000,
        freeBytes: 6_000_000_000,
        identifier: "winston-ui-test-kindle"
    )

    private var books: [DeviceBook] = []
    private var alive = true

    func info() async throws -> DeviceInfo {
        Self.deviceInfo
    }

    func listBooks() async throws -> [DeviceBook] {
        books
    }

    func transfer(
        _ request: DeviceByteTransfer,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DeviceTransferResult {
        let data = try Data(contentsOf: request.sourceURL)
        guard UInt64(data.count) == request.expectedByteCount else {
            throw DeviceError.fileMissing
        }
        progress(1)
        books.append(
            DeviceBook(
                path: request.destination.relativePath,
                fileName: request.destination.fileName,
                sizeBytes: UInt64(data.count)
            )
        )
        return DeviceTransferResult(
            destination: request.destination,
            bytesTransferred: UInt64(data.count),
            transportIdentifier: "winston-ui-test-transfer"
        )
    }

    func copyBook(
        _ book: DeviceBook,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Data("UI test book".utf8).write(to: destination)
        progress(1)
    }

    func delete(_ book: DeviceBook) async throws {
        books.removeAll { $0.id == book.id }
    }

    func pushCoverThumbnail(_ fileURL: URL, named name: String) async throws {}

    func readClippingsText() async throws -> String? {
        nil
    }

    func isAlive() async -> Bool {
        alive
    }

    func disconnect() async {
        alive = false
    }

    func eject() async throws {
        alive = false
    }

    func removeStaleVariants(baseName: String, keeping fileName: String) async throws {}

    func removeAppleDoubleSidecars() async throws -> Int {
        0
    }
}
#endif
