import Foundation
import Testing
@testable import Winston

@MainActor
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

    private func record(_ id: UUID, ready: Bool) -> LibraryBookRecord {
        LibraryBookRecord(
            id: id,
            sourceOrdinal: 0,
            displayTitle: id.uuidString,
            displayAuthor: "Author",
            dateAdded: .now,
            rating: 0,
            readingStatus: .unread,
            format: "EPUB",
            tags: [],
            series: nil,
            seriesIndex: 0,
            collectionIDs: [],
            elevenReaderReady: ready
        )
    }

    @Test func recordCaptureMatchesTheHandoffChoice() {
        let mobiWithEPUB = Book(fileName: "primary.mobi", originalFileName: "Book.mobi")
        _ = BookAsset(uuid: mobiWithEPUB.uuid, fileName: "primary.mobi", book: mobiWithEPUB)
        _ = BookAsset(fileName: "sibling.epub", book: mobiWithEPUB)

        let lockedEPUB = Book(fileName: "locked.epub", originalFileName: "Locked.epub")
        _ = BookAsset(uuid: lockedEPUB.uuid, fileName: "locked.epub", drmProtected: true, book: lockedEPUB)

        let paper = Book(fileName: "", originalFileName: "Paper")
        paper.hasPhysicalCopy = true

        func ready(_ book: Book) -> Bool {
            LibraryBookRecord(book, sourceOrdinal: 0, includeCollections: false, includeHighlights: false)
                .elevenReaderReady
        }
        #expect(ready(mobiWithEPUB))
        #expect(ElevenReaderHandoff.file(for: mobiWithEPUB)?.fileName == "sibling.epub")
        #expect(!ready(lockedEPUB))
        #expect(!ready(paper))
    }

    @Test func filterAndFacetIncludeOnlyReadyBooks() async {
        let ready = UUID()
        let notReady = UUID()
        let records = [record(ready, ready: true), record(notReady, ready: false)]
        let engine = LibraryMetadataQueryEngine(now: { .now })
        await engine.rebuild(records: records, sourceOrder: records.map(\.id), generation: 1)
        let spec = LibraryQuerySpec(
            filter: .elevenReader,
            searchText: "",
            sort: .sourceOrder,
            savedSearch: nil,
            smartShelf: nil,
            deviceFileNames: [],
            deviceIsConnected: false,
            kindlePresenceFilter: .all
        )
        #expect(await engine.query(spec).ids == [ready])

        var facets = LibraryFacetSnapshot.build(
            records: records, smartCollections: [], deviceFileNames: [], deviceIsConnected: false
        )
        #expect(facets.elevenReader == 1)
        facets.apply(
            [LibraryReadModelRecordChange(id: notReady, old: records[1], new: record(notReady, ready: true))],
            smartCollections: [], deviceFileNames: [], deviceIsConnected: false
        )
        #expect(facets.elevenReader == 2)
        facets.apply(
            [LibraryReadModelRecordChange(id: ready, old: records[0], new: nil)],
            smartCollections: [], deviceFileNames: [], deviceIsConnected: false
        )
        #expect(facets.elevenReader == 1)
    }
}
