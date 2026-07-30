import Foundation
import Testing
@testable import Winston

@Suite("Localization boundaries")
struct LocalizationBoundaryTests {
    private let czech = Locale(identifier: "cs")
    private let english = Locale(identifier: "en")

    @Test
    func localizationUsesTheApplicationResourceBundle() {
        #expect(
            WinstonLocalization.bundle.bundleIdentifier
                == "cz.annajung.Winston"
        )
        #expect(WinstonLocalization.bundle.localizations.contains("cs"))
    }

    @Test @MainActor
    func nativeMetadataLabelsResolveInCzech() {
        let expected: [DetailMetadataField: String] = [
            .format: "Formát",
            .copy: "Kopie",
            .shelf: "Police",
            .size: "Velikost",
            .pages: "Strany",
            .publisher: "Vydavatel",
            .year: "Rok",
            .language: "Jazyk",
            .translator: "Překlad",
            .edition: "Vydání",
            .isbn: "ISBN",
            .series: "Série",
            .tags: "Štítky",
        ]

        for field in DetailMetadataField.allCases {
            #expect(field.localizedLabel(locale: czech) == expected[field])
        }
    }

    @Test @MainActor
    func terminalMetadataLabelsRemainVerbatim() {
        let expected = [
            "FORMAT", "KOPIE", "POLICE", "SIZE", "PAGES", "PUB", "YEAR",
            "LANG", "PREKLAD", "VYDANI", "ISBN", "SERIES", "TAGS",
        ]

        #expect(DetailMetadataField.allCases.map(\.terminalLabel) == expected)
    }

    @Test
    func everyDeviceErrorResolvesInEnglishAndCzech() {
        let cases: [(DeviceError, String, String)] = [
            (.notConnected, "No device connected", "Není připojeno žádné zařízení"),
            (.openFailed, "Could not open the device", "Zařízení se nepodařilo otevřít"),
            (
                .listFailed,
                "Could not read the device contents",
                "Obsah zařízení se nepodařilo načíst"
            ),
            (
                .transferFailed(code: -17),
                "Transfer failed (error -17)",
                "Přenos selhal (chyba -17)"
            ),
            (
                .deleteFailed(code: 42),
                "Delete failed (error 42)",
                "Smazání selhalo (chyba 42)"
            ),
            (.fileMissing, "The file no longer exists", "Soubor již neexistuje"),
            (
                .invalidFileName,
                "The destination file name is invalid",
                "Název cílového souboru je neplatný"
            ),
            (
                .unsafePath,
                "The device path violates the mounted-volume boundary",
                "Cesta v zařízení překračuje hranici připojeného svazku"
            ),
        ]

        for (error, expectedEnglish, expectedCzech) in cases {
            #expect(error.localizedDescription(locale: english) == expectedEnglish)
            #expect(error.localizedDescription(locale: czech) == expectedCzech)
        }
    }

    @Test
    func newRecoveryAndOperationMessagesResolveInCzech() {
        #expect(
            String(
                localized: "Couldn’t eject the Kindle. \("E42")",
                bundle: WinstonLocalization.bundle(for: czech),
                locale: czech
            ) == "Kindle se nepodařilo vysunout. E42"
        )
        #expect(
            String(
                localized: "A Kindle transfer needs review before it can be retried.",
                bundle: WinstonLocalization.bundle(for: czech),
                locale: czech
            ) == "Přenos do Kindlu vyžaduje kontrolu, než jej bude možné zopakovat."
        )
        #expect(
            String(
                localized: "The recovery journal could not be decoded.",
                bundle: WinstonLocalization.bundle(for: czech),
                locale: czech
            ) == "Žurnál obnovení se nepodařilo dekódovat."
        )
        #expect(
            String(
                localized: "Library data may be out of date.",
                bundle: WinstonLocalization.bundle(for: czech),
                locale: czech
            ) == "Data knihovny možná nejsou aktuální."
        )
        #expect(
            String(
                localized: "Exported \(2) files and \(1) metadata-only entries.",
                bundle: WinstonLocalization.bundle(for: czech),
                locale: czech
            ) == "Exportováno souborů: 2; položek pouze s metadaty: 1."
        )
    }

    @Test
    func czechPluralCategoriesResolveForReleaseCounts() {
        #expect(
            String(
                localized: "Found \(1) new releases.",
                bundle: WinstonLocalization.bundle(for: czech),
                locale: czech
            )
                == "Nalezena 1 nová kniha."
        )
        #expect(
            String(
                localized: "Found \(3) new releases.",
                bundle: WinstonLocalization.bundle(for: czech),
                locale: czech
            )
                == "Nalezeny 3 nové knihy."
        )
        #expect(
            String(
                localized: "Found \(0) new releases.",
                bundle: WinstonLocalization.bundle(for: czech),
                locale: czech
            )
                == "Nalezeno 0 nových knih."
        )
        #expect(
            String(
                localized: "Found \(12) new releases.",
                bundle: WinstonLocalization.bundle(for: czech),
                locale: czech
            )
                == "Nalezeno 12 nových knih."
        )
    }
}
