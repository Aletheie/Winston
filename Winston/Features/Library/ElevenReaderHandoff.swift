import AppKit

/// ElevenReader has no public import API, so Winston hands the file to the
/// user through the ElevenReader web library or AirDrop and uploads nothing.
@MainActor
enum ElevenReaderHandoff {
    nonisolated enum Destination: Equatable, Sendable {
        case web
        case airDrop
    }

    nonisolated enum Unavailability: Equatable, Sendable {
        case noDigitalFile
        case drmProtected
        case unsupportedFormat
    }

    nonisolated struct Candidate: Equatable, Sendable {
        let fileName: String
        let format: String
        let isPrimary: Bool
        let drmProtected: Bool
        let dateAdded: Date
    }

    nonisolated static let libraryURL = URL(string: "https://elevenreader.io/reader/library")!

    nonisolated static let supportedFormats = ["epub", "pdf", "docx", "html", "htm", "txt"]

    static func file(for book: Book) -> Candidate? {
        best(of: candidates(for: book))
    }

    static func unavailability(for book: Book) -> Unavailability? {
        unavailability(among: candidates(for: book))
    }

    nonisolated static func best(of candidates: [Candidate]) -> Candidate? {
        candidates
            .filter { !$0.drmProtected && supportedFormats.contains($0.format) }
            .min { lhs, rhs in
                let lhsRank = rank(of: lhs)
                let rhsRank = rank(of: rhs)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.dateAdded < rhs.dateAdded
            }
    }

    nonisolated static func unavailability(among candidates: [Candidate]) -> Unavailability? {
        guard best(of: candidates) == nil else { return nil }
        if candidates.isEmpty { return .noDigitalFile }
        if candidates.contains(where: { supportedFormats.contains($0.format) }) {
            return .drmProtected
        }
        return .unsupportedFormat
    }

    static func unavailabilityReason(_ reason: Unavailability) -> String {
        switch reason {
        case .noDigitalFile:
            String(localized: "This book has no available digital file.")
        case .drmProtected:
            String(localized: "ElevenReader cannot import DRM-protected files.")
        case .unsupportedFormat:
            String(localized: "ElevenReader imports EPUB, PDF, DOCX, HTML, and TXT files. Convert this book to EPUB first.")
        }
    }

    static func send(_ book: Book, to destination: Destination, toasts: ToastCenter) {
        guard let candidate = file(for: book),
              let url = BookFileStore.validatedURL(for: candidate.fileName),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            let reason = unavailability(for: book) ?? .noDigitalFile
            if reason == .noDigitalFile {
                LibraryExternalActions.postUnavailableFile(for: book, toasts: toasts)
            } else {
                toasts.error(unavailabilityReason(reason))
            }
            return
        }
        switch destination {
        case .web:
            NSWorkspace.shared.activateFileViewerSelecting([url])
            NSWorkspace.shared.open(libraryURL)
            toasts.info(String(
                localized: "Drag “\(url.lastPathComponent)” from Finder into your ElevenReader library."
            ))
        case .airDrop:
            if let service = NSSharingService(named: .sendViaAirDrop),
               service.canPerform(withItems: [url]) {
                service.perform(withItems: [url])
            } else {
                LibraryExternalActions.share(url)
            }
        }
    }

    private static func candidates(for book: Book) -> [Candidate] {
        let primaryID = book.primaryAsset?.uuid
        if book.assets.isEmpty {
            guard book.hasCatalogDigitalFile else { return [] }
            return [Candidate(
                fileName: book.fileName,
                format: book.format.lowercased(),
                isPrimary: true,
                drmProtected: book.primaryDRMProtected == true,
                dateAdded: book.dateAdded
            )]
        }
        return book.assets.filter(\.isUsable).map { asset in
            let isPrimary = asset.uuid == primaryID
            return Candidate(
                fileName: asset.fileName,
                format: asset.format.lowercased(),
                isPrimary: isPrimary,
                drmProtected: asset.drmProtected
                    ?? (isPrimary ? book.primaryDRMProtected : nil)
                    ?? false,
                dateAdded: asset.dateAdded
            )
        }
    }

    nonisolated private static func rank(of candidate: Candidate) -> Int {
        let formatRank = supportedFormats.firstIndex(of: candidate.format) ?? supportedFormats.count
        return formatRank * 2 + (candidate.isPrimary ? 0 : 1)
    }
}
