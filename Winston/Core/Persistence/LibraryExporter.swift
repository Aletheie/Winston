import Foundation

nonisolated struct ExportRow: Sendable {
    var title: String
    var author: String
    var translator: String
    var series: String
    var seriesIndex: String
    var year: String
    var publisher: String
    var format: String
    var tags: String
    var rating: Int
    var status: String
    var sourcePath: String
    var readableName: String
    var workUUID: String
    var workTitle: String
    var editionUUID: String
    var editionStatement: String
}

nonisolated enum LibraryExporter {
    struct Result: Sendable { var copied: Int; var failed: Int }

    static func export(_ rows: [ExportRow], to folder: URL) -> Result {
        var copied = 0, failed = 0
        var usedNames = Set<String>()
        var exportedRows: [ExportRow] = []

        for var row in rows {
            let name = FileNaming.uniqueName(row.readableName, in: &usedNames)
            row.readableName = name
            let dest = folder.appending(path: name)
            do {
                if FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(atPath: row.sourcePath, toPath: dest.path(percentEncoded: false))
                copied += 1
                exportedRows.append(row)
            } catch {
                failed += 1
            }
        }

        writeCSV(exportedRows, to: folder.appending(path: "metadata.csv"))
        writeJSON(exportedRows, to: folder.appending(path: "metadata.json"))
        return Result(copied: copied, failed: failed)
    }

    private static func writeCSV(_ rows: [ExportRow], to url: URL) {
        let header = ["Title", "Author", "Series", "Series Index", "Year", "Publisher",
                      "Format", "Tags", "Rating", "Status", "File", "Translator",
                      "Work UUID", "Work Title", "Edition UUID", "Edition Statement"]
        var lines = [header.map(csvEscape).joined(separator: ",")]
        for r in rows {
            let cells = [r.title, r.author, r.series, r.seriesIndex, r.year, r.publisher,
                         r.format, r.tags, String(r.rating), r.status, r.readableName,
                         r.translator, r.workUUID, r.workTitle, r.editionUUID, r.editionStatement]
            lines.append(cells.map(csvEscape).joined(separator: ","))
        }
        try? lines.joined(separator: "\n").data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private static func writeJSON(_ rows: [ExportRow], to url: URL) {
        let objects: [[String: Any]] = rows.map {
            [
                "title": $0.title, "author": $0.author, "series": $0.series,
                "seriesIndex": $0.seriesIndex, "year": $0.year, "publisher": $0.publisher,
                "format": $0.format, "tags": $0.tags, "rating": $0.rating,
                "status": $0.status, "file": $0.readableName,
                "translator": $0.translator, "workUUID": $0.workUUID,
                "workTitle": $0.workTitle, "editionUUID": $0.editionUUID,
                "editionStatement": $0.editionStatement,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func csvEscape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
