import SwiftUI
import SwiftData

struct BookCoverImageView: View {
    let book: Book
    var tier: CoverCache.Tier = .display

    @Environment(\.theme) private var theme
    @State private var coverImage: NSImage?

    var body: some View {
        let accents = theme.coverAccents(for: book)
        Color.clear
            .overlay {
                if let image = coverImage {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    BookCoverArt(accent1: accents.primary, accent2: accents.secondary)
                }
            }
            .clipped()
            .task(id: "\(book.fileName)#\(book.coverVersion)") {
                coverImage = nil
                let resolved = await resolvedCover(for: book.fileURL, uuid: book.uuid)
                guard !Task.isCancelled else { return }
                coverImage = resolved
            }
    }

    private func resolvedCover(for url: URL, uuid: UUID) async -> NSImage? {
        let maxDimension = tier.maxDimension
        let maxPixel = Int(maxDimension)
        return await CoverCache.shared.resolve(for: url, tier: tier) {
            if let stored = await Task.detached(priority: .background, operation: {
                if let data = CoverStore.loadData(for: uuid),
                   let decoded = ImageTranscoder.decodedImage(from: data, maxPixel: maxPixel) {
                    return NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                }
                return nil
            }).value {
                return stored
            }
            let token = await CoverRepository.shared.beginBackgroundMutation(for: uuid)
            let prepared = await Task.detached(priority: .background) { () -> (NSImage, Data)? in
                guard let extracted = CoverExtractor.extractCover(from: url),
                      let data = ImageTranscoder.jpegData(from: extracted) else { return nil }
                return (extracted, data)
            }.value
            guard let (extracted, data) = prepared else { return nil }
            if await CoverRepository.shared.install(data, using: token, onlyIfMissing: true) != nil {
                return CoverCache.downscaled(extracted, maxDimension: maxDimension)
            }
            return await Task.detached(priority: .background) {
                guard let data = CoverStore.loadData(for: uuid),
                      let decoded = ImageTranscoder.decodedImage(from: data, maxPixel: maxPixel) else {
                    return nil
                }
                return NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
            }.value
        }
    }
}
