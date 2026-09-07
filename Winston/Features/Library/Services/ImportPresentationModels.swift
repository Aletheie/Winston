import Foundation

nonisolated struct CatalogImportContext: Sendable, Equatable, Hashable {
    let catalogID: String
    let catalogName: String
    let publicationID: String
    let publicationTitle: String
    let publicationAuthors: [String]
    let publicationLanguage: String?
    let sourceURL: URL
    let attribution: String?
    let contributors: [String]
    let selectedFormat: String
    let acquisitionRelation: OPDSAcquisitionRelation
}

nonisolated struct ImportFailurePresentation: Sendable, Equatable {
    let title: String
    let sourcePath: String?
    let reason: String
    let detail: String
    let systemImage: String

    init(failure: ImportFailure) {
        title = failure.sourceURL?.lastPathComponent
            ?? String(localized: "Unknown import source")
        sourcePath = failure.sourceURL?.path(percentEncoded: false)
        reason = failure.reason.localizedLabel
        detail = failure.detail
        systemImage = failure.reason.systemImage
    }
}

extension ImportFailureReason {
    nonisolated var systemImage: String {
        switch self {
        case .unsupportedFormat: "doc.badge.ellipsis"
        case .unreadableSource: "doc.badge.xmark"
        case .staging: "square.and.arrow.down.badge.xmark"
        case .validation: "checkmark.seal.text.page"
        case .catalog: "books.vertical.circle"
        case .recoveryDeferred: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }
}
