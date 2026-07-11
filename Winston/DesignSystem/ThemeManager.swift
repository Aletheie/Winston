import SwiftUI
import AppKit
import Observation

enum AppTheme: String, CaseIterable, Identifiable {
    case purple
    case white
    case black

    var id: Self { self }

    var theme: Theme {
        switch self {
        case .purple: .purple
        case .white:  .white
        case .black:  .black
        }
    }

    var displayName: String {
        switch self {
        case .purple: String(localized: "Purple (Retro)", comment: "Theme name")
        case .white:  String(localized: "White", comment: "Theme name")
        case .black:  String(localized: "Black", comment: "Theme name")
        }
    }
}

@MainActor
@Observable
final class ThemeManager {
    private static let defaultsKey = "appTheme"
    private static let fontFamilyDefaultsKey = "appFontFamily"

    var selection: AppTheme {
        didSet { UserDefaults.standard.set(selection.rawValue, forKey: Self.defaultsKey) }
    }

    var fontFamily: String? {
        didSet { UserDefaults.standard.set(fontFamily, forKey: Self.fontFamilyDefaultsKey) }
    }

    var theme: Theme {
        var theme = selection.theme
        theme.fontFamily = fontFamily
        return theme
    }

    var defaultFont: Font? {
        fontFamily.map { .custom($0, size: NSFont.systemFontSize) }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        selection = stored.flatMap(AppTheme.init(rawValue:)) ?? .purple
        fontFamily = UserDefaults.standard.string(forKey: Self.fontFamilyDefaultsKey)
    }

    func cycle() {
        let all = AppTheme.allCases
        let next = (all.firstIndex(of: selection)! + 1) % all.count
        selection = all[next]
    }
}
