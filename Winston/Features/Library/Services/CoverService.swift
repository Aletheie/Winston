import Foundation
import SwiftData
import AppKit

@MainActor
@Observable
final class CoverService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Custom covers

    func setCustomCover(for book: Book, from url: URL) {
        let uuid = book.uuid
        let fileURL = book.fileURL
        Task {
            let image: NSImage? = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
            guard let image else { return }
            CoverStore.save(image, for: uuid)
            await CoverCache.shared.replace(image, for: fileURL)
            book.coverVersion += 1
            modelContext.saveQuietly()
        }
    }

    func resetCover(for book: Book) {
        let uuid = book.uuid
        let fileURL = book.fileURL
        CoverStore.delete(for: uuid)
        Task {
            let image: NSImage? = await Task.detached(priority: .userInitiated) {
                CoverExtractor.extractCover(from: fileURL)
            }.value
            if let image { CoverStore.save(image, for: uuid) }
            await CoverCache.shared.replace(image, for: fileURL)
            book.coverVersion += 1
            modelContext.saveQuietly()
        }
    }

}
