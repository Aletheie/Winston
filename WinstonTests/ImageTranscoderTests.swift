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

    @Test func fileDecodeDownsamplesAndNormalizesInvalidPixelLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cover-decode-\(UUID().uuidString).png")
        try pngData(width: 1_200, height: 800).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try #require(ImageTranscoder.decodedImage(from: url, maxPixel: 160))
        #expect(decoded.width == 160)
        #expect(decoded.height <= 107)
        let smallest = try #require(ImageTranscoder.decodedImage(from: url, maxPixel: 0))
        #expect(max(smallest.width, smallest.height) == 1)
    }

    @Test func cacheBoundsActualPixelsEvenWhenLogicalImageSizeIsTiny() async throws {
        let bitmap = try #require(ImageTranscoder.decodedImage(from: pngData(width: 1_200, height: 800)))
        let image = NSImage(cgImage: bitmap, size: NSSize(width: 12, height: 8))
        let cached = try #require(await CoverCache().insert(
            image, for: URL(fileURLWithPath: "/cover-retina.png"), tier: .thumb
        ))
        let pixels = try #require(ImageTranscoder.cgImage(from: cached))
        #expect(max(pixels.width, pixels.height) <= 160)
        #expect(cached.size.width == CGFloat(pixels.width))
        #expect(cached.size.height == CGFloat(pixels.height))
    }

    @Test func newAssetRevisionDoesNotReusePreviouslyMissingCover() async throws {
        let cache = CoverCache()
        let url = URL(fileURLWithPath: "/cover-revision.jpg")
        let assetID = UUID()
        let first = CoverCache.Revision(version: 1, derivedKey: DerivedCoverKey(
            assetID: assetID, contentHash: "first", fileName: "book.epub", sizeBytes: 10, maxPixel: 600
        ))
        let second = CoverCache.Revision(version: 1, derivedKey: DerivedCoverKey(
            assetID: assetID, contentHash: "second", fileName: "book.epub", sizeBytes: 10, maxPixel: 600
        ))
        let counter = CoverLoadCounter()
        let image = try #require(NSImage(data: pngData(width: 120, height: 180)))
        #expect(await cache.resolve(for: url, tier: .display, revision: first) { nil } == nil)
        for _ in 0..<2 {
            let resolved = await cache.resolve(for: url, tier: .display, revision: second) {
                await counter.increment()
                return image
            }
            #expect(resolved != nil)
        }
        #expect(await counter.value == 1)
    }

    @Test func replacingCoverRevisionCancelsOldLoadWithoutOverwritingNewImage() async throws {
        let cache = CoverCache()
        let url = URL(fileURLWithPath: "/cover-pending-revision.jpg")
        let loader = CancellationAwareCoverLoad()
        let first = Task {
            await cache.resolve(
                for: url, tier: .display,
                revision: CoverCache.Revision(version: 1, derivedKey: nil)
            ) { await loader.load() }
        }
        await loader.waitUntilStarted()
        let image = try #require(NSImage(data: pngData(width: 120, height: 180)))
        let resolved = await cache.resolve(
            for: url, tier: .display,
            revision: CoverCache.Revision(version: 2, derivedKey: nil)
        ) { image }
        #expect(resolved != nil)
        #expect(await first.value == nil)
        #expect(await loader.wasCancelled)
        let diagnostics = await cache.diagnostics()
        #expect(diagnostics.cancelledJobCount == 1)
        #expect(diagnostics.completedJobCount == 1)
    }

    @Test func scheduledFileDecodesStayWithinBothWorkerLimits() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cover-workers-\(UUID().uuidString).png")
        try pngData(width: 1_200, height: 800).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let scheduler = CoverWorkScheduler(ioLimit: 3, cpuLimit: 2)
        let dimensions = await withTaskGroup(of: NSSize?.self, returning: [NSSize?].self) { group in
            for _ in 0..<48 {
                group.addTask {
                    await scheduler.storedImage(at: url, maxPixel: 160)?.size
                }
            }
            var result: [NSSize?] = []
            for await size in group { result.append(size) }
            return result
        }
        #expect(dimensions.count == 48)
        #expect(dimensions.allSatisfy { $0?.width == 160 })
        let diagnostics = await scheduler.diagnostics()
        #expect(diagnostics.peakIOCount <= 3)
        #expect(diagnostics.peakCPUCount <= 2)
        #expect(diagnostics.activeIOCount == 0)
        #expect(diagnostics.activeCPUCount == 0)
    }

    @Test(arguments: ["png", "svg"])
    func extractedPreviewUsesRequestedTierBeforeEncoding(format: String) async throws {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest><item id="cover" href="cover.\(format)" media-type="image/\(format)" properties="cover-image"/></manifest>
        </package>
        """
        let data = format == "png" ? pngData(width: 1_200, height: 1_800) : Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="1200" height="1800">
          <rect width="1200" height="1800" fill="red"/>
        </svg>
        """.utf8)
        let url = try EPUBFixture.makeWithOPF(opf, additionalEntries: [
            "OEBPS/cover.\(format)": data,
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = try #require(await CoverWorkScheduler().extractAndEncode(from: url, maxDimension: 160))
        let encoded = try #require(ImageTranscoder.decodedImage(from: result.data))
        #expect(result.image.size.height == 160)
        #expect(encoded.height == 160)
        #expect(encoded.width <= 107)
    }

    @Test func managedPreviewValidatesAgainstCapturedDirectory() async throws {
        let url = try EPUBFixture.make(title: "Captured cover root", author: "Reader")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // This fixture deliberately lives outside the current AppPaths root.
        // A queued request must keep using the root from its catalog snapshot.
        let result = await CoverWorkScheduler().extractAndEncode(
            from: url, maxDimension: 160,
            validatingManagedDirectory: url.deletingLastPathComponent()
        )
        #expect(result != nil)
    }

    @Test func managedPreviewRejectsEscapingSymlinkBeforeOpeningBook() async throws {
        let target = try EPUBFixture.make(title: "Outside managed root", author: "Reader")
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ManagedCover-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appending(path: "linked.epub")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(BookFileStore.catalogURL(for: "linked.epub", in: directory) == link)
        let result = await CoverWorkScheduler().extractAndEncode(
            from: link, maxDimension: 160, validatingManagedDirectory: directory
        )
        #expect(result == nil)
        #expect(EPUBArchive.openCount(for: link) == 0)
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
