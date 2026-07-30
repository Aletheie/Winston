import Foundation

extension String {
    nonisolated var normalizedMatchKey: String {
        MetadataNormalizer.comparisonKey(self)
    }
}

nonisolated struct BookMatchKey: Hashable, Sendable {
    let title: String
    let author: String

    init(title: String, author: String?) {
        self.title = title.normalizedMatchKey
        self.author = (author ?? "").normalizedMatchKey
    }

    var isComplete: Bool { !title.isEmpty && !author.isEmpty }

    var storageValue: String { "\(title)|\(author)" }
}
