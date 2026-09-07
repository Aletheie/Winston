import AppKit
import Foundation

private nonisolated struct DiscoveryImageRequestKey: Hashable, Sendable {
    enum Context: Hashable, Sendable {
        case discovery
        case opds(OPDSCatalogAccess)
    }

    let url: URL
    let context: Context
}

private nonisolated final class DiscoveryImageCacheKey: NSObject {
    let value: DiscoveryImageRequestKey

    init(_ value: DiscoveryImageRequestKey) {
        self.value = value
    }

    override var hash: Int { value.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? DiscoveryImageCacheKey)?.value == value
    }
}

private nonisolated final class DiscoveryImageBox {
    let image: NSImage?

    init(_ image: NSImage?) {
        self.image = image
    }
}

actor DiscoveryImageLoader {
    nonisolated static let maximumResponseBytes = 12 * 1024 * 1024
    static let shared = DiscoveryImageLoader()

    private let cache: NSCache<DiscoveryImageCacheKey, DiscoveryImageBox> = {
        let cache = NSCache<DiscoveryImageCacheKey, DiscoveryImageBox>()
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 400
        return cache
    }()

    private let session: URLSession
    private let maximumBytes: Int
    private let maxPixel = 600
    private var inFlight: [
        DiscoveryImageRequestKey: Task<NSImage?, Never>
    ] = [:]

    private init() {
        maximumBytes = Self.maximumResponseBytes
        session = URLSession(configuration: Self.makeConfiguration())
    }

    init(
        configuration: URLSessionConfiguration,
        maximumResponseBytes: Int = DiscoveryImageLoader.maximumResponseBytes
    ) {
        maximumBytes = max(1, maximumResponseBytes)
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL) async -> NSImage? {
        await image(for: DiscoveryImageRequestKey(
            url: url,
            context: .discovery
        ))
    }

    func image(
        for url: URL,
        access: OPDSCatalogAccess
    ) async -> NSImage? {
        await image(for: DiscoveryImageRequestKey(
            url: url,
            context: .opds(access)
        ))
    }

    private func image(
        for key: DiscoveryImageRequestKey
    ) async -> NSImage? {
        let cacheKey = DiscoveryImageCacheKey(key)
        if let box = cache.object(forKey: cacheKey) {
            return box.image
        }
        if let request = inFlight[key] {
            return await request.value
        }

        let request = Task { [self] in
            await fetchAndDecode(key)
        }
        inFlight[key] = request
        let image = await request.value
        inFlight[key] = nil
        let cost = image.map {
            Int($0.size.width * $0.size.height * 4)
        } ?? 16
        cache.setObject(
            DiscoveryImageBox(image),
            forKey: cacheKey,
            cost: cost
        )
        return image
    }

    private func fetchAndDecode(
        _ key: DiscoveryImageRequestKey
    ) async -> NSImage? {
        let request: URLRequest
        let policy: OPDSRequestPolicy?
        switch key.context {
        case .discovery:
            guard key.url.isDiscoveryImageHTTPURL else { return nil }
            var discoveryRequest = URLRequest(url: key.url)
            discoveryRequest.setValue(
                "image/*",
                forHTTPHeaderField: "Accept"
            )
            request = discoveryRequest
            policy = nil
        case .opds(let access):
            let catalogPolicy = OPDSRequestPolicy(access: access)
            guard let catalogRequest = try? catalogPolicy.request(
                for: key.url,
                accept: "image/*"
            ) else {
                return nil
            }
            request = catalogRequest
            policy = catalogPolicy
        }

        guard let data = await downloadData(
            for: request,
            policy: policy
        ),
        let cg = ImageTranscoder.decodedImage(
            from: data,
            maxPixel: maxPixel
        ) else {
            return nil
        }
        return NSImage(
            cgImage: cg,
            size: NSSize(width: cg.width, height: cg.height)
        )
    }

    private func downloadData(
        for request: URLRequest,
        policy: OPDSRequestPolicy?
    ) async -> Data? {
        guard let download = try? await BoundedDownload.perform(
            using: session,
            request: request,
            policy: policy,
            maximumBytes: Int64(maximumBytes)
        ) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: download.fileURL) }
        guard accepts(download.response, policy: policy) else { return nil }
        return data(
            from: download.fileURL,
            byteCount: download.byteCount
        )
    }

    private func accepts(
        _ response: URLResponse,
        policy: OPDSRequestPolicy?
    ) -> Bool {
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let responseURL = http.url,
              responseURL.isDiscoveryImageHTTPURL else {
            return false
        }
        guard let policy else { return true }
        return (try? policy.validateTransport(for: responseURL)) != nil
    }

    private func data(
        from fileURL: URL,
        byteCount: Int64
    ) -> Data? {
        guard byteCount > 1_000,
              let data = try? Data(
                  contentsOf: fileURL,
                  options: .mappedIfSafe
              ),
              data.count == Int(byteCount) else {
            return nil
        }
        return data
    }

    private nonisolated static func makeConfiguration()
        -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.urlCache = .shared
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Winston/1.0 (macOS eBook manager)",
        ]
        return configuration
    }
}

private extension URL {
    nonisolated var isDiscoveryImageHTTPURL: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
