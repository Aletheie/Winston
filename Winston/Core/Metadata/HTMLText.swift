import Foundation

private nonisolated enum HTMLPatterns {
    static let lineBreaks: [(regex: NSRegularExpression, replacement: String)] = [
        ("<br ?/?>", "\n"), ("</p>", "\n\n"), ("</li>", "\n"), ("</div>", "\n"),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]), $0.1) }

    static let anyTag = try! NSRegularExpression(pattern: "<[^>]+>")
    static let spaceRuns = try! NSRegularExpression(pattern: "[ \\t]+")
    static let newlineRuns = try! NSRegularExpression(pattern: "\n{3,}")

    static let nonContent: [NSRegularExpression] = [
        "<!--[\\s\\S]*?-->",
        "<script\\b[^>]*>[\\s\\S]*?</script>",
        "<style\\b[^>]*>[\\s\\S]*?</style>",
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
}

extension String {
    nonisolated private func replacing(_ regex: NSRegularExpression, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: self, range: NSRange(location: 0, length: (self as NSString).length),
            withTemplate: template
        )
    }

    nonisolated var strippedHTML: String {
        var s = self
        for (regex, replacement) in HTMLPatterns.lineBreaks {
            s = s.replacing(regex, with: replacement)
        }
        s = s.replacing(HTMLPatterns.anyTag, with: "")
        s = s.decodingHTMLEntities()
        s = s.replacing(HTMLPatterns.spaceRuns, with: " ")
        s = s.replacing(HTMLPatterns.newlineRuns, with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated var removingHTMLNonContent: String {
        var s = self
        for regex in HTMLPatterns.nonContent {
            s = s.replacing(regex, with: "")
        }
        return s
    }

    nonisolated func decodingHTMLEntities() -> String {
        let named: [String: Character] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
            "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}",
            "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}",
            "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "deg": "\u{00B0}",
        ]
        var result = ""
        result.reserveCapacity(count)
        var i = startIndex
        while i < endIndex {
            guard self[i] == "&",
                  let semi = self[i...].firstIndex(of: ";"),
                  distance(from: i, to: semi) <= 12 else {
                result.append(self[i]); i = index(after: i); continue
            }
            let body = self[index(after: i)..<semi]
            if body.first == "#" {
                let digits = body.dropFirst()
                let scalar: Unicode.Scalar? = (digits.first == "x" || digits.first == "X")
                    ? UInt32(digits.dropFirst(), radix: 16).flatMap(Unicode.Scalar.init)
                    : UInt32(digits, radix: 10).flatMap(Unicode.Scalar.init)
                if let scalar { result.unicodeScalars.append(scalar); i = index(after: semi); continue }
            } else if let character = named[String(body)] {
                result.append(character); i = index(after: semi); continue
            }
            result.append(self[i]); i = index(after: i)
        }
        return result
    }
}
