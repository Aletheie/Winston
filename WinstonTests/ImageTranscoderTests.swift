import Testing
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Winston

private actor CoverLoadCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor CancellationAwareCoverLoad {
    private(set) var startCount = 0
    private(set) var wasCancelled = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func load(duration: Duration = .seconds(60)) async -> NSImage? {
        startCount += 1
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        do {
            try await Task.sleep(for: duration)
        } catch {
            wasCancelled = true
        }
        return nil
    }

    func waitUntilStarted() async {
        if startCount > 0 { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
}

@MainActor
struct ImageTranscoderTests {

    private func pngData(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func transcodesToJPEGWithMagicBytes() throws {
        let jpeg = try #require(ImageTranscoder.jpegData(from: pngData(width: 100, height: 50)))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func downscaleHonorsMaxPixelOnLongEdge() throws {
        let image = try #require(ImageTranscoder.decodedImage(from: pngData(width: 800, height: 400), maxPixel: 200))
        #expect(max(image.width, image.height) <= 200)
        #expect(abs(Double(image.width) / Double(image.height) - 2.0) < 0.05)
    }

    @Test func neverUpscales() throws {
        let image = try #require(ImageTranscoder.decodedImage(from: pngData(width: 60, height: 40), maxPixel: 1_000))
        #expect(image.width == 60)
        #expect(image.height == 40)
    }

    @Test func garbageDataDecodesToNil() {
        #expect(ImageTranscoder.jpegData(from: Data("definitely not an image".utf8)) == nil)
        #expect(ImageTranscoder.decodedImage(from: Data()) == nil)
    }

    @Test func exifOrientationIsAppliedOnDecode() throws {
        let source = try #require(ImageTranscoder.decodedImage(from: pngData(width: 200, height: 100)))
        let tagged = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(tagged, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, source, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        let decoded = try #require(ImageTranscoder.decodedImage(from: tagged as Data))
        #expect(decoded.width == 100)
        #expect(decoded.height == 200)
    }

    @Test func scaledToFitConstrainsBothAxes() throws {
        let image = try #require(ImageTranscoder.decodedImage(from: pngData(width: 1_000, height: 100)))
        let fitted = ImageTranscoder.scaledToFit(image, maxWidth: 330, maxHeight: 470)
        #expect(fitted.width <= 330)
        #expect(fitted.height <= 470)

        let tall = try #require(ImageTranscoder.decodedImage(from: pngData(width: 100, height: 1_000)))
        let fittedTall = ImageTranscoder.scaledToFit(tall, maxWidth: 330, maxHeight: 470)
        #expect(fittedTall.width <= 330)
        #expect(fittedTall.height <= 470)
    }

    @Test func concurrentCoverRequestsShareOneLoad() async {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cover-cache-\(UUID().uuidString).epub")
        let counter = CoverLoadCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = await CoverCache.shared.resolve(for: url, tier: .display) {
                        await counter.increment()
                        try? await Task.sleep(for: .milliseconds(40))
                        return nil
                    }
                }
            }
        }

        let loadCount = await counter.value
        #expect(loadCount == 1)
    }

    @Test func lastCoverLeaseCancelsUnobservedLoadAfterGracePeriod() async {
        let cache = CoverCache(cancellationGrace: .milliseconds(20))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cover-lease-cancel-\(UUID().uuidString).epub")
        let loader = CancellationAwareCoverLoad()

        let request = Task {
            let lease = await cache.lease(for: url, tier: .display) {
                await loader.load()
            }
            _ = await lease.image()
        }
        await loader.waitUntilStarted()
        request.cancel()
        await request.value

        let diagnostics = await cache.diagnostics()
        #expect(await loader.wasCancelled)
        #expect(diagnostics.startedJobCount == 1)
        #expect(diagnostics.cancelledJobCount == 1)
        #expect(diagnostics.completedJobCount == 0)
        #expect(diagnostics.activeJobCount == 0)
        #expect(diagnostics.activeSubscriberCount == 0)
    }

    @Test func newCoverLeaseDuringGracePeriodReusesPendingLoad() async {
        let cache = CoverCache(cancellationGrace: .milliseconds(80))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cover-lease-grace-\(UUID().uuidString).epub")
        let loader = CancellationAwareCoverLoad()

        let first = Task {
            let lease = await cache.lease(for: url, tier: .display) {
                await loader.load(duration: .milliseconds(45))
            }
            _ = await lease.image()
        }
        await loader.waitUntilStarted()
        first.cancel()
        try? await Task.sleep(for: .milliseconds(10))

        let second = Task {
            let lease = await cache.lease(for: url, tier: .display) {
                await loader.load(duration: .milliseconds(45))
            }
            _ = await lease.image()
        }
        await first.value
        await second.value

        let diagnostics = await cache.diagnostics()
        #expect(await loader.startCount == 1)
        #expect(!(await loader.wasCancelled))
        #expect(diagnostics.startedJobCount == 1)
        #expect(diagnostics.coalescedRequestCount == 1)
        #expect(diagnostics.completedJobCount == 1)
        #expect(diagnostics.cancelledJobCount == 0)
    }
}
