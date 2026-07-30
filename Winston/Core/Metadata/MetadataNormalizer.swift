import Foundation

nonisolated enum MetadataLanguageNormalizationStatus: String, Codable, Hashable, Sendable {
    case recognized
    case special
    case privateUse
    case unrecognized

    func localizedName(displayLocaleIdentifier: String) -> String {
        let bundle = WinstonLocalization.bundle(
            for: Locale(identifier: displayLocaleIdentifier)
        )
        return switch self {
        case .recognized:
            NSLocalizedString("Recognized", bundle: bundle, comment: "Language normalization status")
        case .special:
            NSLocalizedString("Special language code", bundle: bundle, comment: "Language normalization status")
        case .privateUse:
            NSLocalizedString("Private-use language tag", bundle: bundle, comment: "Language normalization status")
        case .unrecognized:
            NSLocalizedString("Unrecognized", bundle: bundle, comment: "Language normalization status")
        }
    }
}

nonisolated struct NormalizedLanguage: Codable, Equatable, Hashable, Sendable {
    let rawValue: String
    let normalizedRawValue: String
    let canonicalTag: String?
    let baseLanguageCode: String?
    let scriptCode: String?
    let regionCode: String?
    let variants: [String]
    let status: MetadataLanguageNormalizationStatus

    var isRecognized: Bool {
        status != .unrecognized
    }

    var isBaseLanguageOnly: Bool {
        status == .recognized
            && canonicalTag == baseLanguageCode
    }

    var groupIdentifier: String {
        baseLanguageCode ?? "status:\(status.rawValue)"
    }

    func localizedGroupName(displayLocaleIdentifier: String) -> String {
        guard status == .recognized, let baseLanguageCode else {
            return status.localizedName(
                displayLocaleIdentifier: displayLocaleIdentifier
            )
        }
        return Locale(identifier: displayLocaleIdentifier)
            .localizedString(forLanguageCode: baseLanguageCode)
            ?? baseLanguageCode
    }

    func localizedDisplayName(displayLocaleIdentifier: String) -> String {
        guard let canonicalTag, let baseLanguageCode else {
            return normalizedRawValue
        }
        guard status == .recognized else {
            return canonicalTag
        }

        let locale = Locale(identifier: displayLocaleIdentifier)
        var components = [
            locale.localizedString(forLanguageCode: baseLanguageCode)
                ?? baseLanguageCode
        ]
        if let scriptCode {
            components.append(
                locale.localizedString(forScriptCode: scriptCode)
                    ?? scriptCode
            )
        }
        if let regionCode {
            components.append(
                locale.localizedString(forRegionCode: regionCode)
                    ?? regionCode
            )
        }
        let name = components.joined(separator: " · ")
        return "\(name) — \(canonicalTag)"
    }
}

nonisolated enum MetadataISBNNormalizationStatus: String, Codable, Hashable, Sendable {
    case missing
    case valid
    case invalid
}

nonisolated struct NormalizedISBN: Codable, Equatable, Hashable, Sendable {
    let rawValue: String
    let parsedValue: String?
    let canonicalISBN13: String?
    let status: MetadataISBNNormalizationStatus
}

nonisolated struct MetadataLanguageSuggestion: Identifiable, Equatable, Hashable, Sendable {
    let tag: String
    let localizedName: String

    var id: String { tag }
    var label: String { "\(localizedName) — \(tag)" }
}

/// Read-through metadata normalization. Raw catalog values remain authoritative;
/// this type only derives comparison, filtering, and presentation values.
nonisolated enum MetadataNormalizer {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")


    private static let bibliographicLanguageAliases: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya",
        "chi": "zho", "cze": "ces", "dut": "nld", "fre": "fra",
        "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl",
        "mac": "mkd", "mao": "mri", "may": "msa", "per": "fas",
        "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]

    private static let grandfatheredLanguageTags: [String: String] = [
        "art-lojban": "jbo", "cel-gaulish": "",
        "en-gb-oed": "en-GB-oxendict", "i-ami": "ami", "i-bnn": "bnn",
        "i-default": "", "i-enochian": "", "i-hak": "hak",
        "i-klingon": "tlh", "i-lux": "lb", "i-mingo": "",
        "i-navajo": "nv", "i-pwn": "pwn", "i-tao": "tao",
        "i-tay": "tay", "i-tsu": "tsu", "no-bok": "nb",
        "no-nyn": "nn", "sgn-be-fr": "sfb", "sgn-be-nl": "vgt",
        "sgn-ch-de": "sgg", "zh-guoyu": "cmn", "zh-hakka": "hak",
        "zh-min": "", "zh-min-nan": "nan", "zh-xiang": "hsn",
    ]

    private static let preferredLanguageAliases: [String: String] = {
        let entries = """
        bh:bih in:id iw:he ji:yi jw:jv mo:ro aam:aas adp:dz ajp:apc ajt:aeb asd:snz aue:ktz ayx:nun bgm:bcg bic:bir bjd:drl blg:iba ccq:rki cjr:mom cka:cmr cmk:xch coy:pij cqu:quh dek:sqm dit:dif drh:khk drr:kzk drw:prs gav:dev gfx:vaj ggn:gvr gli:kzk gti:nyc guv:duz hrr:jal ibi:opa ilw:gal jeg:oyb kgc:tdf kgh:kml kgm:plu koj:kwv krm:bmf ktr:dtp kvs:gdj kwq:yam kxe:tvd kxl:kru kzj:dtp kzt:dtp lak:ksp lii:raq llo:ngt lmm:rmx meg:cir mst:mry mwj:vaj myd:aog myt:mry nad:xny ncp:kdz nns:nbr nnx:ngv nom:cbr nte:eko nts:pij nxu:bpp oun:vaj pat:kxr pcr:adx pmc:huw pmk:crr pmu:phr ppa:bfy ppr:lcq prp:gu pry:prt puz:pub sca:hle skk:oyb smd:kmb snb:iba szd:umi tdu:dtp thc:tpo thw:ola thx:oyb tie:ras tkk:twm tlw:weo tmk:tdg tmp:tyj tne:kak tnf:prs tpw:tpn tsf:taj uok:ema xba:cax xia:acn xkh:waw xrq:dmw xss:zko ybd:rki yma:lrr ymt:mtm yol:enm yos:zom yuu:yug zir:scv zkb:kjh
        """
        return Dictionary(uniqueKeysWithValues: entries.split(whereSeparator: \.isWhitespace).compactMap {
            let pair = $0.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            return (String(pair[0]), String(pair[1]))
        })
    }()

    private static let localizedLanguageNames: [String: String] = {
        var candidates: [String: Set<String>] = [:]
        let locales = [Locale(identifier: "en"), Locale(identifier: "cs")]
        for code in Locale.LanguageCode.isoLanguageCodes {
            guard let base = canonicalBase(code.identifier) else { continue }
            for locale in locales {
                guard let name = locale.localizedString(forLanguageCode: base) else {
                    continue
                }
                candidates[languageNameKey(name), default: []].insert(base)
            }
        }
        let explicit: [String: String] = [
            "English": "en", "angličtina": "en", "anglicky": "en",
            "Czech": "cs", "Czech language": "cs", "čeština": "cs",
            "česky": "cs", "český jazyk": "cs",
        ]
        for (name, code) in explicit {
            candidates[languageNameKey(name), default: []].insert(code)
        }
        return candidates.compactMapValues { values in
            values.count == 1 ? values.first : nil
        }
    }()

    private static let cachedLanguageSuggestions: [String: [MetadataLanguageSuggestion]] = [
        "en": makeLanguageSuggestions(displayLocaleIdentifier: "en"),
        "cs": makeLanguageSuggestions(displayLocaleIdentifier: "cs"),
    ]

    static func language(_ raw: String?) -> NormalizedLanguage {
        let rawValue = raw ?? ""
        let trimmed = nfc(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else {
            return unrecognizedLanguage(rawValue: rawValue, normalized: trimmed)
        }

        if let namedBase = localizedLanguageNames[languageNameKey(trimmed)] {
            return NormalizedLanguage(
                rawValue: rawValue,
                normalizedRawValue: trimmed,
                canonicalTag: namedBase,
                baseLanguageCode: namedBase,
                scriptCode: nil,
                regionCode: nil,
                variants: [],
                status: .recognized
            )
        }

        let hyphenated = trimmed.replacingOccurrences(of: "_", with: "-")
        let lowercased = hyphenated.lowercased(with: posixLocale)
        if let preferred = grandfatheredLanguageTags[lowercased] {
            if preferred.isEmpty {
                return NormalizedLanguage(
                    rawValue: rawValue,
                    normalizedRawValue: trimmed,
                    canonicalTag: lowercased,
                    baseLanguageCode: nil,
                    scriptCode: nil,
                    regionCode: nil,
                    variants: [],
                    status: .special
                )
            }
            let canonical = language(preferred)
            return NormalizedLanguage(
                rawValue: rawValue,
                normalizedRawValue: trimmed,
                canonicalTag: canonical.canonicalTag,
                baseLanguageCode: canonical.baseLanguageCode,
                scriptCode: canonical.scriptCode,
                regionCode: canonical.regionCode,
                variants: canonical.variants,
                status: canonical.status
            )
        }
        let parts = lowercased.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else {
            return unrecognizedLanguage(rawValue: rawValue, normalized: trimmed)
        }

        if parts[0] == "x" {
            guard parts.count > 1,
                  parts.dropFirst().allSatisfy({
                      (1 ... 8).contains($0.count) && isASCIIAlphanumeric($0)
                  }) else {
                return unrecognizedLanguage(rawValue: rawValue, normalized: trimmed)
            }
            return NormalizedLanguage(
                rawValue: rawValue,
                normalizedRawValue: trimmed,
                canonicalTag: parts.joined(separator: "-"),
                baseLanguageCode: nil,
                scriptCode: nil,
                regionCode: nil,
                variants: Array(parts.dropFirst()),
                status: .privateUse
            )
        }

        let specialCodes: Set<String> = ["und", "mul", "zxx"]
        if specialCodes.contains(parts[0]) {
            guard parts.count == 1 else {
                return unrecognizedLanguage(rawValue: rawValue, normalized: trimmed)
            }
            return NormalizedLanguage(
                rawValue: rawValue,
                normalizedRawValue: trimmed,
                canonicalTag: parts[0],
                baseLanguageCode: parts[0],
                scriptCode: nil,
                regionCode: nil,
                variants: [],
                status: .special
            )
        }

        guard let base = canonicalBase(parts[0]) else {
            return unrecognizedLanguage(rawValue: rawValue, normalized: trimmed)
        }

        var canonicalParts = [base]
        var script: String?
        var region: String?
        var variants: [String] = []
        var index = 1

        var extlangCount = 0
        while index < parts.count,
              extlangCount < 3,
              parts[index].count == 3,
              canonicalBase(parts[index]) != nil {
            let extlang = preferredLanguageAliases[parts[index]] ?? parts[index]
            canonicalParts.append(extlang)
            variants.append(extlang)
            extlangCount += 1
            index += 1
        }

        if index < parts.count,
           parts[index].count == 4,
           isASCIIAlpha(parts[index]),
           Locale.Script(titlecased(parts[index])).isISOScript {
            script = titlecased(parts[index])
            canonicalParts.append(script!)
            index += 1
        }

        if index < parts.count {
            let candidate = parts[index]
            let canonicalRegion = candidate.count == 2
                ? candidate.uppercased(with: posixLocale)
                : candidate
            if ((candidate.count == 2 && isASCIIAlpha(candidate))
                || (candidate.count == 3 && candidate.allSatisfy(\.isNumber))),
               Locale.Region(canonicalRegion).isISORegion {
                region = canonicalRegion
                canonicalParts.append(canonicalRegion)
                index += 1
            }
        }

        var isInExtension = false
        var extensionHasValue = false
        while index < parts.count {
            let part = parts[index]
            if part == "x" {
                guard index + 1 < parts.count,
                      parts[(index + 1)...].allSatisfy({
                          (1 ... 8).contains($0.count) && isASCIIAlphanumeric($0)
                      }) else {
                    return unrecognizedLanguage(rawValue: rawValue, normalized: trimmed)
                }
                variants.append(contentsOf: parts[index...])
                canonicalParts.append(contentsOf: parts[index...])
                index = parts.count
                continue
            }
            if part.count == 1, isASCIIAlphanumeric(part), part != "x" {
                guard !isInExtension || extensionHasValue else {
                    return unrecognizedLanguage(rawValue: rawValue, normalized: trimmed)
                }
                isInExtension = true
                extensionHasValue = false
                variants.append(part)
                canonicalParts.append(part)
                index += 1
                continue
            }

            let valid = if isInExtension {
                (2 ... 8).contains(part.count) && isASCIIAlphanumeric(part)
            } else {
                ((5 ... 8).contains(part.count) && isASCIIAlphanumeric(part))
                    || (part.count == 4
                        && part.first?.isNumber == true
                        && isASCIIAlphanumeric(part))
            }
            guard valid else {
                return unrecognizedLanguage(rawValue: rawValue, normalized: trimmed)
            }
            if isInExtension { extensionHasValue = true }
            variants.append(part)
            canonicalParts.append(part)
            index += 1
        }
        guard !isInExtension || extensionHasValue else {
            return unrecognizedLanguage(rawValue: rawValue, normalized: trimmed)
        }

        return NormalizedLanguage(
            rawValue: rawValue,
            normalizedRawValue: trimmed,
            canonicalTag: canonicalParts.joined(separator: "-"),
            baseLanguageCode: base,
            scriptCode: script,
            regionCode: region,
            variants: variants,
            status: isPrivateUseBase(parts[0]) ? .privateUse : .recognized
        )
    }

    static func languageMatches(actual rawActual: String?, operand rawOperand: String) -> Bool {
        let actual = language(rawActual)
        let operand = language(rawOperand)
        guard operand.status != .unrecognized else {
            return rawComparisonKey(actual.normalizedRawValue)
                == rawComparisonKey(operand.normalizedRawValue)
        }
        guard actual.status != .unrecognized else { return false }
        if operand.isBaseLanguageOnly {
            return actual.baseLanguageCode == operand.baseLanguageCode
        }
        return actual.canonicalTag == operand.canonicalTag
    }

    static func languageSearchText(
        _ raw: String?,
        displayLocaleIdentifiers: [String] = ["en", "cs"]
    ) -> String {
        let normalized = language(raw)
        var values = [
            normalized.normalizedRawValue,
            normalized.canonicalTag ?? "",
            normalized.baseLanguageCode ?? "",
        ]
        if let base = normalized.baseLanguageCode, normalized.status == .recognized {
            for identifier in displayLocaleIdentifiers {
                let locale = Locale(identifier: identifier)
                values.append(locale.localizedString(forLanguageCode: base) ?? "")
            }
        }
        return values.map(searchKey).joined(separator: " ")
    }

    static func languageSuggestions(
        displayLocaleIdentifier: String
    ) -> [MetadataLanguageSuggestion] {
        if let cached = cachedLanguageSuggestions[displayLocaleIdentifier] {
            return cached
        }
        return makeLanguageSuggestions(
            displayLocaleIdentifier: displayLocaleIdentifier
        )
    }

    private static func makeLanguageSuggestions(
        displayLocaleIdentifier: String
    ) -> [MetadataLanguageSuggestion] {
        let locale = Locale(identifier: displayLocaleIdentifier)
        var suggestionsByTag: [String: MetadataLanguageSuggestion] = [:]
        for languageCode in Locale.LanguageCode.isoLanguageCodes {
            guard let tag = canonicalBase(languageCode.identifier),
                  suggestionsByTag[tag] == nil else {
                continue
            }
            let name = locale.localizedString(forLanguageCode: tag) ?? tag
            suggestionsByTag[tag] = MetadataLanguageSuggestion(
                tag: tag,
                localizedName: name
            )
        }
        return suggestionsByTag.values.sorted {
            $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
        }
    }

    static func isbn(_ raw: String?) -> NormalizedISBN {
        let rawValue = raw ?? ""
        let trimmed = nfc(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else {
            return NormalizedISBN(
                rawValue: rawValue,
                parsedValue: nil,
                canonicalISBN13: nil,
                status: .missing
            )
        }

        var parsingValue = trimmed
        if parsingValue.hasPrefix("=\""), parsingValue.hasSuffix("\"") {
            parsingValue = String(parsingValue.dropFirst(2).dropLast())
        }
        let withoutPrefix = parsingValue.replacingOccurrences(
            of: #"(?i)^ISBN(?:\s*-?\s*(?:10|13))?\s*:?\s*"#,
            with: "",
            options: .regularExpression
        )
        let separatorCharacters = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "-‐‑‒–—")
        )
        let scalars = withoutPrefix.unicodeScalars
        guard scalars.allSatisfy({
            (48 ... 57).contains($0.value)
                || $0 == "X" || $0 == "x"
                || separatorCharacters.contains($0)
        }) else {
            return invalidISBN(rawValue: rawValue)
        }
        let parsed = withoutPrefix
            .uppercased(with: posixLocale)
            .filter { $0.isNumber || $0 == "X" }

        if isValidISBN13(parsed) {
            return NormalizedISBN(
                rawValue: rawValue,
                parsedValue: parsed,
                canonicalISBN13: parsed,
                status: .valid
            )
        }
        if isValidISBN10(parsed) {
            let stem = "978" + parsed.prefix(9)
            let canonical = stem + String(isbn13CheckDigit(for: String(stem)))
            return NormalizedISBN(
                rawValue: rawValue,
                parsedValue: parsed,
                canonicalISBN13: canonical,
                status: .valid
            )
        }
        return NormalizedISBN(
            rawValue: rawValue,
            parsedValue: parsed.isEmpty ? nil : parsed,
            canonicalISBN13: nil,
            status: .invalid
        )
    }

    static func canonicalISBN13(_ raw: String?) -> String? {
        isbn(raw).canonicalISBN13
    }

    /// Conservative textual comparison: NFC, collapsed whitespace, and
    /// case-insensitive matching without discarding punctuation or diacritics.
    static func comparisonKey(_ value: String?) -> String {
        let collapsed = collapseWhitespace(nfc(value ?? ""))
        return nfc(collapsed.folding(options: .caseInsensitive, locale: posixLocale))
    }

    static func tagComparisonKey(_ value: String?) -> String {
        comparisonKey(value)
    }

    static func formatFilterKey(_ value: String?) -> String {
        let key = comparisonKey(value)
        return key == "htm" ? "html" : key
    }

    static func searchKey(_ value: String?) -> String {
        collapseWhitespace(nfc(value ?? "")).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: posixLocale
        )
    }

    static func identifierKey(_ value: String?) -> String {
        searchKey(value).filter { $0.isLetter || $0.isNumber }
    }

    private static func canonicalBase(_ rawBase: String) -> String? {
        var base = rawBase.lowercased(with: posixLocale)
        base = bibliographicLanguageAliases[base] ?? base
        base = preferredLanguageAliases[base] ?? base
        if base.count == 3,
           let alpha2 = Locale.LanguageCode(base).identifier(.alpha2),
           isRegisteredLanguageBase(alpha2) {
            return alpha2
        }
        guard isRegisteredLanguageBase(base) || isPrivateUseBase(base) else {
            return nil
        }
        if let alpha2 = Locale.LanguageCode(base).identifier(.alpha2),
           isRegisteredLanguageBase(alpha2) {
            return alpha2
        }
        return base
    }

    private static func isRegisteredLanguageBase(_ code: String) -> Bool {
        guard isASCIIAlpha(code) else { return false }
        let bytes = Array(code.utf8)
        guard bytes.count == 2 || bytes.count == 3 else { return false }
        let index = bytes.reduce(0) { result, byte in
            result * 26 + Int(byte - 97)
        }
        let bits = bytes.count == 2
            ? LanguageRegistryData.registeredTwoLetterLanguageBits
            : LanguageRegistryData.registeredThreeLetterLanguageBits
        guard index / 8 < bits.count else { return false }
        return bits[index / 8] & (1 << (index % 8)) != 0
    }

    private static func isPrivateUseBase(_ code: String) -> Bool {
        guard code.count == 3 else { return false }
        return code >= "qaa" && code <= "qtz"
    }

    private static func languageNameKey(_ value: String) -> String {
        searchKey(value).filter { $0.isLetter || $0.isNumber }
    }

    private static func rawComparisonKey(_ value: String?) -> String {
        nfc(collapseWhitespace(value ?? "").folding(
            options: .caseInsensitive,
            locale: posixLocale
        ))
    }

    private static func unrecognizedLanguage(
        rawValue: String,
        normalized: String
    ) -> NormalizedLanguage {
        NormalizedLanguage(
            rawValue: rawValue,
            normalizedRawValue: normalized,
            canonicalTag: nil,
            baseLanguageCode: nil,
            scriptCode: nil,
            regionCode: nil,
            variants: [],
            status: .unrecognized
        )
    }

    private static func invalidISBN(rawValue: String) -> NormalizedISBN {
        NormalizedISBN(
            rawValue: rawValue,
            parsedValue: nil,
            canonicalISBN13: nil,
            status: .invalid
        )
    }

    private static func isValidISBN10(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let characters = Array(value)
        guard characters.dropLast().allSatisfy(\.isNumber),
              characters.last?.isNumber == true || characters.last == "X" else {
            return false
        }
        let sum = characters.enumerated().reduce(0) { total, pair in
            let digit = pair.element == "X" ? 10 : pair.element.wholeNumberValue!
            return total + digit * (10 - pair.offset)
        }
        return sum.isMultiple(of: 11)
    }

    private static func isValidISBN13(_ value: String) -> Bool {
        guard value.count == 13,
              value.hasPrefix("978") || value.hasPrefix("979"),
              value.allSatisfy(\.isNumber) else {
            return false
        }
        let digits = value.compactMap(\.wholeNumberValue)
        let sum = digits.prefix(12).enumerated().reduce(0) { total, pair in
            total + pair.element * (pair.offset.isMultiple(of: 2) ? 1 : 3)
        }
        return (sum + digits[12]).isMultiple(of: 10)
    }

    private static func isbn13CheckDigit(for twelveDigits: String) -> Int {
        let sum = twelveDigits.compactMap(\.wholeNumberValue).enumerated().reduce(0) {
            $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 1 : 3)
        }
        return (10 - sum % 10) % 10
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func nfc(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
    }

    private static func titlecased(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst().lowercased()
    }

    private static func isASCIIAlpha(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            (65 ... 90).contains($0.value) || (97 ... 122).contains($0.value)
        }
    }

    private static func isASCIIAlphanumeric(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            (48 ... 57).contains($0.value)
                || (65 ... 90).contains($0.value)
                || (97 ... 122).contains($0.value)
        }
    }
}
