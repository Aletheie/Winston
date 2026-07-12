import Foundation
import QuickLookUI
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    enum PreviewError: Error {
        case coverUnavailable
        case unsupportedImageType
    }

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let fileURL = request.fileURL
        guard let payload = await Task.detached(priority: .userInitiated, operation: {
            KindleQuickLookPreview.payload(for: fileURL)
        }).value else {
            throw PreviewError.coverUnavailable
        }
        guard let contentType = UTType(payload.contentTypeIdentifier) else {
            throw PreviewError.unsupportedImageType
        }

        let imageData = payload.imageData
        let reply = QLPreviewReply(
            dataOfContentType: contentType,
            contentSize: CGSize(width: payload.pixelWidth, height: payload.pixelHeight)
        ) { _ in
            imageData
        }
        reply.title = payload.title
        return reply
    }
}
