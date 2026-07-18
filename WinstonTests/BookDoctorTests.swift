import Foundation
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
}
