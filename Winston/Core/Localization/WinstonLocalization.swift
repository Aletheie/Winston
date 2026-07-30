import Foundation

private nonisolated final class WinstonLocalizationBundleToken: NSObject {}

nonisolated enum WinstonLocalization {
    static let bundle: Bundle = {
        let codeBundle = Bundle(for: WinstonLocalizationBundleToken.self)
        if containsCatalog(codeBundle) {
            return codeBundle
        }

        var candidateURL = codeBundle.bundleURL
        while candidateURL.pathExtension != "app",
              candidateURL.path != "/" {
            candidateURL.deleteLastPathComponent()
        }
        if let appBundle = Bundle(url: candidateURL),
           containsCatalog(appBundle) {
            return appBundle
        }
        return .main
    }()

    private static func containsCatalog(_ bundle: Bundle) -> Bool {
        bundle.path(
            forResource: "Localizable",
            ofType: "strings",
            inDirectory: nil,
            forLocalization: "cs"
        ) != nil
    }

    static func bundle(for locale: Locale) -> Bundle {
        let language = locale.language.languageCode?.identifier
            ?? locale.identifier.split(separator: "_").first.map(String.init)
            ?? locale.identifier
        guard let path = bundle.path(
            forResource: language,
            ofType: "lproj"
        ), let localizedBundle = Bundle(path: path) else {
            return bundle
        }
        return localizedBundle
    }
}
