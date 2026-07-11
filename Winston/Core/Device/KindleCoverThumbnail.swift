import Foundation

nonisolated enum KindleCoverThumbnail {
    struct Prepared: Sendable {
        let fileURL: URL
        let name: String
    }

    static func prepare(sentFile: URL, coverSourceUUID uuid: UUID) -> Prepared? {
        let ids = MOBIIdentifiers.read(from: sentFile)
        guard let asin = ids.asin else { return nil }
        let cdeType = ids.cdeType ?? "EBOK"

        guard let cover = CoverStore.load(for: uuid) ?? CoverExtractor.extractCover(from: sentFile),
              let fileURL = CoverStore.makeThumbnailFile(from: cover) else { return nil }

        // The device shows this sidecar as the home-screen thumbnail; the name must carry the file's ASIN.
        return Prepared(fileURL: fileURL, name: "thumbnail_\(asin)_\(cdeType)_portrait.jpg")
    }
}
