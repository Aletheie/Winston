import AppKit
import PDFKit

// MARK: - Cover Cache

private nonisolated final class CoverBox: @unchecked Sendable {
    let image: NSImage?
    init(_ image: NSImage?) { self.image = image }
}

// Tiered (thumb for rows, display for cards) with a byte-cost limit.
actor CoverCache {
    static let shared = CoverCache()

    enum Tier: Sendable, Hashable {
        case thumb
        case display

        var maxDimension: CGFloat {
            switch self {
            case .thumb:   160
            case .display: 600
            }
        }
    }

    private let cache: NSCache<NSString, CoverBox> = {
        let cache = NSCache<NSString, CoverBox>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private struct PendingLoad {
        let id: UUID
        let task: Task<CoverBox, Never>
    }
    private var pendingLoads: [NSString: PendingLoad] = [:]

    private init() {}

    private func key(_ url: URL, _ tier: Tier) -> NSString {
        "\(tier)|\(url.path)" as NSString
    }

    func image(for url: URL, tier: Tier) -> NSImage?? {
        guard let box = cache.object(forKey: key(url, tier)) else { return nil }
        return .some(box.image)
    }

    func resolve(
        for url: URL,
        tier: Tier,
        loader: @escaping @Sendable () async -> NSImage?
    ) async -> NSImage? {
        let cacheKey = key(url, tier)
        if let cached = cache.object(forKey: cacheKey) { return cached.image }

        let pending: PendingLoad
        if let existing = pendingLoads[cacheKey] {
            pending = existing
        } else {
            let id = UUID()
            let task = Task { CoverBox(await loader()) }
            pending = PendingLoad(id: id, task: task)
            pendingLoads[cacheKey] = pending
        }

        let loaded = await pending.task.value
        if let cached = cache.object(forKey: cacheKey) { return cached.image }
        guard pendingLoads[cacheKey]?.id == pending.id else { return loaded.image }
        pendingLoads.removeValue(forKey: cacheKey)
        return insert(loaded.image, for: url, tier: tier)
    }

    @discardableResult
    func insert(_ image: NSImage?, for url: URL, tier: Tier) -> NSImage? {
        let scaled = image.map { CoverCache.downscaled($0, maxDimension: tier.maxDimension) }
        let cost = scaled.map { Int($0.size.width * $0.size.height * 4) } ?? 16
        cache.setObject(CoverBox(scaled), forKey: key(url, tier), cost: cost)
        return scaled
    }

    // Drops every tier — a tier-scoped insert would leave stale renditions.
    func replace(_ image: NSImage?, for url: URL) {
        pendingLoads.removeValue(forKey: key(url, .thumb))?.task.cancel()
        pendingLoads.removeValue(forKey: key(url, .display))?.task.cancel()
        cache.removeObject(forKey: key(url, .thumb))
        cache.removeObject(forKey: key(url, .display))
        insert(image, for: url, tier: .display)
    }

    nonisolated static func downscaled(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0,
              let cg = ImageTranscoder.cgImage(from: image) else { return image }
        let scaled = ImageTranscoder.downscaled(cg, maxPixel: Int(maxDimension))
        return NSImage(cgImage: scaled, size: NSSize(width: scaled.width, height: scaled.height))
    }
}

// MARK: - Cover Extractor

enum CoverExtractor {

    nonisolated static func extractCover(from url: URL) -> NSImage? {
        switch url.pathExtension.lowercased() {
        case "epub":                return extractEPUBCover(from: url)
        case "mobi", "azw", "azw3": return extractMOBICover(from: url)
        case "pdf":                 return extractPDFCover(from: url)
        default:                    return nil
        }
    }

    // MARK: EPUB

    nonisolated private static func extractEPUBCover(from url: URL) -> NSImage? {
        guard let archive = try? EPUBArchive(url: url),
              let containerData = archive.entry("META-INF/container.xml"),
              let opfPath = MetadataExtractor.parseOPFPath(from: containerData),
              let opfData = archive.entry(opfPath),
              let doc = try? XMLDocument(data: opfData, options: .nodeLoadExternalEntitiesNever) else { return nil }

        let opfDir = (opfPath as NSString).deletingLastPathComponent
        return epubCoverData(doc: doc, opfDir: opfDir, archive: archive).flatMap { NSImage(data: $0) }
    }

    nonisolated static func epubCoverData(doc: XMLDocument, opfDir: String, archive: EPUBArchive) -> Data? {
        for candidate in coverCandidates(from: doc, opfDir: opfDir, archive: archive) {
            if let data = archive.entry(candidate) { return data }
        }
        return nil
    }

    nonisolated static func coverCandidates(
        from doc: XMLDocument, opfDir: String, archive: EPUBArchive
    ) -> [String] {
        var out: [String] = []

        if let nodes = try? doc.nodes(forXPath: "//*[local-name()='item'][@properties='cover-image']/@href"),
           let href = nodes.first?.stringValue {
            out.append(resolve(href, dir: opfDir))
        }

        if let metas = try? doc.nodes(forXPath: "//*[local-name()='meta'][@name='cover']/@content"),
           let covId = metas.first?.stringValue,
           let items = try? doc.nodes(forXPath: "//*[local-name()='item'][@id='\(covId)']"),
           let item  = items.first {
            let href  = (try? item.nodes(forXPath: "@href"))?.first?.stringValue ?? ""
            let mtype = (try? item.nodes(forXPath: "@media-type"))?.first?.stringValue ?? ""
            if mtype.hasPrefix("image/") {
                out.append(resolve(href, dir: opfDir))
            } else if mtype.contains("xhtml") || mtype.contains("xml") {
                out += imageHrefsFromXHTML(at: resolve(href, dir: opfDir), archive: archive)
            }
        }

        if let nodes = try? doc.nodes(forXPath: "//*[local-name()='reference'][@type='cover']/@href"),
           let href  = nodes.first?.stringValue {
            let clean = href.components(separatedBy: "#").first ?? href
            let ext = (clean as NSString).pathExtension.lowercased()
            if ["jpg","jpeg","png","gif","webp"].contains(ext) {
                out.append(resolve(clean, dir: opfDir))
            } else {
                out += imageHrefsFromXHTML(at: resolve(clean, dir: opfDir), archive: archive)
            }
        }

        if let items = try? doc.nodes(forXPath: "//*[local-name()='item'][starts-with(@media-type,'image/')]") {
            for node in items {
                let h = (try? node.nodes(forXPath: "@href"))?.first?.stringValue ?? ""
                let i = (try? node.nodes(forXPath: "@id"))?.first?.stringValue  ?? ""
                if h.lowercased().contains("cover") || i.lowercased().contains("cover") {
                    out.append(resolve(h, dir: opfDir))
                }
            }
        }

        if let items = try? doc.nodes(forXPath: "//*[local-name()='item'][starts-with(@media-type,'image/')]"),
           let href  = (try? items.first?.nodes(forXPath: "@href"))?.first?.stringValue {
            out.append(resolve(href, dir: opfDir))
        }

        return out
    }

    nonisolated private static func imageHrefsFromXHTML(at path: String, archive: EPUBArchive) -> [String] {
        guard let data = archive.entry(path),
              let html = String(data: data, encoding: .utf8) else { return [] }
        let xhtmlDir = (path as NSString).deletingLastPathComponent
        var hrefs: [String] = []
        for attr in ["src=\"", "xlink:href=\"", "href=\""] {
            var search = html[html.startIndex...]
            while let range = search.range(of: attr) {
                let start = range.upperBound
                guard let end = html[start...].firstIndex(of: "\"") else { break }
                let value = String(html[start..<end])
                let ext = (value as NSString).pathExtension.lowercased()
                if ["jpg","jpeg","png","gif","webp","svg"].contains(ext) {
                    let resolved = resolve(value, dir: xhtmlDir)
                    if !hrefs.contains(resolved) { hrefs.append(resolved) }
                }
                search = html[end...]
            }
        }
        return hrefs
    }

    // MARK: MOBI / AZW3

    nonisolated private static func extractMOBICover(from url: URL) -> NSImage? {
        MOBICoverExtractor.coverData(from: url).flatMap(NSImage.init(data:))
    }

    // MARK: PDF

    nonisolated private static func extractPDFCover(from url: URL) -> NSImage? {
        guard let doc = PDFDocument(url: url),
              let page = doc.page(at: 0) else { return nil }
        return page.thumbnail(of: CGSize(width: 400, height: 600), for: .mediaBox)
    }

    // MARK: Helpers

    nonisolated static func resolve(_ href: String, dir: String) -> String {
        let h = href.removingPercentEncoding ?? href
        if dir.isEmpty || dir == "." { return h }
        var parts = dir.split(separator: "/").map(String.init)
        for seg in h.split(separator: "/").map(String.init) {
            if seg == ".." { if !parts.isEmpty { parts.removeLast() } }
            else if seg != "." { parts.append(seg) }
        }
        return parts.joined(separator: "/")
    }
}
