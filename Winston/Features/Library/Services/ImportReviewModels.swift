import Foundation

nonisolated struct CatalogImportContext:
    Sendable,
    Equatable,
    Hashable
{
    let catalogID: String
    let catalogName: String
    let publicationID: String
    let publicationTitle: String
    let publicationAuthors: [String]
    let publicationLanguage: String?
    let selectedFormat: String
    let acquisitionRelation: OPDSAcquisitionRelation
}

nonisolated struct CatalogMetadataDifference:
    Sendable,
    Equatable,
    Hashable,
    Identifiable
{
    let field: String
    let catalogValue: String
    let extractedValue: String?

    var id: String { field }
}

nonisolated enum ImportReviewPhase: Sendable, Equatable {
    case preparing
    case ready
    case committing
    case completed(ImportSummary)
    case failed(String)
}

nonisolated enum ImportReviewAction: Sendable, Equatable, Hashable {
    case skip
    case createNewWork
    case createEdition(workID: UUID)
    case addFormat(bookID: UUID, workID: UUID?)

    var importsFile: Bool {
        self != .skip
    }
}

nonisolated struct ImportReviewEditionTarget: Sendable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let detail: String?
    let workID: UUID?
}

nonisolated struct ImportReviewWorkTarget: Sendable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let detail: String?
    let editions: [ImportReviewEditionTarget]
}

nonisolated struct PreparedImportItem: Sendable, Equatable, Identifiable {
    let id: UUID
    let sourceURL: URL
    let sourceName: String
    let format: String
    let sizeBytes: Int64
    let sha256: String?
    let drmProtected: Bool
    let validation: AssetValidation?
    let coverPreviewJPEGData: Data?
    var metadata: BookMetadata
    let proposedAction: ImportReviewAction
    var action: ImportReviewAction
    var isSelected: Bool
    let isSelectable: Bool
    let reasons: [String]
    let warnings: [String]
    let workTargets: [ImportReviewWorkTarget]
    let catalogContext: CatalogImportContext?
    let catalogMetadataDifferences: [CatalogMetadataDifference]

    var willImport: Bool {
        isSelectable && isSelected && action.importsFile
    }

    var requiresDecision: Bool {
        isSelectable && proposedAction == .skip && !reasons.isEmpty
            && workTargets.count > 1
    }
}

nonisolated struct PreparedImportBatch: Sendable, Equatable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let requestedCount: Int
    var phase: ImportReviewPhase
    var items: [PreparedImportItem]
    var completedPreparationCount: Int

    var selectedCount: Int {
        items.count(where: \.willImport)
    }

    var blockedCount: Int {
        items.count { !$0.isSelectable }
    }

    var reviewCount: Int {
        items.count(where: \.requiresDecision)
    }

    var canCommit: Bool {
        phase == .ready && selectedCount > 0
    }
}

nonisolated enum ImportSummaryPresentationStyle: Sendable, Equatable {
    case success
    case info
    case error
}

nonisolated struct ImportSummaryPresentation: Sendable, Equatable {
    let message: String
    let style: ImportSummaryPresentationStyle
    let showsReviewAction: Bool

    init(summary: ImportSummary) {
        if summary.hasIssues {
            message = String(
                localized: "Imported \(summary.importedItemCount) of \(summary.requestedCount) · skipped \(summary.skippedCount) · failed \(summary.failedCount) · cancelled \(summary.cancelledCount) · recovery \(summary.recoveryDeferredCount)."
            )
        } else if summary.skippedCount > 0 {
            message = String(
                localized: "Imported \(summary.importedItemCount) of \(summary.requestedCount) · skipped \(summary.skippedCount)."
            )
        } else {
            message = String(
                localized: "Imported \(summary.importedItemCount) of \(summary.requestedCount)."
            )
        }
        if summary.failedCount > 0, summary.importedItemCount == 0 {
            style = .error
        } else if summary.hasIssues {
            style = .info
        } else {
            style = .success
        }
        showsReviewAction = summary.hasIssues
    }
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
