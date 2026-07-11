import AppKit

private nonisolated final class DiscoveryImageBox {
    let image: NSImage?
    init(_ image: NSImage?) { self.image = image }
}

actor DiscoveryImageLoader {
    static let shared = DiscoveryImageLoader()

    private let cache: NSCache<NSString, DiscoveryImageBox> = {
        let cache = NSCache<NSString, DiscoveryImageBox>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = ["User-Agent": "Winston/1.0 (macOS eBook manager)"]
        return URLSession(configuration: config)
    }()

    private let maxPixel = 600

    private init() {}

    func image(for url: URL) async -> NSImage? {
        let key = url.absoluteString as NSString
        if let box = cache.object(forKey: key) { return box.image }

        let image = await fetchAndDecode(url)
        let cost = image.map { Int($0.size.width * $0.size.height * 4) } ?? 16
        cache.setObject(DiscoveryImageBox(image), forKey: key, cost: cost)
        return image
    }

    private func fetchAndDecode(_ url: URL) async -> NSImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count > 1_000,
              let cg = ImageTranscoder.decodedImage(from: data, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
