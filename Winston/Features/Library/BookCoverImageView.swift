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
            .task(id: "\(book.uuid)#\(book.fileName)#\(book.coverVersion)") {
                coverImage = nil
                let resolved = await resolvedCover(for: book.coverCacheURL, uuid: book.uuid)
                guard !Task.isCancelled else { return }
                coverImage = resolved
            }
    }

    private func resolvedCover(for url: URL, uuid: UUID) async -> NSImage? {
        let maxDimension = tier.maxDimension
        let maxPixel = Int(maxDimension)
        let lease = await CoverCache.shared.lease(for: url, tier: tier) {
            if let stored = await CoverWorkScheduler.shared.storedCover(
                for: uuid,
                maxPixel: maxPixel
            ) {
                return stored
            }
            guard !Task.isCancelled else { return nil }

            let token = await CoverRepository.shared.beginBackgroundMutation(for: uuid)
            guard let prepared = await CoverWorkScheduler.shared.extractAndEncode(
                from: url,
                maxDimension: maxDimension
            ), !Task.isCancelled else { return nil }
            if await CoverWorkScheduler.shared.install(prepared.data, using: token) {
                return prepared.image
            }
            guard !Task.isCancelled else { return nil }
            return await CoverWorkScheduler.shared.storedCover(
                for: uuid,
                maxPixel: maxPixel
            )
        }
        return await lease.image()
    }
}
