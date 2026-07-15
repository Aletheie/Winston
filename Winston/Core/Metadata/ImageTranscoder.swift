import Foundation
import CoreGraphics
import ImageIO
import AppKit
import UniformTypeIdentifiers

// ImageIO/CoreGraphics only — NSImage drawing is main-thread-affine and this runs off-main.
nonisolated enum ImageTranscoder {

    static let defaultQuality = 0.85
    private static let defaultMaxPixel = 4_096
    private static let maxSourcePixels = 100_000_000

    // MARK: - Decode

    static func decodedImage(from data: Data, maxPixel: Int? = nil) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        if let (width, height) = dimensions(of: source),
           width > maxSourcePixels / max(1, height) {
            return nil
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel ?? defaultMaxPixel
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func dimensions(of source: CGImageSource) -> (Int, Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = props[kCGImagePropertyPixelWidth as String] as? Int,
              let height = props[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        return (width, height)
    }

    // MARK: - Encode

    static func jpegData(from image: CGImage, quality: Double = defaultQuality) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func jpegData(from data: Data, maxPixel: Int? = nil, quality: Double = defaultQuality) -> Data? {
        decodedImage(from: data, maxPixel: maxPixel).flatMap { jpegData(from: $0, quality: quality) }
    }

    static func jpegData(from image: NSImage, quality: Double = defaultQuality) -> Data? {
        cgImage(from: image).flatMap { jpegData(from: $0, quality: quality) }
    }

    // MARK: - Scale

    static func downscaled(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(longest)
        return resized(image,
                       width: max(1, Int(Double(image.width) * scale)),
                       height: max(1, Int(Double(image.height) * scale))) ?? image
    }

    static func scaledToFit(_ image: CGImage, maxWidth: Int, maxHeight: Int) -> CGImage {
        let scale = min(Double(maxWidth) / Double(image.width),
                        Double(maxHeight) / Double(image.height))
        guard scale < 1 else { return image }
        return resized(image,
                       width: max(1, Int(Double(image.width) * scale)),
                       height: max(1, Int(Double(image.height) * scale))) ?? image
    }

    private static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
