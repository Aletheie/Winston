import AppKit
import Darwin
import Foundation
import OSLog
import SQLite3
import SwiftData

nonisolated enum LibraryPerformanceConfiguration {
    static let preparationArgument = "--winston-library-performance-prepare"
    static let rootEnvironmentKey = "WINSTON_LIBRARY_PERFORMANCE_ROOT"
    static let scenarioEnvironmentKey = "WINSTON_LIBRARY_PERFORMANCE_SCENARIO"
    static let countEnvironmentKey = "WINSTON_LIBRARY_PERFORMANCE_COUNT"
    static let resultFileEnvironmentKey = "WINSTON_LIBRARY_PERFORMANCE_RESULT_FILE"

    static var isScenarioEnabled: Bool {
        ProcessInfo.processInfo.environment[scenarioEnvironmentKey] == "1"
    }

    static var expectedBookCount: Int? {
        ProcessInfo.processInfo.environment[countEnvironmentKey].flatMap(Int.init)
    }

    static func writeResult(_ value: String) {
        guard let path = ProcessInfo.processInfo.environment[resultFileEnvironmentKey],
              !path.isEmpty else { return }
        do {
            try Data("\(value)\n".utf8).write(
                to: URL(fileURLWithPath: path),
                options: .atomic
            )
        } catch {
            FileHandle.standardError.write(Data(
                "WINSTON_LIBRARY_PERFORMANCE_RESULT_WRITE_FAILED \(error.localizedDescription)\n".utf8
            ))
        }
    }

    static func configureAppPathsIfNeeded() throws {
        guard let value = ProcessInfo.processInfo.environment[rootEnvironmentKey],
              !value.isEmpty else { return }
        AppPaths.rootDirectory = try validatedRoot(value)
    }

    static func preparationRequest(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) throws -> LibraryPerformancePreparationRequest? {
        guard let argumentIndex = arguments.firstIndex(of: preparationArgument) else {
            return nil
        }
        guard arguments.indices.contains(argumentIndex + 2),
              let count = Int(arguments[argumentIndex + 1]),
              (1...50_000).contains(count) else {
            throw LibraryPerformanceError.invalidPreparationArguments
        }
        return LibraryPerformancePreparationRequest(
            bookCount: count,
            rootDirectory: try validatedRoot(arguments[argumentIndex + 2])
        )
    }

    private static func validatedRoot(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard url.path != "/",
              url.path != FileManager.default.homeDirectoryForCurrentUser.path,
              url.pathComponents.count >= 3 else {
            throw LibraryPerformanceError.unsafeRoot(path)
        }
        return url
    }
}

nonisolated struct LibraryPerformancePreparationRequest: Equatable, Sendable {
    let bookCount: Int
    let rootDirectory: URL
}

nonisolated struct LibraryPerformanceManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let bookCount: Int
    let assetCount: Int
    let collectionCount: Int
    let highlightCount: Int
    let readingSessionCount: Int
    let targetBookID: UUID
    let mutationCollectionID: UUID
    let primaryAssetID: UUID
    let alternateAssetID: UUID
    let calibreImportBookCount: Int
}

nonisolated enum LibraryPerformanceError: LocalizedError {
    case invalidPreparationArguments
    case unsafeRoot(String)
    case rootIsNotEmpty(URL)
    case manifestMismatch(expected: Int, actual: Int)
    case missingScenarioTarget
    case mutationFailed(String)
    case synchronizationTimedOut(String)
    case calibreFixturePreparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPreparationArguments:
            "Expected \(LibraryPerformanceConfiguration.preparationArgument) <1...50000> <empty-root>."
        case .unsafeRoot(let path):
            "Refusing to use unsafe performance root: \(path)"
        case .rootIsNotEmpty(let url):
            "Performance root must be empty: \(url.path)"
        case .manifestMismatch(let expected, let actual):
            "Performance store contains \(actual) books; expected \(expected)."
        case .missingScenarioTarget:
            "The prepared performance target book, collection, or alternate asset is missing."
        case .mutationFailed(let name):
            "The \(name) performance mutation failed."
        case .synchronizationTimedOut(let name):
            "The read model did not synchronize after the \(name) mutation."
        case .calibreFixturePreparationFailed(let message):
            "The Calibre performance fixture could not be prepared: \(message)"
        }
    }
}

@MainActor
enum LibraryPerformanceDatasetBuilder {
    static let manifestFileName = "library-performance-manifest.json"
    static let calibreFixtureDirectoryName = "CalibrePerformanceFixture"
    static let collectionCount = 64

    static var targetBookID: UUID { deterministicID(kind: 0x01, index: 0) }
    static var mutationCollectionID: UUID { deterministicID(kind: 0x03, index: 0) }
    static var primaryAssetID: UUID { deterministicID(kind: 0x02, index: 0) }
    static var alternateAssetID: UUID { deterministicID(kind: 0x04, index: 0) }
    static var calibreFixtureURL: URL {
        AppPaths.rootDirectory.appending(
            path: calibreFixtureDirectoryName,
            directoryHint: .isDirectory
        )
    }

    static func prepare(_ request: LibraryPerformancePreparationRequest) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: request.rootDirectory.path) {
            let contents = try fileManager.contentsOfDirectory(
                at: request.rootDirectory,
                includingPropertiesForKeys: nil
            )
            guard contents.isEmpty else {
                throw LibraryPerformanceError.rootIsNotEmpty(request.rootDirectory)
            }
        }

        AppPaths.rootDirectory = request.rootDirectory
        try AppPaths.ensureRequiredDirectories()

        let container = try PersistenceController.performanceContainer(
            at: PersistenceController.storeURL
        )
        let context = container.mainContext
        context.autosaveEnabled = false

        let collections = (0..<collectionCount).map { index in
            BookCollection(
                id: deterministicID(kind: 0x03, index: index),
                name: String(format: "Shelf %02d", index)
            )
        }
        for collection in collections {
            context.insert(collection)
        }

        let baseDate = Date(timeIntervalSince1970: 1_735_689_600)
        var assetCount = 0
        var highlightCount = 0
        var readingSessionCount = 0

        for index in 0..<request.bookCount {
            let bookID = deterministicID(kind: 0x01, index: index)
            let primaryID = deterministicID(kind: 0x02, index: index)
            let primaryFileName = "\(bookID.uuidString.lowercased()).epub"
            let book = Book(
                uuid: bookID,
                fileName: primaryFileName,
                originalFileName: String(format: "Book %05d.epub", index),
                dateAdded: baseDate.addingTimeInterval(TimeInterval(-index * 1_337))
            )
            book.title = String(format: "The Measured Book %05d", index)
            book.author = String(format: "Author %03d", index % 250)
            book.publisher = String(format: "Publisher %02d", index % 40)
            book.year = String(1980 + index % 47)
            book.language = ["en", "cs", "de", "fr"][index % 4]
            book.series = index.isMultiple(of: 3)
                ? String(format: "Series %03d", index % 180)
                : nil
            book.seriesIndex = book.series == nil ? nil : String(index % 12 + 1)
            book.tags = [
                String(format: "tag-%02d", index % 48),
                String(format: "topic-%02d", index % 19),
            ]
            book.bookDescription = "A deterministic performance fixture with realistic catalog metadata."
            book.rating = index % 6
            book.readingStatus = ReadingStatus.allCases[index % ReadingStatus.allCases.count]
            book.pageCount = 120 + index % 680
            book.fileSizeBytes = Int64(64_000 + index % 4_000_000)

            let primary = BookAsset(
                uuid: primaryID,
                fileName: primaryFileName,
                origin: .original,
                format: "EPUB",
                sourceProvenance: .directImport,
                sourceIdentifier: "performance:\(index)",
                contentHash: String(format: "%064x", index + 1),
                sizeBytes: book.fileSizeBytes,
                validationStatus: .ok,
                availability: .available,
                book: book
            )
            book.primaryAssetUUID = primaryID
            book.assets = [primary]
            context.insert(book)
            assetCount += 1

            let firstCollectionIndex = (index + 1) % collectionCount
            book.collections.append(collections[firstCollectionIndex])
            if index.isMultiple(of: 7) {
                book.collections.append(collections[(index + 17) % collectionCount])
            }
            if index.isMultiple(of: 29) {
                book.collections.append(collections[(index + 41) % collectionCount])
            }

            if index.isMultiple(of: 25) {
                let highlight = Highlight(
                    text: "Deterministic highlight \(index)",
                    isNote: index.isMultiple(of: 50),
                    location: "chapter-\(index % 20)",
                    addedDate: baseDate.addingTimeInterval(TimeInterval(index))
                )
                highlight.book = book
                book.highlights.append(highlight)
                highlightCount += 1
            }

            if index.isMultiple(of: 10) {
                let session = ReadingSession(
                    uuid: deterministicID(kind: 0x05, index: index),
                    startedAt: baseDate.addingTimeInterval(TimeInterval(-index * 3_600)),
                    endedAt: baseDate.addingTimeInterval(TimeInterval(-index * 3_600 + 1_800)),
                    status: .finished,
                    progress: 1,
                    book: book
                )
                book.readingSessions.append(session)
                readingSessionCount += 1
            }

            if index == 0 {
                let alternateFileName = "\(bookID.uuidString.lowercased()).mobi"
                let alternate = BookAsset(
                    uuid: alternateAssetID,
                    fileName: alternateFileName,
                    origin: .generated,
                    format: "MOBI",
                    sourceProvenance: .conversion,
                    sourceIdentifier: "performance:alternate",
                    contentHash: String(repeating: "a", count: 64),
                    generatedFromContentHash: primary.contentHash,
                    sizeBytes: 96_000,
                    validationStatus: .ok,
                    availability: .available,
                    book: book
                )
                book.assets.append(alternate)
                assetCount += 1
                try Data("performance-primary".utf8).write(
                    to: BookFileStore.url(for: primaryFileName),
                    options: .atomic
                )
                try Data("performance-alternate".utf8).write(
                    to: BookFileStore.url(for: alternateFileName),
                    options: .atomic
                )
            }

            if (index + 1).isMultiple(of: 1_000) {
                try context.save()
            }
        }
        try context.save()
        try prepareCalibreFixture(at: calibreFixtureURL)

        let manifest = LibraryPerformanceManifest(
            schemaVersion: 2,
            bookCount: request.bookCount,
            assetCount: assetCount,
            collectionCount: collectionCount,
            highlightCount: highlightCount,
            readingSessionCount: readingSessionCount,
            targetBookID: targetBookID,
            mutationCollectionID: mutationCollectionID,
            primaryAssetID: primaryAssetID,
            alternateAssetID: alternateAssetID,
            calibreImportBookCount: 1
        )
        let manifestURL = request.rootDirectory.appending(path: manifestFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    private static func prepareCalibreFixture(at root: URL) throws {
        let bookDirectory = root.appending(
            path: "Measured Author/Measured Import",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: bookDirectory,
            withIntermediateDirectories: true
        )
        try Data("calibre-performance-epub".utf8).write(
            to: bookDirectory.appending(path: "book.epub"),
            options: .atomic
        )

        let databaseURL = root.appending(path: "metadata.db")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path(percentEncoded: false), &database) == SQLITE_OK,
              let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open failed"
            sqlite3_close(database)
            throw LibraryPerformanceError.calibreFixturePreparationFailed(message)
        }
        defer { sqlite3_close(database) }

        let sql = """
        CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, series_index REAL, path TEXT, pubdate TEXT, timestamp TEXT, author_sort TEXT);
        CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT, sort TEXT);
        CREATE TABLE books_authors_link (id INTEGER PRIMARY KEY, book INTEGER, author INTEGER);
        CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE books_tags_link (id INTEGER PRIMARY KEY, book INTEGER, tag INTEGER);
        CREATE TABLE series (id INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE books_series_link (id INTEGER PRIMARY KEY, book INTEGER, series INTEGER);
        CREATE TABLE publishers (id INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE books_publishers_link (id INTEGER PRIMARY KEY, book INTEGER, publisher INTEGER);
        CREATE TABLE ratings (id INTEGER PRIMARY KEY, rating INTEGER);
        CREATE TABLE books_ratings_link (id INTEGER PRIMARY KEY, book INTEGER, rating INTEGER);
        CREATE TABLE comments (id INTEGER PRIMARY KEY, book INTEGER, text TEXT);
        CREATE TABLE identifiers (id INTEGER PRIMARY KEY, book INTEGER, type TEXT, val TEXT);
        CREATE TABLE languages (id INTEGER PRIMARY KEY, lang_code TEXT);
        CREATE TABLE books_languages_link (id INTEGER PRIMARY KEY, book INTEGER, lang_code INTEGER, item_order INTEGER);
        CREATE TABLE data (id INTEGER PRIMARY KEY, book INTEGER, format TEXT, uncompressed_size INTEGER, name TEXT);
        INSERT INTO books VALUES (1,'SwiftData Measured Import',1.0,'Measured Author/Measured Import','2026-01-01','2026-01-01 00:00:00+00:00','Measured, Ada');
        INSERT INTO authors VALUES (1,'Ada Measured','Measured, Ada');
        INSERT INTO books_authors_link VALUES (1,1,1);
        INSERT INTO tags VALUES (1,'performance');
        INSERT INTO books_tags_link VALUES (1,1,1);
        INSERT INTO identifiers VALUES (1,1,'isbn','9780000000001');
        INSERT INTO languages VALUES (1,'eng');
        INSERT INTO books_languages_link VALUES (1,1,1,0);
        INSERT INTO data VALUES (1,1,'EPUB',24,'book');
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw LibraryPerformanceError.calibreFixturePreparationFailed(
                String(cString: sqlite3_errmsg(database))
            )
        }
    }

    private static func deterministicID(kind: UInt8, index: Int) -> UUID {
        let value = UInt32(index)
        return UUID(uuid: (
            0x57, 0x49, 0x4e, 0x53, 0x54, 0x4f, 0x4e, kind,
            0, 0, 0, 0,
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ))
    }
}

@MainActor
enum LibraryPerformanceDiagnostics {
    private static var initialLoadInterval: OSSignpostIntervalState?
    private static var initialLoadScopeIsOpen = false

    static func recordBody(_ name: StaticString) {
        guard LibraryPerformanceConfiguration.isScenarioEnabled else { return }
        Log.librarySignposter.emitEvent(name)
    }

    static func writeOutput(_ value: String) {
        guard LibraryPerformanceConfiguration.isScenarioEnabled else { return }
        FileHandle.standardOutput.write(Data("\(value)\n".utf8))
    }

    static func beginInitialLoad() {
        guard LibraryPerformanceConfiguration.isScenarioEnabled,
              initialLoadInterval == nil else { return }
        beginSQLScope("library_initial_load")
        initialLoadScopeIsOpen = true
        let signposter = Log.librarySignposter
        initialLoadInterval = signposter.beginInterval(
            "LibraryInitialLoad",
            id: signposter.makeSignpostID()
        )
    }

    static func endInitialLoad() {
        guard LibraryPerformanceConfiguration.isScenarioEnabled,
              let interval = initialLoadInterval else { return }
        Log.librarySignposter.endInterval("LibraryInitialLoad", interval)
        initialLoadInterval = nil
        if initialLoadScopeIsOpen {
            endSQLScope("library_initial_load")
            initialLoadScopeIsOpen = false
        }
    }

    static func beginSQLScope(_ name: String) {
        guard LibraryPerformanceConfiguration.isScenarioEnabled else { return }
        writeDiagnostic("WINSTON_SWIFTDATA_SCOPE_BEGIN name=\(name)")
    }

    static func endSQLScope(_ name: String) {
        guard LibraryPerformanceConfiguration.isScenarioEnabled else { return }
        writeDiagnostic("WINSTON_SWIFTDATA_SCOPE_END name=\(name)")
    }

    private static func writeDiagnostic(_ value: String) {
        FileHandle.standardError.write(Data("\(value)\n".utf8))
    }
}

@MainActor
enum LibraryPerformanceScenario {
    private static var didStart = false
    private static let timeout = Duration.seconds(30)
    private static let coverData: Data = {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 24
        )!
        for x in 0..<2 {
            for y in 0..<2 {
                bitmap.setColor(
                    NSColor(
                        calibratedRed: x == y ? 0.31 : 0.72,
                        green: 0.24,
                        blue: x == y ? 0.68 : 0.39,
                        alpha: 1
                    ),
                    atX: x,
                    y: y
                )
            }
        }
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.9]
        )!
    }()

    static func run(
        books: [Book],
        collections: [BookCollection],
        readModel: LibraryReadModel,
        viewModel: LibraryViewModel
    ) async {
        guard LibraryPerformanceConfiguration.isScenarioEnabled else { return }
        guard readModel.isReady else {
            LibraryPerformanceDiagnostics.writeOutput(
                "WINSTON_LIBRARY_PERFORMANCE_WAITING books=\(books.count)"
            )
            return
        }
        guard !didStart else { return }
        didStart = true
        LibraryPerformanceDiagnostics.writeOutput(
            "WINSTON_LIBRARY_PERFORMANCE_STARTED books=\(books.count)"
        )

        do {
            if let expected = LibraryPerformanceConfiguration.expectedBookCount,
               books.count != expected {
                throw LibraryPerformanceError.manifestMismatch(
                    expected: expected,
                    actual: books.count
                )
            }
            guard let target = books.first(where: {
                $0.uuid == LibraryPerformanceDatasetBuilder.targetBookID
            }),
            let collection = collections.first(where: {
                $0.id == LibraryPerformanceDatasetBuilder.mutationCollectionID
            }),
            let alternateAsset = target.assets.first(where: {
                $0.uuid == LibraryPerformanceDatasetBuilder.alternateAssetID
            }) else {
                throw LibraryPerformanceError.missingScenarioTarget
            }

            // Build the fixture before any measured interval.
            _ = coverData
            // Instruments launches this fresh app instance. Leave a deterministic window
            // after the initial UI and read model settle before the first mutation.
            try await Task.sleep(for: .seconds(5))
            try await measure(
                "status",
                signpostName: "LibraryPerfStatus",
                readModel: readModel
            ) {
                guard viewModel.setReadingStatus(.reading, for: [target]) else {
                    throw LibraryPerformanceError.mutationFailed("status")
                }
            }
            try await measure(
                "collection",
                signpostName: "LibraryPerfCollection",
                readModel: readModel
            ) {
                let result = await viewModel.add([target], to: collection)
                guard result.appliedTargetIDs.contains(.catalogBook(target.uuid)) else {
                    throw LibraryPerformanceError.mutationFailed("collection")
                }
            }
            try await measure(
                "title",
                signpostName: "LibraryPerfTitle",
                readModel: readModel
            ) {
                guard viewModel.updateMetadata(
                    for: target,
                    title: "\(target.displayTitle) — profiled",
                    author: target.author,
                    publisher: target.publisher,
                    year: target.year,
                    series: target.series,
                    seriesIndex: target.seriesIndex,
                    language: target.language,
                    translator: target.translator,
                    isbn: target.isbn,
                    description: target.bookDescription,
                    tags: target.tags,
                    shelfLocation: target.shelfLocation
                ) else {
                    throw LibraryPerformanceError.mutationFailed("title")
                }
            }
            try await measure(
                "cover",
                signpostName: "LibraryPerfCover",
                readModel: readModel
            ) {
                viewModel.setCustomCover(for: target, from: coverData)
            }
            try await measure(
                "asset",
                signpostName: "LibraryPerfAsset",
                readModel: readModel
            ) {
                await viewModel.makePrimary(alternateAsset, for: target)
            }
            try await measure(
                "edition_scan",
                signpostName: "LibraryPerfEditionScan",
                readModel: readModel,
                requiresReadModelSynchronization: false
            ) {
                await viewModel.editions.scanLibrary()
            }
            try await measure(
                "calibre_import",
                signpostName: "LibraryPerfCalibreImport",
                readModel: readModel
            ) {
                viewModel.importCalibreLibrary(
                    at: LibraryPerformanceDatasetBuilder.calibreFixtureURL
                )
                await viewModel.calibreImporter.waitForCurrentImport()
                guard viewModel.calibreImporter.result?.isComplete == true else {
                    throw LibraryPerformanceError.mutationFailed("calibre_import")
                }
            }

            LibraryPerformanceDiagnostics.writeOutput(
                "WINSTON_LIBRARY_PERFORMANCE_COMPLETE books=\(readModel.bookCount)"
            )
            LibraryPerformanceConfiguration.writeResult(
                "complete books=\(books.count)"
            )
            try await Task.sleep(for: .milliseconds(250))
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            LibraryPerformanceDiagnostics.writeOutput(
                "WINSTON_LIBRARY_PERFORMANCE_FAILED \(error.localizedDescription)"
            )
            LibraryPerformanceConfiguration.writeResult(
                "failed \(error.localizedDescription)"
            )
            try? await Task.sleep(for: .milliseconds(250))
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func measure(
        _ mutationName: String,
        signpostName: StaticString,
        readModel: LibraryReadModel,
        requiresReadModelSynchronization: Bool = true,
        operation: () async throws -> Void
    ) async throws {
        let signposter = Log.librarySignposter
        let interval = signposter.beginInterval(
            signpostName,
            id: signposter.makeSignpostID()
        )
        LibraryPerformanceDiagnostics.beginSQLScope(mutationName)
        let startingGeneration = readModel.generation
        do {
            try await operation()
            if requiresReadModelSynchronization {
                try await waitForSynchronization(
                    after: startingGeneration,
                    mutationName: mutationName,
                    readModel: readModel
                )
            }
            await Task.yield()
            await Task.yield()
            LibraryPerformanceDiagnostics.endSQLScope(mutationName)
            signposter.endInterval(signpostName, interval)
            LibraryPerformanceDiagnostics.writeOutput(
                "WINSTON_LIBRARY_PERFORMANCE_MUTATION name=\(mutationName) generation=\(readModel.generation)"
            )
            try await Task.sleep(for: .milliseconds(750))
        } catch {
            LibraryPerformanceDiagnostics.endSQLScope(mutationName)
            signposter.endInterval(signpostName, interval)
            throw error
        }
    }

    private static func waitForSynchronization(
        after generation: Int,
        mutationName: String,
        readModel: LibraryReadModel
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while readModel.generation <= generation {
            guard clock.now < deadline else {
                throw LibraryPerformanceError.synchronizationTimedOut(mutationName)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
