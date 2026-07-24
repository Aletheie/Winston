import Foundation
import CoreGraphics
import Testing
@testable import Winston

@MainActor
struct BookDoctorTests {
    @Test func healthyEPUBIsReadyWithoutWarnings() throws {
        let url = try EPUBFixture.make(title: "Healthy", author: "Ursula")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let report = BookDoctorService.inspect(
            BookDoctorSource(title: "Healthy", url: url)
        )

        #expect(report.canImport)
        #expect(report.canSend)
        #expect(!report.hasErrors)
        #expect(!report.hasWarnings)
        #expect(report.issues.contains { $0.kind == .shortSample })
    }

    @Test func brokenSpineAndMissingImagesAreDiagnosed() throws {
        let url = try damagedEPUB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let report = BookDoctorService.inspect(
            BookDoctorSource(title: "Damaged", url: url)
        )

        #expect(report.issues.contains { $0.kind == .brokenSpine && $0.repairable })
        #expect(report.issues.contains { $0.kind == .missingImages })
        #expect(report.canRepair)
        #expect(report.canSend)
    }

    @Test func repairCreatesAReadableCopyAndPreservesOriginal() throws {
        let original = try damagedEPUB()
        let repaired = original.deletingLastPathComponent().appending(path: "repaired.epub")
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }

        try BookDoctorService.makeRepairedCopy(of: original, at: repaired)

        let originalReport = BookDoctorService.inspect(
            BookDoctorSource(title: "Original", url: original)
        )
        let repairedReport = BookDoctorService.inspect(
            BookDoctorSource(title: "Repaired", url: repaired)
        )
        let parsed = try EPUBReader.read(repaired)

        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: repaired.path(percentEncoded: false)))
        #expect(originalReport.issues.contains { $0.kind == .brokenSpine })
        #expect(!repairedReport.issues.contains { $0.kind == .brokenSpine })
        #expect(parsed.spine.count == 1)
    }

    @Test func repairNeverOverwritesTheOriginal() throws {
        let original = try damagedEPUB()
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        let originalHash = try ContentHasher.sha256(of: original)

        #expect(throws: BookDoctorService.RepairError.self) {
            try BookDoctorService.makeRepairedCopy(of: original, at: original)
        }

        #expect(try ContentHasher.sha256(of: original) == originalHash)
    }

    @Test func repairRejectsASymlinkBackToTheOriginal() throws {
        let original = try damagedEPUB()
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        let symlink = original.deletingLastPathComponent().appending(path: "repair.epub")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        let originalHash = try ContentHasher.sha256(of: original)

        #expect(throws: BookDoctorService.RepairError.self) {
            try BookDoctorService.makeRepairedCopy(of: original, at: symlink)
        }

        #expect(try ContentHasher.sha256(of: original) == originalHash)
    }

    @Test func unreadableFileIsBlocked() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WinstonBookDoctor-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "broken.epub")
        try Data("not an epub".utf8).write(to: url)

        let report = BookDoctorService.inspect(BookDoctorSource(title: "Broken", url: url))

        #expect(report.hasErrors)
        #expect(!report.canImport)
        #expect(!report.canSend)
        #expect(report.assetValidation == .corrupt)
    }

    @Test func batchInspectionPreservesInputOrderAndStreamsProgress() async throws {
        let url = try EPUBFixture.make(title: "Batch", author: "A")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sources = (0..<5).map { index in
            BookDoctorSource(title: "Book \(index)", url: url)
        }
        let progress = BookDoctorProgressRecorder()

        let reports = await BookDoctorService.inspect(
            sources,
            maximumConcurrency: 2
        ) { completed, _ in
            await progress.record(completed)
        }
        let progressCounts = await progress.counts

        #expect(reports.map(\.source.title) == sources.map(\.title))
        #expect(progressCounts == [1, 2, 3, 4, 5])
    }

    @Test func importAnalysisPersistsTheBookDoctorVerdict() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WinstonImportDoctor-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "broken.epub")
        try Data("not an epub".utf8).write(to: url)

        let analysis = await ImportService.defaultAnalysis(for: url)

        #expect(analysis.validation == .corrupt)
    }

    @Test func importAnalysisSharesOneEPUBArchiveAcrossAllExtractors() async throws {
        let url = try EPUBFixture.make(title: "One Pass", author: "A")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(EPUBArchive.openCount(for: url) == 0)
        let analysis = await ImportService.defaultAnalysis(for: url)

        #expect(EPUBArchive.openCount(for: url) == 1)
        #expect(analysis.fileOpenCount == 1)
        #expect(analysis.metadata.title == "One Pass")
        #expect(analysis.metadata.author == "A")
        #expect(analysis.coverJPEGData != nil)
        #expect(analysis.validation == .ok)
    }

    @Test func drmEPUBCanBeArchivedButNotSent() throws {
        let url = try EPUBFixture.makeWithOPF(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Protected</dc:title>
              </metadata>
              <manifest>
                <item id="chap1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="chap1"/></spine>
            </package>
            """,
            additionalEntries: ["META-INF/rights.xml": Data("<rights/>".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let report = BookDoctorService.inspect(BookDoctorSource(title: "Protected", url: url))

        #expect(report.issues.contains { $0.kind == .drm && $0.severity == .error })
        #expect(report.canImport)
        #expect(!report.canSend)
        #expect(report.assetValidation == .ok)
    }

    @Test func imageOnlyPDFIsFlaggedAsScannedAndShort() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "scan.pdf")
        try makeBlankPDF(pageCount: 2, at: url)

        let report = BookDoctorService.inspect(BookDoctorSource(title: "Scan", url: url))

        #expect(report.pageCount == 2)
        #expect(report.issues.contains { $0.kind == .scannedPDF && $0.severity == .warning })
        #expect(report.issues.contains { $0.kind == .shortSample && $0.severity == .note })
        #expect(report.canImport)
        #expect(report.canSend)
    }

    @Test(arguments: ["mobi", "azw3"])
    func readableKindleHeadersReportPagesAndMissingCover(fileExtension: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "book.\(fileExtension)")
        try makeKindleData(textLength: 6_000, encrypted: false).write(to: url)

        let report = BookDoctorService.inspect(BookDoctorSource(title: "Kindle", url: url))

        #expect(report.format == fileExtension.uppercased())
        #expect(report.pageCount == 3)
        #expect(report.issues.contains { $0.kind == .missingCover })
        #expect(report.issues.contains { $0.kind == .shortSample })
        #expect(report.canImport)
        #expect(report.canSend)
    }

    @Test func encryptedMOBICanBeArchivedButNotSent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "protected.mobi")
        try makeKindleData(textLength: 4_096, encrypted: true).write(to: url)

        let report = BookDoctorService.inspect(BookDoctorSource(title: "Protected", url: url))

        #expect(report.issues.contains { $0.kind == .drm && $0.severity == .error })
        #expect(report.canImport)
        #expect(!report.canSend)
        #expect(report.assetValidation == .ok)
    }

    @Test func malformedKindleFileIsBlocked() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "broken.mobi")
        try Data("not a mobi".utf8).write(to: url)

        let report = BookDoctorService.inspect(BookDoctorSource(title: "Broken", url: url))

        #expect(report.issues.contains { $0.kind == .unreadable && $0.severity == .error })
        #expect(!report.canImport)
        #expect(!report.canSend)
        #expect(report.assetValidation == .corrupt)
    }

    private func damagedEPUB() throws -> URL {
        try EPUBFixture.makeWithOPF(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Damaged</dc:title>
                <dc:creator>Test Author</dc:creator>
              </metadata>
              <manifest>
                <item id="chap1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
                <item id="chap2" href="missing.xhtml" media-type="application/xhtml+xml"/>
                <item id="ghost" href="ghost.jpg" media-type="image/jpeg"/>
              </manifest>
              <spine>
                <itemref idref="chap1"/>
                <itemref idref="chap2"/>
              </spine>
            </package>
            """
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WinstonBookDoctor-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeBlankPDF(pageCount: Int, at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func makeKindleData(textLength: UInt32, encrypted: Bool) -> Data {
        var data = Data()
        data.appendZeros(76)
        data.appendUInt16BE(1)
        data.appendUInt32BE(88)
        data.appendZeros(6)
        data.appendUInt16BE(2)
        data.appendUInt16BE(0)
        data.appendUInt32BE(textLength)
        data.appendUInt16BE(1)
        data.appendUInt16BE(4_096)
        data.appendUInt16BE(encrypted ? 1 : 0)
        data.appendUInt16BE(0)
        data.appendASCII("MOBI", length: 4)
        data.appendZeros(64)
        return data
    }
}

private actor BookDoctorProgressRecorder {
    private(set) var counts: [Int] = []

    func record(_ completed: Int) {
        counts.append(completed)
    }
}
