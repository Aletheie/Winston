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
            await Task.detached(priority: .background) {
                if let data = CoverStore.loadData(for: uuid),
                   let decoded = ImageTranscoder.decodedImage(from: data, maxPixel: maxPixel) {
                    return NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                }
                guard let extracted = CoverExtractor.extractCover(from: url) else { return nil }
                CoverStore.save(extracted, for: uuid)
                return CoverCache.downscaled(extracted, maxDimension: maxDimension)
            }.value
        }
    }
}
