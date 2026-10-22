import Foundation
import Testing
@testable import Winston

struct ElevenReaderHandoffTests {
    private func candidate(
        _ format: String,
        primary: Bool = false,
        drm: Bool = false,
        added: TimeInterval = 0
    ) -> ElevenReaderHandoff.Candidate {
        ElevenReaderHandoff.Candidate(
            fileName: "\(UUID().uuidString).\(format)",
            format: format,
            isPrimary: primary,
            drmProtected: drm,
            dateAdded: Date(timeIntervalSince1970: added)
        )
    }

    @Test func prefersEPUBOverPrimaryPDF() {
        let pdf = candidate("pdf", primary: true)
        let epub = candidate("epub")
        #expect(ElevenReaderHandoff.best(of: [pdf, epub]) == epub)
    }

    @Test func prefersPrimaryWithinTheSameFormat() {
        let older = candidate("epub", added: 0)
        let primary = candidate("epub", primary: true, added: 100)
        #expect(ElevenReaderHandoff.best(of: [older, primary]) == primary)
    }

    @Test func prefersOlderFileWhenRankIsEqual() {
        let newer = candidate("pdf", added: 100)
        let older = candidate("pdf", added: 0)
        #expect(ElevenReaderHandoff.best(of: [newer, older]) == older)
    }

    @Test func skipsKindleFormatsAndDRMProtectedFiles() {
        let mobi = candidate("mobi", primary: true)
        let lockedEPUB = candidate("epub", drm: true)
        let text = candidate("txt")
        #expect(ElevenReaderHandoff.best(of: [mobi, lockedEPUB, text]) == text)
    }

    @Test func explainsWhyNoFileCanBeHandedOff() {
        #expect(ElevenReaderHandoff.unavailability(among: []) == .noDigitalFile)
        #expect(
            ElevenReaderHandoff.unavailability(among: [candidate("epub", drm: true)])
                == .drmProtected
        )
        #expect(
            ElevenReaderHandoff.unavailability(among: [candidate("azw3"), candidate("mobi")])
                == .unsupportedFormat
        )
        #expect(ElevenReaderHandoff.unavailability(among: [candidate("docx")]) == nil)
    }

    @Test func webLibraryIsTheElevenReaderReaderLibrary() {
        #expect(ElevenReaderHandoff.libraryURL.absoluteString == "https://elevenreader.io/reader/library")
    }
}
