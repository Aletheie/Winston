import AppKit
import Foundation
import PDFKit
import ZIPFoundation

nonisolated struct BookDoctorSource: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let url: URL

    init(id: UUID = UUID(), title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}

nonisolated struct BookDoctorIssue: Identifiable, Sendable, Equatable {
    enum Severity: Int, Sendable, Comparable {
        case note
        case warning
        case error

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Kind: String, Sendable {
        case missingFile
        case unreadable
        case unsupportedFormat
        case drm
        case brokenSpine
        case missingContent
        case missingImages
        case invalidEncoding
        case missingCover
        case shortSample
        case scannedPDF
        case unsafeArchive
    }

    let kind: Kind
    let severity: Severity
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let repairable: Bool

    var id: String { kind.rawValue }
}

nonisolated struct BookDoctorReport: Identifiable, Sendable, Equatable {
    let source: BookDoctorSource
    let format: String
    let pageCount: Int?
    let issues: [BookDoctorIssue]

    var id: UUID { source.id }
    var hasErrors: Bool { issues.contains { $0.severity == .error } }
    var hasWarnings: Bool { issues.contains { $0.severity == .warning } }
    var canRepair: Bool { issues.contains(where: \BookDoctorIssue.repairable) }
    var canImport: Bool {
        !issues.contains { [.missingFile, .unreadable, .unsupportedFormat, .unsafeArchive].contains($0.kind) }
    }
    var canSend: Bool { !hasErrors }
    var assetValidation: AssetValidation {
        if issues.contains(where: { $0.kind == .missingFile }) { return .missing }
        if issues.contains(where: { $0.severity == .error && $0.kind != .drm }) { return .corrupt }
        return .ok
    }
}

nonisolated enum BookDoctorService {
    static let defaultMaximumConcurrentInspections = 3

    enum RepairError: Error, LocalizedError {
        case notRepairable
        case destinationMatchesSource
        case unreadableArchive
        case noReadableSpine

        var errorDescription: String? {
            switch self {
            case .notRepairable:
                String(localized: "Book Doctor found no safe automatic repairs for this file.")
            case .destinationMatchesSource:
                String(localized: "Choose a different destination so the original stays untouched.")
            case .unreadableArchive:
                String(localized: "The EPUB archive couldn’t be read or rebuilt.")
            case .noReadableSpine:
                String(localized: "The EPUB has no readable chapters to preserve.")
            }
        }
    }

    private struct EPUBInspection {
        let opfPath: String
        let opfDocument: XMLDocument
        let brokenSpineIDs: Set<String>
        let nonUTF8TextPaths: Set<String>
        let missingImageCount: Int
        let readableSpineCount: Int
        let pageCount: Int?
        let hasCover: Bool
        let rejectedUnsafeEntry: Bool
    }

    private struct ManifestItem {
        let path: String
        let mediaType: String
    }

    static func inspect(_ source: BookDoctorSource) -> BookDoctorReport {
        let accessing = source.url.startAccessingSecurityScopedResource()
        defer { if accessing { source.url.stopAccessingSecurityScopedResource() } }

        let format = source.url.pathExtension.lowercased()
        guard FileManager.default.fileExists(atPath: source.url.path(percentEncoded: false)) else {
            return report(source, format, nil, [issue(
                .missingFile, .error,
                "File is missing",
                "Winston can’t find this file. Relink it before importing or sending."
            )])
        }

        switch format {
        case "epub":
            return inspectEPUB(source)
        case "pdf":
            return inspectPDF(source)
        case "mobi", "azw", "azw3":
            return inspectKindleFile(source)
        default:
            return report(source, format, nil, [issue(
                .unsupportedFormat, .error,
                "Unsupported format",
                "Book Doctor currently checks EPUB, PDF, MOBI, AZW, and AZW3 files."
            )])
        }
    }

    static func inspect(
        _ sources: [BookDoctorSource],
        maximumConcurrency: Int = defaultMaximumConcurrentInspections,
        progress: (@Sendable (_ completed: Int, _ report: BookDoctorReport) async -> Void)? = nil
    ) async -> [BookDoctorReport] {
        guard !sources.isEmpty else { return [] }
        let concurrency = min(max(1, maximumConcurrency), sources.count)
        var reports = Array<BookDoctorReport?>(repeating: nil, count: sources.count)

        await withTaskGroup(of: (Int, BookDoctorReport).self) { group in
            var nextIndex = 0
            var completed = 0

            while nextIndex < concurrency {
                let index = nextIndex
                group.addTask(priority: .userInitiated) {
                    (index, inspect(sources[index]))
                }
                nextIndex += 1
            }

            while let (index, report) = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                reports[index] = report
                completed += 1
                await progress?(completed, report)

                guard nextIndex < sources.count else { continue }
                let pendingIndex = nextIndex
                group.addTask(priority: .userInitiated) {
                    (pendingIndex, inspect(sources[pendingIndex]))
                }
                nextIndex += 1
            }
        }
        return reports.compactMap { $0 }
    }

    static func makeRepairedCopy(of source: URL, at destination: URL) throws {
        let resolvedSource = source.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedSource != resolvedDestination else {
            throw RepairError.destinationMatchesSource
        }
        guard source.pathExtension.lowercased() == "epub" else { throw RepairError.notRepairable }

        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let inspection = try inspectEPUBArchive(source)
        guard !inspection.brokenSpineIDs.isEmpty || !inspection.nonUTF8TextPaths.isEmpty else {
            throw RepairError.notRepairable
        }
        guard inspection.readableSpineCount > 0 else { throw RepairError.noReadableSpine }

        var replacements: [String: Data] = [:]
        if !inspection.brokenSpineIDs.isEmpty {
            let repairedOPF = try repairedOPFData(
                inspection.opfDocument,
                removingSpineIDs: inspection.brokenSpineIDs
            )
            replacements[inspection.opfPath] = repairedOPF
        }

        let reader = try EPUBArchive(url: source)
        for path in inspection.nonUTF8TextPaths {
            guard let data = reader.entry(path),
                  let latin1 = String(data: data, encoding: .isoLatin1) else { continue }
            let normalized = latin1.replacingOccurrences(
                of: #"encoding\s*=\s*[\"'][^\"']+[\"']"#,
                with: #"encoding=\"UTF-8\""#,
                options: [.regularExpression, .caseInsensitive]
            )
            replacements[path] = Data(normalized.utf8)
        }
        try rebuildArchive(source: source, destination: destination, replacing: replacements)
    }

    // MARK: - Format inspection

    private static func inspectEPUB(_ source: BookDoctorSource) -> BookDoctorReport {
        do {
            let inspection = try inspectEPUBArchive(source.url)
            var issues: [BookDoctorIssue] = []
            if DRMDetector.isProtected(url: source.url) {
                issues.append(issue(
                    .drm, .error,
                    "DRM protection detected",
                    "Winston can preserve this file, but it can’t convert or send DRM-protected content."
                ))
            }
            if inspection.rejectedUnsafeEntry {
                issues.append(issue(
                    .unsafeArchive, .error,
                    "Unsafe archive entry",
                    "The EPUB contains an oversized or suspiciously compressed entry and was not fully opened."
                ))
            }
            if inspection.readableSpineCount == 0 {
                issues.append(issue(
                    .brokenSpine, .error,
                    "No readable chapters",
                    "The EPUB spine does not point to any readable chapter."
                ))
            } else if !inspection.brokenSpineIDs.isEmpty {
                let count = inspection.brokenSpineIDs.count
                issues.append(issue(
                    .brokenSpine, .warning,
                    "Broken reading order",
                    "\(count) spine entries point to missing chapters. A repaired copy can remove those dead references.",
                    repairable: true
                ))
            }
            if inspection.missingImageCount > 0 {
                let count = inspection.missingImageCount
                issues.append(issue(
                    .missingImages, .warning,
                    "Missing images",
                    "\(count) referenced images are missing from the EPUB. Winston will preserve the file but cannot recreate the artwork."
                ))
            }
            if !inspection.nonUTF8TextPaths.isEmpty {
                let count = inspection.nonUTF8TextPaths.count
                issues.append(issue(
                    .invalidEncoding, .warning,
                    "Legacy text encoding",
                    "\(count) content files are not UTF‑8. A repaired copy can normalize readable Latin‑1 text.",
                    repairable: true
                ))
            }
            if !inspection.hasCover {
                issues.append(issue(
                    .missingCover, .warning,
                    "No usable cover",
                    "No readable cover image was found. The book can still be imported or sent."
                ))
            }
            appendSampleIssue(pageCount: inspection.pageCount, to: &issues)
            return report(source, "epub", inspection.pageCount, issues)
        } catch let error as EPUBReader.ReadError {
            return report(source, "epub", nil, [issue(
                .unreadable, .error,
                "Unreadable EPUB",
                LocalizedStringResource(stringLiteral: error.localizedDescription)
            )])
        } catch {
            return report(source, "epub", nil, [issue(
                .unreadable, .error,
                "Unreadable EPUB",
                "The EPUB container or package document is damaged."
            )])
        }
    }

    private static func inspectPDF(_ source: BookDoctorSource) -> BookDoctorReport {
        guard PDFReader.isWithinSizeLimit(source.url), let document = PDFDocument(url: source.url) else {
            return report(source, "pdf", nil, [issue(
                .unreadable, .error,
                "Unreadable PDF",
                "The PDF is damaged, inaccessible, or too large to inspect safely."
            )])
        }
        var issues: [BookDoctorIssue] = []
        if document.isEncrypted && document.isLocked {
            issues.append(issue(
                .drm, .error,
                "Locked PDF",
                "This PDF requires a password and can’t be converted or sent by Winston."
            ))
        }
        if document.pageCount == 0 {
            issues.append(issue(
                .missingContent, .error,
                "No pages",
                "The PDF does not contain any readable pages."
            ))
        } else if !document.isLocked {
            let hasText = (0 ..< min(document.pageCount, 12)).contains { index in
                guard let text = document.page(at: index)?.string else { return false }
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !hasText {
                issues.append(issue(
                    .scannedPDF, .warning,
                    "Image-only PDF",
                    "No extractable text was found in the first pages. Conversion and search may be limited."
                ))
            }
        }
        appendSampleIssue(pageCount: document.pageCount, to: &issues)
        return report(source, "pdf", document.pageCount, issues)
    }

    private static func inspectKindleFile(_ source: BookDoctorSource) -> BookDoctorReport {
        let format = source.url.pathExtension.lowercased()
        guard let fileSize = try? source.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize <= 512 * 1_024 * 1_024,
              let data = try? Data(contentsOf: source.url, options: .mappedIfSafe),
              PageCountEstimator.mobiPageCount(in: data) != nil else {
            return report(source, format, nil, [issue(
                .unreadable, .error,
                "Unreadable Kindle file",
                "The MOBI/AZW header or text records are damaged."
            )])
        }
        let pages = PageCountEstimator.mobiPageCount(in: data)
        var issues: [BookDoctorIssue] = []
        if DRMDetector.isProtected(url: source.url) {
            issues.append(issue(
                .drm, .error,
                "DRM protection detected",
                "Winston can preserve this file, but it can’t convert or send DRM-protected content."
            ))
        }
        if CoverExtractor.extractCover(from: source.url) == nil {
            issues.append(issue(
                .missingCover, .warning,
                "No usable cover",
                "No readable cover image was found. The book can still be imported or sent."
            ))
        }
        appendSampleIssue(pageCount: pages, to: &issues)
        return report(source, format, pages, issues)
    }

    // MARK: - EPUB details

    private static func inspectEPUBArchive(_ url: URL) throws -> EPUBInspection {
        let archive = try EPUBArchive(url: url)
        guard let container = archive.entry("META-INF/container.xml"),
              let opfPath = MetadataExtractor.parseOPFPath(from: container) else {
            throw EPUBReader.ReadError.notAnEPUB
        }
        guard let opfData = archive.entry(opfPath),
              let opf = try? XMLDocument(data: opfData, options: .nodeLoadExternalEntitiesNever) else {
            throw EPUBReader.ReadError.missingOPF
        }
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent
        var manifest: [String: ManifestItem] = [:]
        let itemNodes = try opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")
        for node in itemNodes {
            guard let element = node as? XMLElement,
                  let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue else { continue }
            manifest[id] = ManifestItem(
                path: CoverExtractor.resolve(href, dir: opfDirectory),
                mediaType: element.attribute(forName: "media-type")?.stringValue ?? ""
            )
        }

        var brokenSpineIDs: Set<String> = []
        var readableSpineCount = 0
        let spineNodes = try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")
        for node in spineNodes {
            guard let element = node as? XMLElement,
                  let idref = element.attribute(forName: "idref")?.stringValue,
                  let item = manifest[idref],
                  archive.entry(item.path) != nil else {
                if let idref = (node as? XMLElement)?.attribute(forName: "idref")?.stringValue {
                    brokenSpineIDs.insert(idref)
                }
                continue
            }
            readableSpineCount += 1
        }

        var missingImagePaths: Set<String> = []
        var nonUTF8TextPaths: Set<String> = []
        for item in manifest.values {
            if item.mediaType.lowercased().hasPrefix("image/") {
                if archive.entry(item.path) == nil { missingImagePaths.insert(item.path) }
                continue
            }
            guard isTextContent(item.mediaType), let data = archive.entry(item.path) else { continue }
            if String(data: data, encoding: .utf8) == nil {
                nonUTF8TextPaths.insert(item.path)
            }
            for reference in imageReferences(in: data, contentPath: item.path) {
                if archive.entry(reference) == nil { missingImagePaths.insert(reference) }
            }
        }

        let pageCount = PageCountEstimator.epubPageCount(archive: archive, opfPath: opfPath, opf: opf)
        let cover = CoverExtractor.coverCandidates(from: opf, opfDir: opfDirectory, archive: archive)
            .contains { archive.entry($0) != nil }
        return EPUBInspection(
            opfPath: opfPath,
            opfDocument: opf,
            brokenSpineIDs: brokenSpineIDs,
            nonUTF8TextPaths: nonUTF8TextPaths,
            missingImageCount: missingImagePaths.count,
            readableSpineCount: readableSpineCount,
            pageCount: pageCount,
            hasCover: cover,
            rejectedUnsafeEntry: archive.rejectedUnsafeEntry
        )
    }

    private static func repairedOPFData(
        _ document: XMLDocument,
        removingSpineIDs ids: Set<String>
    ) throws -> Data {
        guard let copy = document.copy() as? XMLDocument else {
            throw RepairError.unreadableArchive
        }
        let nodes = try copy.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")
        for node in nodes {
            guard let element = node as? XMLElement,
                  let idref = element.attribute(forName: "idref")?.stringValue,
                  ids.contains(idref) else { continue }
            element.detach()
        }
        let remaining = try copy.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")
        guard !remaining.isEmpty else { throw RepairError.noReadableSpine }
        return copy.xmlData(options: [.nodePrettyPrint])
    }

    private static func rebuildArchive(
        source: URL,
        destination: URL,
        replacing replacements: [String: Data]
    ) throws {
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).repairing")
        defer { try? fileManager.removeItem(at: temporary) }
        try? fileManager.removeItem(at: temporary)

        guard let input = try? Archive(url: source, accessMode: .read, pathEncoding: nil),
              let output = try? Archive(url: temporary, accessMode: .create, pathEncoding: nil) else {
            throw RepairError.unreadableArchive
        }
        let entries = Array(input).sorted { lhs, rhs in
            if lhs.path == "mimetype" { return rhs.path != "mimetype" }
            if rhs.path == "mimetype" { return false }
            return lhs.path < rhs.path
        }
        var totalBytes: UInt64 = 0
        for entry in entries {
            guard entry.uncompressedSize <= 64 * 1_024 * 1_024,
                  totalBytes <= 256 * 1_024 * 1_024 - entry.uncompressedSize else {
                throw RepairError.unreadableArchive
            }
            totalBytes += entry.uncompressedSize
            var data = Data()
            _ = try input.extract(entry) { data.append($0) }
            if let replacement = replacements[entry.path] { data = replacement }
            let method: CompressionMethod = entry.path == "mimetype" ? .none : .deflate
            try output.addEntry(
                with: entry.path,
                type: entry.type,
                uncompressedSize: Int64(data.count),
                compressionMethod: method
            ) { position, size in
                guard entry.type == .file else { return Data() }
                let lower = Int(position)
                let upper = min(lower + size, data.count)
                return data.subdata(in: lower ..< upper)
            }
        }

        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private static func imageReferences(in data: Data, contentPath: String) -> Set<String> {
        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return [] }
        let pattern = #"(?:src|href|xlink:href)\s*=\s*[\"']([^\"'#?]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let nsRange = NSRange(html.startIndex..., in: html)
        let directory = (contentPath as NSString).deletingLastPathComponent
        var result: Set<String> = []
        for match in regex.matches(in: html, range: nsRange) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let value = String(html[range])
            let ext = (value as NSString).pathExtension.lowercased()
            guard ["jpg", "jpeg", "png", "gif", "webp", "svg", "avif"].contains(ext),
                  !value.lowercased().hasPrefix("data:") else { continue }
            result.insert(CoverExtractor.resolve(value, dir: directory))
        }
        return result
    }

    private static func isTextContent(_ mediaType: String) -> Bool {
        let type = mediaType.lowercased()
        return type.contains("xhtml") || type.contains("html") || type.contains("xml") || type == "text/css"
    }

    // MARK: - Report helpers

    private static func appendSampleIssue(pageCount: Int?, to issues: inout [BookDoctorIssue]) {
        guard let pageCount, pageCount <= Book.sampleMaxPages else { return }
        issues.append(issue(
            .shortSample, .note,
            "Possibly a sample",
            "The file is only about \(pageCount) pages long. Check that it is the complete book."
        ))
    }

    private static func report(
        _ source: BookDoctorSource,
        _ format: String,
        _ pageCount: Int?,
        _ issues: [BookDoctorIssue]
    ) -> BookDoctorReport {
        BookDoctorReport(
            source: source,
            format: format.uppercased(),
            pageCount: pageCount,
            issues: issues.sorted { $0.severity > $1.severity }
        )
    }

    private static func issue(
        _ kind: BookDoctorIssue.Kind,
        _ severity: BookDoctorIssue.Severity,
        _ title: LocalizedStringResource,
        _ detail: LocalizedStringResource,
        repairable: Bool = false
    ) -> BookDoctorIssue {
        BookDoctorIssue(kind: kind, severity: severity, title: title, detail: detail, repairable: repairable)
    }
}
