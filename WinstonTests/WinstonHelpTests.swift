import Testing
@testable import Winston

@Suite
struct WinstonHelpTests {
    @Test
    func explicitLanguageWinsOverPreferredLocalizations() {
        #expect(
            WinstonHelp.localizationCode(
                for: .czech,
                preferredLocalizations: ["en"]
            ) == "cs"
        )
        #expect(
            WinstonHelp.localizationCode(
                for: .english,
                preferredLocalizations: ["cs"]
            ) == "en"
        )
    }

    @Test
    func systemLanguageRecognizesCzechRegionalLocalization() {
        #expect(
            WinstonHelp.localizationCode(
                for: .system,
                preferredLocalizations: ["cs-CZ", "en"]
            ) == "cs"
        )
    }

    @Test
    func systemLanguageFallsBackToEnglish() {
        #expect(
            WinstonHelp.localizationCode(
                for: .system,
                preferredLocalizations: ["de", "en"]
            ) == "en"
        )
    }
}
