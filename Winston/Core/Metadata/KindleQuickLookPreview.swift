import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct KindleQuickLookPayload: Equatable, Sendable {
    let imageData: Data
    let contentTypeIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    let title: String
}

nonisolated enum KindleQuickLookPreview {
    private static let supportedExtensions: Set<String> = ["mobi", "azw", "azw3"]

    static func payload(for url: URL) -> KindleQuickLookPayload? {
        guard supportedExtensions.contains(url.pathExtension.lowercased()),
              let imageData = MOBICoverExtractor.coverData(from: url),
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let contentType = UTType(typeIdentifier),
              contentType.conforms(to: .image) else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 600
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 800
        return KindleQuickLookPayload(
            imageData: imageData,
            contentTypeIdentifier: contentType.identifier,
            pixelWidth: max(width, 1),
            pixelHeight: max(height, 1),
            title: url.deletingPathExtension().lastPathComponent
        )
    }
}
