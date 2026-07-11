import Foundation

struct SourceDocument: Sendable {
    struct Image: Sendable {
        let ref: String
        let data: Data
    }

    let title: String
    let metadata: BookMetadata
    let sections: [String]
    let images: [Image]
    let coverImage: Data?
}

extension String {
    nonisolated var nonEmpty: String? { isEmpty ? nil : self }

    nonisolated var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
