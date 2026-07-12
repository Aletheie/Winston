import Testing
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Winston

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
}
