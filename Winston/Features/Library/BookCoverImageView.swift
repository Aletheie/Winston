import SwiftUI
import SwiftData

struct BookCoverImageView: View {
    let book: Book
    var tier: CoverCache.Tier = .display

    @Environment(\.theme) private var theme
    @State private var coverImage: NSImage?

    var body: some View {
        let accents = theme.coverAccents(for: book)
        let coverReference = book.coverReference
        let primaryAsset = book.primaryAsset
        let sourceURL = book.fileURL
        let derivedKey = DerivedCoverKey(
            assetID: primaryAsset?.uuid ?? book.uuid,
            contentHash: primaryAsset?.contentHash,
            fileName: primaryAsset?.fileName ?? book.fileName,
            sizeBytes: primaryAsset?.sizeBytes ?? book.fileSizeBytes,
            maxPixel: Int(tier.maxDimension)
        )
        Color.clear
            .overlay {
                if let image = coverImage {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    BookCoverArt(accent1: accents.primary, accent2: accents.secondary)
                }
            }
            .clipped()
            .task(
                id: "\(coverReference.owner.scope.rawValue)#\(coverReference.owner.id)#\(book.fileName)#\(coverReference.version)"
            ) {
                coverImage = nil
                let resolved = await resolvedCover(
                    sourceURL: sourceURL,
                    cacheURL: book.coverCacheURL,
                    reference: coverReference,
                    derivedKey: derivedKey
                )
                guard !Task.isCancelled else { return }
                coverImage = resolved
            }
    }

    private func resolvedCover(
        sourceURL: URL?,
        cacheURL: URL,
        reference: CoverReference,
        derivedKey: DerivedCoverKey
    ) async -> NSImage? {
        let maxDimension = tier.maxDimension
        let maxPixel = Int(maxDimension)
        let lease = await CoverCache.shared.lease(for: cacheURL, tier: tier) {
            if let stored = await CoverWorkScheduler.shared.storedCover(
                for: reference.owner,
                maxPixel: maxPixel
            ) {
                return stored
            }
            // Merely displaying an edition must never create or replace a
            // shared work/asset cover as a side effect.
            guard reference.owner.scope == .edition else { return nil }
            guard let sourceURL else { return nil }
            guard !Task.isCancelled else { return nil }

            if let derived = await CoverWorkScheduler.shared.storedDerivedCover(
                for: derivedKey,
                maxPixel: maxPixel
            ) {
                return derived
            }
            guard let prepared = await CoverWorkScheduler.shared.extractAndEncode(
                from: sourceURL,
                maxDimension: maxDimension
            ), !Task.isCancelled else { return nil }
            if await CoverWorkScheduler.shared.installDerived(
                prepared.data,
                for: derivedKey
            ) {
                return prepared.image
            }
            guard !Task.isCancelled else { return nil }
            return await CoverWorkScheduler.shared.storedDerivedCover(
                for: derivedKey,
                maxPixel: maxPixel
            )
        }
        return await lease.image()
    }
}
