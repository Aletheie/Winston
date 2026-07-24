import AppKit
import PDFKit
import os

// MARK: - Cover Cache

private nonisolated final class CoverBox: @unchecked Sendable {
    let image: NSImage?
    init(_ image: NSImage?) { self.image = image }
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
        keepAlive: Bool = false,
        loader: @escaping @Sendable () async -> NSImage?
    ) -> CoverLease {
        let cacheKey = key(url, tier)
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return CoverLease(resolve: { cached.image }, release: {})
        }

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
                task: task,
                subscribers: [subscriberID],
                keepAlive: keepAlive,
                cancellationTask: nil
            )
            pendingLoads[cacheKey] = pending
            diagnosticTotals.startedJobCount += 1
        }

        return CoverLease(
            resolve: { [weak self] in
                let loaded = await pending.task.value
                guard let self else { return nil }
                return await self.complete(
                    loaded,
                    for: url,
                    tier: tier,
                    cacheKey: cacheKey,
                    jobID: pending.id,
                    wasCancelled: pending.task.isCancelled
                )
            },
            release: { [weak self] in
                guard let self else { return }
                Task {
                    await self.release(
                        subscriberID,
                        cacheKey: cacheKey,
                        jobID: pending.id
                    )
                }
            }
        )
    }

    func resolve(
        for url: URL,
        tier: Tier,
        keepAlive: Bool = false,
        loader: @escaping @Sendable () async -> NSImage?
    ) async -> NSImage? {
        let lease = lease(for: url, tier: tier, keepAlive: keepAlive, loader: loader)
        return await lease.image()
    }

    @discardableResult
    func insert(_ image: NSImage?, for url: URL, tier: Tier) -> NSImage? {
        let scaled = image.map { CoverCache.downscaled($0, maxDimension: tier.maxDimension) }
        let cost = scaled.map { Int($0.size.width * $0.size.height * 4) } ?? 16
        cache.setObject(CoverBox(scaled), forKey: key(url, tier) as NSString, cost: cost)
        return scaled
    }

    // Drops every tier — a tier-scoped insert would leave stale renditions.
    func replace(_ image: NSImage?, for url: URL) {
        cancelPendingLoad(for: key(url, .thumb))
        cancelPendingLoad(for: key(url, .display))
        cache.removeObject(forKey: key(url, .thumb) as NSString)
        cache.removeObject(forKey: key(url, .display) as NSString)
        insert(image, for: url, tier: .display)
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
            return cache.object(forKey: cacheKey as NSString)?.image
        }
        pending.cancellationTask?.cancel()
        pendingLoads.removeValue(forKey: cacheKey)
        guard !wasCancelled else {
            diagnosticTotals.cancelledJobCount += 1
            return nil
        }
        diagnosticTotals.completedJobCount += 1
        if let cached = cache.object(forKey: cacheKey as NSString) { return cached.image }
        return insert(loaded, for: url, tier: tier)
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
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0,
              let cg = ImageTranscoder.cgImage(from: image) else { return image }
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

private actor AsyncPermitPool {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var activeCount = 0
    private var peakActiveCount = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    func usage() -> (active: Int, peak: Int) {
        (activeCount, peakActiveCount)
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if activeCount < limit {
            activeCount += 1
            peakActiveCount = max(peakActiveCount, activeCount)
            return
        }

        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        guard granted else { throw CancellationError() }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume(returning: true)
        } else {
            activeCount = max(0, activeCount - 1)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
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

    func storedCover(for uuid: UUID, maxPixel: Int) async -> NSImage? {
        let data: Data?
        do {
            data = try await ioPermits.run {
                try Task.checkCancellation()
                return await cancellationPropagatingDetached(priority: .background) {
                    guard !Task.isCancelled else { return nil }
                    return CoverStore.loadData(for: uuid)
                }
            }
        } catch {
            return nil
        }
        guard let data, !Task.isCancelled else { return nil }

        do {
            return try await cpuPermits.run {
                try Task.checkCancellation()
                return await cancellationPropagatingDetached(priority: .utility) {
                    guard !Task.isCancelled,
                          let decoded = ImageTranscoder.decodedImage(
                              from: data,
                              maxPixel: maxPixel
                          ) else { return nil }
                    return NSImage(
                        cgImage: decoded,
                        size: NSSize(width: decoded.width, height: decoded.height)
                    )
                }
            }
        } catch {
            return nil
        }
    }

    func extractAndEncode(
        from url: URL,
        maxDimension: CGFloat
    ) async -> (image: NSImage, data: Data)? {
        let extracted: NSImage?
        do {
            extracted = try await ioPermits.run {
                try Task.checkCancellation()
                return await cancellationPropagatingDetached(priority: .background) {
                    guard !Task.isCancelled else { return nil }
                    let image = CoverExtractor.extractCover(from: url)
                    return Task.isCancelled ? nil : image
                }
            }
        } catch {
            return nil
        }
        guard let extracted, !Task.isCancelled else { return nil }

        do {
            return try await cpuPermits.run {
                try Task.checkCancellation()
                return await cancellationPropagatingDetached(priority: .utility) {
                    guard !Task.isCancelled,
                          let data = ImageTranscoder.jpegData(from: extracted) else { return nil }
                    let scaled = CoverCache.downscaled(
                        extracted,
                        maxDimension: maxDimension
                    )
                    return Task.isCancelled ? nil : (scaled, data)
                }
            }
        } catch {
            return nil
        }
    }

    func install(
        _ data: Data,
        using token: CoverMutationToken
    ) async -> Bool {
        do {
            return try await ioPermits.run {
                try Task.checkCancellation()
                return await CoverRepository.shared.install(
                    data,
                    using: token,
                    onlyIfMissing: true
                ) != nil
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

    nonisolated static func extractCover(from url: URL) -> NSImage? {
        guard !Task.isCancelled else { return nil }
        switch url.pathExtension.lowercased() {
        case "epub":                return extractEPUBCover(from: url)
        case "mobi", "azw", "azw3": return extractMOBICover(from: url)
        case "pdf":                 return extractPDFCover(from: url)
        default:                    return nil
        }
    }

    // MARK: EPUB

    nonisolated private static func extractEPUBCover(from url: URL) -> NSImage? {
        guard let archive = try? EPUBArchive(url: url) else { return nil }
        return epubCoverData(from: archive).flatMap(NSImage.init(data:))
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
