import Foundation

extension String {
    nonisolated var normalizedMatchKey: String {
        folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
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
