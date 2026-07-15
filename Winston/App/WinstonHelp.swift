import AppKit
import Carbon
import OSLog

@MainActor
enum WinstonHelp {
    private static let bookName = "cz.annajung.Winston.helpbook"
    private static let logger = Logger(subsystem: "cz.annajung.Winston", category: "Help")

    static func open(for language: AppLanguage) {
        let registrationStatus = AHRegisterHelpBookWithURL(Bundle.main.bundleURL as CFURL)
        guard registrationStatus == noErr else {
            logger.error("Help Book registration failed with status \(registrationStatus)")
            NSApplication.shared.showHelp(nil)
            return
        }

        let localization = localizationCode(
            for: language,
            preferredLocalizations: Bundle.main.preferredLocalizations
        )
        let pagePath = "\(localization).lproj/index.html"
        let openStatus = AHGotoPage(bookName as CFString, pagePath as CFString, nil)
        guard openStatus != noErr else { return }

        logger.error("Opening localized Help Book page failed with status \(openStatus)")
        NSApplication.shared.showHelp(nil)
    }

    nonisolated static func localizationCode(
        for language: AppLanguage,
        preferredLocalizations: [String]
    ) -> String {
        switch language {
        case .czech:
            "cs"
        case .english:
            "en"
        case .system:
            preferredLocalizations.contains { $0.lowercased().hasPrefix("cs") } ? "cs" : "en"
        }
    }
}
