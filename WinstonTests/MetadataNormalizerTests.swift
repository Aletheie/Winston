import Foundation
import Testing
@testable import Winston

@Suite("Metadata normalizer")
struct MetadataNormalizerTests {
    @Test(arguments: [
        ("en", "en"),
        ("eng", "en"),
        ("EN", "en"),
        ("English", "en"),
        ("angličtina", "en"),
        ("cze", "cs"),
        ("ces", "cs"),
        ("Čeština", "cs"),
    ])
    func languageAliasesPreferTwoLetterBase(
        _ raw: String,
        _ expected: String
    ) {
        let value = MetadataNormalizer.language(raw)

        #expect(value.canonicalTag == expected)
        #expect(value.baseLanguageCode == expected)
        #expect(value.status == .recognized)
    }

    @Test func bcp47PreservesRegionScriptAndVariantsWithCanonicalCasing() {
        let regional = MetadataNormalizer.language(" en_us ")
        let scripted = MetadataNormalizer.language("sr_latn_rs")
        let variant = MetadataNormalizer.language("sl-ROZAJ-biske")

        #expect(regional.canonicalTag == "en-US")
        #expect(regional.baseLanguageCode == "en")
        #expect(regional.regionCode == "US")
        #expect(scripted.canonicalTag == "sr-Latn-RS")
        #expect(scripted.scriptCode == "Latn")
        #expect(scripted.regionCode == "RS")
        #expect(variant.canonicalTag == "sl-rozaj-biske")
        #expect(variant.variants == ["rozaj", "biske"])
    }

    @Test func registeredISO639ThreeCodeAndGrandfatheredTagAreRecognized() {
        let rare = MetadataNormalizer.language("aaa")
        let grandfathered = MetadataNormalizer.language("i-klingon")

        #expect(rare.canonicalTag == "aaa")
        #expect(rare.status == .recognized)
        #expect(grandfathered.canonicalTag == "tlh")
        #expect(grandfathered.status == .recognized)
    }

    @Test func specialPrivateMalformedAndAmbiguousValuesRemainDistinct() {
        #expect(MetadataNormalizer.language("und").status == .special)
        #expect(MetadataNormalizer.language("mul").status == .special)
        #expect(MetadataNormalizer.language("zxx").status == .special)
        #expect(MetadataNormalizer.language("x-winston-test").status == .privateUse)
        #expect(MetadataNormalizer.language("qaa").status == .privateUse)

        let unknown = MetadataNormalizer.language("  zzq  ")
        let ambiguous = MetadataNormalizer.language("en, cs")

        #expect(unknown.status == .unrecognized)
        #expect(unknown.rawValue == "  zzq  ")
        #expect(unknown.normalizedRawValue == "zzq")
        #expect(unknown.groupIdentifier == "status:unrecognized")
        #expect(
            unknown.localizedGroupName(displayLocaleIdentifier: "en")
                == "Unrecognized"
        )
        #expect(
            unknown.localizedGroupName(displayLocaleIdentifier: "cs")
                == "Nerozpoznáno"
        )
        #expect(ambiguous.status == .unrecognized)
        #expect(ambiguous.normalizedRawValue == "en, cs")
    }

    @Test func localizedLanguageNamesAndStatusesSupportEnglishAndCzech() {
        let language = MetadataNormalizer.language("en-GB")
        let english = language.localizedDisplayName(
            displayLocaleIdentifier: "en"
        )
        let czech = language.localizedDisplayName(
            displayLocaleIdentifier: "cs"
        )

        #expect(english.lowercased().contains("english"))
        #expect(english.contains("United Kingdom"))
        #expect(czech.lowercased().contains("angličtina"))
        #expect(czech.contains("Spojené království"))
        #expect(
            MetadataLanguageNormalizationStatus.unrecognized
                .localizedName(displayLocaleIdentifier: "en")
                == "Unrecognized"
        )
        #expect(
            MetadataLanguageNormalizationStatus.unrecognized
                .localizedName(displayLocaleIdentifier: "cs")
                == "Nerozpoznáno"
        )
    }

    @Test func baseLanguageQueriesGroupRegionsWhileRegionalQueriesAreExact() {
        #expect(MetadataNormalizer.languageMatches(actual: "en-US", operand: "en"))
        #expect(MetadataNormalizer.languageMatches(actual: "en-GB", operand: "eng"))
        #expect(MetadataNormalizer.languageMatches(actual: "English", operand: "English"))
        #expect(MetadataNormalizer.languageMatches(actual: "en-GB", operand: "en-GB"))
        #expect(!MetadataNormalizer.languageMatches(actual: "en-US", operand: "en-GB"))
        #expect(MetadataNormalizer.languageMatches(actual: "zzq", operand: "zzq"))
        #expect(!MetadataNormalizer.languageMatches(actual: "ZZQ", operand: "other"))
    }

    @Test func comparisonKeysCollapseUnicodeWhitespaceWithoutDiscardingCredits() {
        let decomposed = "  Jose\u{301}\u{00a0}\u{00a0}L.  Guin "
        let composed = "josé L. Guin"

        #expect(
            MetadataNormalizer.comparisonKey(decomposed)
                == MetadataNormalizer.comparisonKey(composed)
        )
        #expect(
            MetadataNormalizer.comparisonKey("José L. Guin")
                != MetadataNormalizer.comparisonKey("Jose L Guin")
        )
        #expect(
            MetadataNormalizer.comparisonKey("A. Writer & B. Writer")
                != MetadataNormalizer.comparisonKey("B. Writer & A. Writer")
        )
    }

    @Test func isbnValidationPreservesRawAndConvertsISBN10ForComparison() {
        let isbn10 = MetadataNormalizer.isbn(" ISBN-10: 0-306-40615-2 ")
        let isbn13 = MetadataNormalizer.isbn("978-0-306-40615-7")

        #expect(isbn10.rawValue == " ISBN-10: 0-306-40615-2 ")
        #expect(isbn10.parsedValue == "0306406152")
        #expect(isbn10.canonicalISBN13 == "9780306406157")
        #expect(isbn10.status == .valid)
        #expect(isbn13.canonicalISBN13 == isbn10.canonicalISBN13)
    }

    @Test func invalidISBNIsRetainedAndNeverProducesAComparisonKey() {
        let invalid = MetadataNormalizer.isbn("ISBN 978-0-306-40615-8")

        #expect(invalid.rawValue == "ISBN 978-0-306-40615-8")
        #expect(invalid.status == .invalid)
        #expect(invalid.canonicalISBN13 == nil)
        #expect(MetadataNormalizer.isbn("   ").status == .missing)
    }

    @Test func onlyHTMAndHTMLAliasDuringFormatFiltering() {
        #expect(MetadataNormalizer.formatFilterKey("HTM") == "html")
        #expect(MetadataNormalizer.formatFilterKey("html") == "html")
        #expect(MetadataNormalizer.formatFilterKey("MOBI") == "mobi")
        #expect(MetadataNormalizer.formatFilterKey("AZW") == "azw")
        #expect(MetadataNormalizer.formatFilterKey("AZW3") == "azw3")
        #expect(MetadataNormalizer.formatFilterKey("MOBI") != MetadataNormalizer.formatFilterKey("AZW"))
        #expect(MetadataNormalizer.formatFilterKey("AZW") != MetadataNormalizer.formatFilterKey("AZW3"))
    }
}
