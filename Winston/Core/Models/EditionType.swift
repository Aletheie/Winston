import Foundation

nonisolated enum EditionType: String, CaseIterable, Codable, Sendable, Identifiable {
    case standard
    case translation
    case revised
    case illustrated
    case abridged
    case other

    var id: Self { self }

    var label: String {
        switch self {
        case .standard: String(localized: "Standard edition")
        case .translation: String(localized: "Translation")
        case .revised: String(localized: "Revised edition")
        case .illustrated: String(localized: "Illustrated edition")
        case .abridged: String(localized: "Abridged edition")
        case .other: String(localized: "Other edition")
        }
    }
}
