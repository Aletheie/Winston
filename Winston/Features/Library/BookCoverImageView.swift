import SwiftUI
import SwiftData

private nonisolated struct BookCoverRequest: Hashable, Sendable {
    let reference: CoverReference
    let sourceURL: URL?
    let derivedKey: DerivedCoverKey
}

struct BookCoverImageView: View {
    let book: Book
    var tier: CoverCache.Tier = .display

    @Environment(\.theme) private var theme
    @State private var coverImage: NSImage?

    var body: some View {
        let accents = theme.coverAccents(for: book)
        let coverReference = book.coverReference
        let primaryAsset = book.primaryAsset
        let fileName = primaryAsset?.fileName ?? book.fileName
        let request = BookCoverRequest(
            reference: coverReference,
            sourceURL: BookFileStore.catalogURL(for: fileName),
            derivedKey: DerivedCoverKey(
                assetID: primaryAsset?.uuid ?? book.uuid,
                contentHash: primaryAsset?.contentHash,
                fileName: fileName,
                sizeBytes: primaryAsset?.sizeBytes ?? book.fileSizeBytes,
                maxPixel: Int(tier.maxDimension)
            )
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
            .task(id: request) {
                coverImage = nil
                let resolved = await resolvedCover(
                    sourceURL: request.sourceURL,
                    reference: request.reference,
                    derivedKey: request.derivedKey
                )
                guard !Task.isCancelled else { return }
                coverImage = resolved
            }
            .onDisappear {
                // Lazy containers preserve state for offscreen rows. Keeping
                // their bitmaps here would bypass the byte-limited cache.
                coverImage = nil
            }
    }

    private func resolvedCover(
        sourceURL: URL?,
        reference: CoverReference,
        derivedKey: DerivedCoverKey
    ) async -> NSImage? {
        let maxDimension = tier.maxDimension
        let maxPixel = Int(maxDimension)
        let revision = CoverCache.Revision(
            version: reference.version,
            derivedKey: reference.owner.scope == .edition ? derivedKey : nil
        )
        let lease = await CoverCache.shared.lease(
            for: CoverStore.url(for: reference.owner), tier: tier, revision: revision
        ) {
            if let stored = await CoverWorkScheduler.shared.storedCover(
                for: reference.owner,
                maxPixel: maxPixel
            ) {
                return stored
            }
            // Merely displaying an edition must never create or replace a
            // shared work/asset cover as a side effect.
            guard reference.owner.scope == .edition else { return nil }
            guard let sourceURL, !Task.isCancelled else { return nil }

            if let derived = await CoverWorkScheduler.shared.storedDerivedCover(
                for: derivedKey,
                maxPixel: maxPixel
            ) {
                return derived
            }
            guard let prepared = await CoverWorkScheduler.shared.extractAndEncode(
                from: sourceURL,
                maxDimension: maxDimension,
                validatingManagedDirectory: sourceURL.deletingLastPathComponent()
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
