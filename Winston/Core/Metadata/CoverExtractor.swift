import AppKit
import PDFKit
import os

// MARK: - Cover Cache

private nonisolated final class CoverBox: @unchecked Sendable {
    let image: NSImage?
    let revision: CoverCache.Revision?

    init(_ image: NSImage?, revision: CoverCache.Revision?) {
        self.image = image
        self.revision = revision
    }
}

nonisolated struct CoverCacheDiagnostics: Sendable, Equatable {
    var startedJobCount = 0
    var completedJobCount = 0
    var cancelledJobCount = 0
    var coalescedRequestCount = 0
    var activeJobCount = 0
    var activeSubscriberCount = 0
}

/// A subscriber-scoped handle to one coalesced cover request. Releasing the
/// last lease schedules cancellation of work that no longer has a consumer.
nonisolated final class CoverLease: @unchecked Sendable {
    private let resolveAction: @Sendable () async -> NSImage?
    private let releaseAction: @Sendable () -> Void
    private let released = OSAllocatedUnfairLock<Bool>(initialState: false)

    fileprivate init(
        resolve: @escaping @Sendable () async -> NSImage?,
        release: @escaping @Sendable () -> Void
    ) {
        resolveAction = resolve
        releaseAction = release
    }

    func image() async -> NSImage? {
        await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                release()
                return nil
            }
            let image = await resolveAction()
            release()
            return Task.isCancelled ? nil : image
        } onCancel: {
            self.release()
        }
    }

    func cancel() {
        release()
    }

    private func release() {
        let shouldRelease = released.withLock { released in
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease { releaseAction() }
    }

    deinit {
        release()
    }
}

// Tiered (thumb for rows, display for cards) with a byte-cost limit.
actor CoverCache {
    static let shared = CoverCache()

    /// File names alone do not identify an extracted preview: selecting a new
    /// primary asset or replacing its contents must also invalidate misses.
    struct Revision: Hashable, Sendable {
        let version: Int
        let derivedKey: DerivedCoverKey?
    }

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

    private let cache: NSCache<NSString, CoverBox>
    private let cancellationGrace: Duration
    private struct PendingLoad {
        let id: UUID
        let revision: Revision?
        let task: Task<NSImage?, Never>
        var subscribers: Set<UUID>
        var keepAlive: Bool
        var cancellationTask: Task<Void, Never>?
    }
    private var pendingLoads: [String: PendingLoad] = [:]
    private var diagnosticTotals = CoverCacheDiagnostics()

    init(
        totalCostLimit: Int = 96 * 1024 * 1024,
        countLimit: Int = 4_096,
        cancellationGrace: Duration = .milliseconds(180)
    ) {
        let cache = NSCache<NSString, CoverBox>()
        cache.totalCostLimit = max(1, totalCostLimit)
        cache.countLimit = max(1, countLimit)
        self.cache = cache
        self.cancellationGrace = cancellationGrace
    }

    private func key(_ url: URL, _ tier: Tier) -> String {
        "\(tier)|\(url.path)"
    }

    func image(for url: URL, tier: Tier) -> NSImage?? {
        guard let box = cache.object(forKey: key(url, tier) as NSString) else { return nil }
        return .some(box.image)
    }

    func lease(
        for url: URL,
        tier: Tier,
        revision: Revision? = nil,
        keepAlive: Bool = false,
        loader: @escaping @Sendable () async -> NSImage?
    ) -> CoverLease {
        let cacheKey = key(url, tier)
        if let cached = cache.object(forKey: cacheKey as NSString),
           revision == nil || cached.revision == revision {
            return CoverLease(resolve: { cached.image }, release: {})
        }
        if pendingLoads[cacheKey]?.revision != revision {
            cancelPendingLoad(for: cacheKey)
        }
        cache.removeObject(forKey: cacheKey as NSString)

        let subscriberID = UUID()
        let pending: PendingLoad
        if var existing = pendingLoads[cacheKey] {
            existing.cancellationTask?.cancel()
            existing.cancellationTask = nil
            existing.subscribers.insert(subscriberID)
            existing.keepAlive = existing.keepAlive || keepAlive
            pendingLoads[cacheKey] = existing
            pending = existing
            diagnosticTotals.coalescedRequestCount += 1
        } else {
            let id = UUID()
            let task = Task(priority: .utility) { await loader() }
            pending = PendingLoad(
                id: id,
                revision: revision,
                task: task,
                subscribers: [subscriberID],
                keepAlive: keepAlive,
                cancellationTask: nil
            )
            pendingLoads[cacheKey] = pending
            diagnosticTotals.startedJobCount += 1
        }

        let task = pending.task
        let jobID = pending.id
        return CoverLease(
            resolve: { [weak self] in
                let loaded = await task.value
                guard let self else { return nil }
                return await self.complete(
                    loaded,
                    for: url,
                    tier: tier,
                    cacheKey: cacheKey,
                    jobID: jobID,
                    wasCancelled: task.isCancelled
                )
            },
            release: { [weak self] in
                guard let self else { return }
                Task {
                    await self.release(
                        subscriberID,
                        cacheKey: cacheKey,
                        jobID: jobID
                    )
                }
            }
        )
    }

    func resolve(
        for url: URL,
        tier: Tier,
        revision: Revision? = nil,
        keepAlive: Bool = false,
        loader: @escaping @Sendable () async -> NSImage?
    ) async -> NSImage? {
        let lease = lease(for: url, tier: tier, revision: revision, keepAlive: keepAlive, loader: loader)
        return await lease.image()
    }

    @discardableResult
    func insert(
        _ image: NSImage?, for url: URL, tier: Tier, revision: Revision? = nil
    ) -> NSImage? {
        let scaled = image.map { CoverCache.downscaled($0, maxDimension: tier.maxDimension) }
        let cost = scaled.map { Int($0.size.width * $0.size.height * 4) } ?? 16
        cache.setObject(CoverBox(scaled, revision: revision), forKey: key(url, tier) as NSString, cost: cost)
        return scaled
    }

    // Drops every tier — a tier-scoped insert would leave stale renditions.
    func replace(_ image: NSImage?, for url: URL) {
        invalidate(for: url)
        insert(image, for: url, tier: .display)
    }

    func invalidate(for url: URL) {
        cancelPendingLoad(for: key(url, .thumb))
        cancelPendingLoad(for: key(url, .display))
        cache.removeObject(forKey: key(url, .thumb) as NSString)
        cache.removeObject(forKey: key(url, .display) as NSString)
    }

    func diagnostics() -> CoverCacheDiagnostics {
        var result = diagnosticTotals
        result.activeJobCount = pendingLoads.count
        result.activeSubscriberCount = pendingLoads.values.reduce(0) {
            $0 + $1.subscribers.count
        }
        return result
    }

    private func complete(
        _ loaded: NSImage?,
        for url: URL,
        tier: Tier,
        cacheKey: String,
        jobID: UUID,
        wasCancelled: Bool
    ) -> NSImage? {
        guard let pending = pendingLoads[cacheKey], pending.id == jobID else {
            return wasCancelled ? nil : cache.object(forKey: cacheKey as NSString)?.image
        }
        pending.cancellationTask?.cancel()
        pendingLoads.removeValue(forKey: cacheKey)
        guard !wasCancelled else {
            diagnosticTotals.cancelledJobCount += 1
            return nil
        }
        diagnosticTotals.completedJobCount += 1
        if let cached = cache.object(forKey: cacheKey as NSString) { return cached.image }
        return insert(loaded, for: url, tier: tier, revision: pending.revision)
    }

    private func release(_ subscriberID: UUID, cacheKey: String, jobID: UUID) {
        guard var pending = pendingLoads[cacheKey], pending.id == jobID else { return }
        pending.subscribers.remove(subscriberID)
        guard pending.subscribers.isEmpty, !pending.keepAlive else {
            pendingLoads[cacheKey] = pending
            return
        }

        pending.cancellationTask?.cancel()
        pending.cancellationTask = Task { [weak self, cancellationGrace] in
            do {
                try await Task.sleep(for: cancellationGrace)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.cancelIfUnobserved(cacheKey: cacheKey, jobID: jobID)
        }
        pendingLoads[cacheKey] = pending
    }

    private func cancelIfUnobserved(cacheKey: String, jobID: UUID) {
        guard let pending = pendingLoads[cacheKey],
              pending.id == jobID,
              pending.subscribers.isEmpty,
              !pending.keepAlive else { return }
        pendingLoads.removeValue(forKey: cacheKey)
        pending.task.cancel()
        diagnosticTotals.cancelledJobCount += 1
    }

    private func cancelPendingLoad(for cacheKey: String) {
        guard let pending = pendingLoads.removeValue(forKey: cacheKey) else { return }
        pending.cancellationTask?.cancel()
        pending.task.cancel()
        diagnosticTotals.cancelledJobCount += 1
    }

    nonisolated static func downscaled(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        // NSImage.size is in points; a tiny logical size can still retain a
        // multi-megapixel bitmap. Normalize by actual pixels before costing.
        guard let cg = ImageTranscoder.cgImage(from: image) else { return image }
        let scaled = ImageTranscoder.downscaled(cg, maxPixel: Int(maxDimension))
        return NSImage(cgImage: scaled, size: NSSize(width: scaled.width, height: scaled.height))
    }
}

private nonisolated func cancellationPropagatingDetached<Value: Sendable>(
    priority: TaskPriority,
    operation: @escaping @Sendable () -> Value
) async -> Value {
    let task = Task.detached(priority: priority, operation: operation)
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

nonisolated struct CoverWorkSchedulerDiagnostics: Sendable, Equatable {
    let activeIOCount: Int
    let peakIOCount: Int
    let activeCPUCount: Int
    let peakCPUCount: Int
}

actor CoverWorkScheduler {
    static let shared = CoverWorkScheduler()

    private let ioPermits: AsyncPermitPool
    private let cpuPermits: AsyncPermitPool

    init(ioLimit: Int = 2, cpuLimit: Int = 2) {
        ioPermits = AsyncPermitPool(limit: ioLimit)
        cpuPermits = AsyncPermitPool(limit: cpuLimit)
    }

    func storedCover(for owner: CoverOwner, maxPixel: Int) async -> NSImage? {
        await storedImage(at: CoverStore.url(for: owner), maxPixel: maxPixel)
    }

    func storedCover(for uuid: UUID, maxPixel: Int) async -> NSImage? {
        await storedCover(for: .edition(uuid), maxPixel: maxPixel)
    }

    func storedDerivedCover(
        for key: DerivedCoverKey,
        maxPixel: Int
    ) async -> NSImage? {
        let url = await DerivedCoverStore.shared.fileURL(for: key)
        return await storedImage(at: url, maxPixel: maxPixel)
    }

    func storedImage(at url: URL, maxPixel: Int) async -> NSImage? {
        await runImageWork {
            guard let decoded = ImageTranscoder.decodedImage(from: url, maxPixel: maxPixel) else {
                return nil
            }
            return NSImage(
                cgImage: decoded,
                size: NSSize(width: decoded.width, height: decoded.height)
            )
        }
    }

    func extractAndEncode(
        from url: URL,
        maxDimension: CGFloat,
        validatingManagedDirectory directory: URL? = nil
    ) async -> (image: NSImage, data: Data)? {
        await runImageWork {
            // View construction uses catalog paths only. Resolve symlinks on
            // the bounded worker immediately before I/O, against the captured
            // directory rather than a possibly changed process-wide root.
            if let directory {
                guard BookFileStore.validatedURL(for: url.lastPathComponent, in: directory) == url else {
                    return nil
                }
            }
            guard let image = CoverExtractor.extractCover(
                from: url, maxPixel: Int(maxDimension)
            ), !Task.isCancelled,
            let data = ImageTranscoder.jpegData(from: image) else { return nil }
            return (image, data)
        }
    }

    /// Hold both permits until temporary compressed bytes and full decoder
    /// state are released. Splitting read and decode into separate queues let
    /// an arbitrarily large backlog retain image Data between the two lanes.
    private func runImageWork<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value?
    ) async -> Value? {
        do {
            return try await ioPermits.run { [cpuPermits] in
                try await cpuPermits.run {
                    await cancellationPropagatingDetached(priority: .utility) {
                        autoreleasepool {
                            guard !Task.isCancelled else { return nil }
                            let result = operation()
                            return Task.isCancelled ? nil : result
                        }
                    }
                }
            }
        } catch {
            return nil
        }
    }

    func installDerived(
        _ data: Data,
        for key: DerivedCoverKey
    ) async -> Bool {
        do {
            return try await ioPermits.run {
                try Task.checkCancellation()
                return await DerivedCoverStore.shared.installIfMissing(
                    data,
                    for: key
                )
            }
        } catch {
            return false
        }
    }

    func diagnostics() async -> CoverWorkSchedulerDiagnostics {
        let io = await ioPermits.usage()
        let cpu = await cpuPermits.usage()
        return CoverWorkSchedulerDiagnostics(
            activeIOCount: io.active,
            peakIOCount: io.peak,
            activeCPUCount: cpu.active,
            peakCPUCount: cpu.peak
        )
    }
}

// MARK: - Cover Extractor

enum CoverExtractor {

    nonisolated static func extractCover(from url: URL, maxPixel: Int? = nil) -> NSImage? {
        guard !Task.isCancelled else { return nil }
        switch url.pathExtension.lowercased() {
        case "epub":                return extractEPUBCover(from: url, maxPixel: maxPixel)
        case "mobi", "azw", "azw3": return coverImage(MOBICoverExtractor.coverData(from: url), maxPixel: maxPixel)
        case "pdf":                 return extractPDFCover(from: url, maxPixel: maxPixel)
        default:                    return nil
        }
    }

    // MARK: EPUB

    nonisolated private static func extractEPUBCover(from url: URL, maxPixel: Int?) -> NSImage? {
        guard let archive = try? EPUBArchive(url: url) else { return nil }
        return coverImage(epubCoverData(from: archive), maxPixel: maxPixel)
    }

    nonisolated private static func coverImage(_ data: Data?, maxPixel: Int?) -> NSImage? {
        guard let data else { return nil }
        guard let maxPixel else { return NSImage(data: data) }
        let image: CGImage
        if let bitmap = ImageTranscoder.decodedImage(from: data, maxPixel: maxPixel) {
            image = bitmap
        } else {
            // AppKit supports SVG covers, but ImageIO's thumbnail API does
            // not. Size the vector before rasterizing so this compatibility
            // path never falls back to decoding a full-size raster image.
            guard let document = try? XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever),
                  document.rootElement()?.localName == "svg",
                  let vector = NSImage(data: data) else { return nil }
            let longest = max(vector.size.width, vector.size.height)
            guard longest.isFinite, longest > 0 else { return nil }
            let scale = min(1, CGFloat(max(1, maxPixel)) / longest)
            vector.size = NSSize(width: vector.size.width * scale, height: vector.size.height * scale)
            guard let bitmap = ImageTranscoder.cgImage(from: vector) else { return nil }
            // AppKit may rasterize points at the connected display's Retina
            // scale. Normalize the resulting pixels to the requested tier.
            image = ImageTranscoder.downscaled(bitmap, maxPixel: max(1, maxPixel))
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    nonisolated static func epubCoverData(from archive: EPUBArchive) -> Data? {
        guard !Task.isCancelled,
              let containerData = archive.entry("META-INF/container.xml"),
              let opfPath = MetadataExtractor.parseOPFPath(from: containerData),
              let opfData = archive.entry(opfPath),
              let doc = try? XMLDocument(data: opfData, options: .nodeLoadExternalEntitiesNever) else { return nil }

        let opfDir = (opfPath as NSString).deletingLastPathComponent
        return epubCoverData(doc: doc, opfDir: opfDir, archive: archive)
    }

    nonisolated static func epubCoverData(doc: XMLDocument, opfDir: String, archive: EPUBArchive) -> Data? {
        for candidate in coverCandidates(from: doc, opfDir: opfDir, archive: archive) {
            guard !Task.isCancelled else { return nil }
            if let data = archive.entry(candidate) { return data }
        }
        return nil
    }

    nonisolated static func coverCandidates(
        from doc: XMLDocument, opfDir: String, archive: EPUBArchive
    ) -> [String] {
        guard !Task.isCancelled else { return [] }
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
                guard !Task.isCancelled else { return [] }
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
            guard !Task.isCancelled else { return [] }
            var search = html[html.startIndex...]
            while let range = search.range(of: attr) {
                guard !Task.isCancelled else { return [] }
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

    // MARK: PDF

    nonisolated private static func extractPDFCover(from url: URL, maxPixel: Int?) -> NSImage? {
        guard let doc = PDFDocument(url: url),
              let page = doc.page(at: 0) else { return nil }
        let dimension = CGFloat(max(1, maxPixel ?? 600))
        return page.thumbnail(of: CGSize(width: dimension * 2 / 3, height: dimension), for: .mediaBox)
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
