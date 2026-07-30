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
    var isPhysicalCopy = false
    var shelfLocation = ""
}

nonisolated enum LibraryExporter {
    enum FailureStage: String, Sendable, Equatable {
        case createStaging
        case copyBook
        case writeCSV
        case writeJSON
        case publish
        case cleanup
    }

    struct Failure: Sendable, Equatable {
        let stage: FailureStage
        let itemName: String?
        let detail: String
    }

    struct Result: Sendable, Equatable {
        let finalURL: URL?
        let stagingURL: URL?
        let copied: Int
        let skipped: Int
        let failures: [Failure]

        var failed: Int { failures.count }
        var isCommitted: Bool { finalURL != nil }
    }

    struct FileSystem: Sendable {
        var fileExists: @Sendable (URL) -> Bool
        var createDirectory: @Sendable (URL) throws -> Void
        var copyItem: @Sendable (URL, URL) throws -> Void
        var moveItem: @Sendable (URL, URL) throws -> Void
        var removeItem: @Sendable (URL) throws -> Void
        var writeData: @Sendable (Data, URL) throws -> Void

        static let live = FileSystem(
            fileExists: {
                FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
            },
            createDirectory: {
                try FileManager.default.createDirectory(
                    at: $0,
                    withIntermediateDirectories: false
                )
            },
            copyItem: {
                try FileManager.default.copyItem(at: $0, to: $1)
            },
            moveItem: {
                try FileManager.default.moveItem(at: $0, to: $1)
            },
            removeItem: {
                try FileManager.default.removeItem(at: $0)
            },
            writeData: {
                try $0.write(to: $1, options: .atomic)
            }
        )
    }

    static func export(
        _ rows: [ExportRow],
        to parentFolder: URL,
        fileSystem: FileSystem = .live,
        now: Date = .now,
        stagingID: UUID = UUID()
    ) -> Result {
        let finalURL = uniqueFinalURL(
            in: parentFolder,
            now: now,
            fileExists: fileSystem.fileExists
        )
        let stagingURL = parentFolder.appending(
            path: ".winston-export-\(stagingID.uuidString).staging",
            directoryHint: .isDirectory
        )
        var failures: [Failure] = []
        do {
            try fileSystem.createDirectory(stagingURL)
        } catch {
            failures.append(Failure(
                stage: .createStaging,
                itemName: nil,
                detail: error.localizedDescription
            ))
            return Result(
                finalURL: nil,
                stagingURL: nil,
                copied: 0,
                skipped: 0,
                failures: failures
            )
        }

        var copied = 0
        var skipped = 0
        var usedNames = Set<String>()
        var exportedRows: [ExportRow] = []

        for var row in rows {
            if row.sourcePath.isEmpty {
                row.readableName = ""
                exportedRows.append(row)
                skipped += 1
                continue
            }

            let safeBaseName = safeReadableName(row.readableName)
            let name = FileNaming.uniqueName(safeBaseName, in: &usedNames)
            row.readableName = name
            let destination = stagingURL.appending(path: name)
            do {
                try fileSystem.copyItem(
                    URL(fileURLWithPath: row.sourcePath),
                    destination
                )
                copied += 1
                exportedRows.append(row)
            } catch {
                failures.append(Failure(
                    stage: .copyBook,
                    itemName: name,
                    detail: error.localizedDescription
                ))
            }
        }

        do {
            try writeCSV(
                exportedRows,
                to: stagingURL.appending(path: "metadata.csv"),
                fileSystem: fileSystem
            )
        } catch {
            failures.append(Failure(
                stage: .writeCSV,
                itemName: "metadata.csv",
                detail: error.localizedDescription
            ))
            return failedResult(
                stagingURL: stagingURL,
                copied: copied,
                skipped: skipped,
                failures: failures,
                fileSystem: fileSystem
            )
        }

        do {
            try writeJSON(
                exportedRows,
                to: stagingURL.appending(path: "metadata.json"),
                fileSystem: fileSystem
            )
        } catch {
            failures.append(Failure(
                stage: .writeJSON,
                itemName: "metadata.json",
                detail: error.localizedDescription
            ))
            return failedResult(
                stagingURL: stagingURL,
                copied: copied,
                skipped: skipped,
                failures: failures,
                fileSystem: fileSystem
            )
        }

        do {
            try fileSystem.moveItem(stagingURL, finalURL)
            return Result(
                finalURL: finalURL,
                stagingURL: nil,
                copied: copied,
                skipped: skipped,
                failures: failures
            )
        } catch {
            failures.append(Failure(
                stage: .publish,
                itemName: finalURL.lastPathComponent,
                detail: error.localizedDescription
            ))
            return failedResult(
                stagingURL: stagingURL,
                copied: copied,
                skipped: skipped,
                failures: failures,
                fileSystem: fileSystem
            )
        }
    }

    private static func failedResult(
        stagingURL: URL,
        copied: Int,
        skipped: Int,
        failures: [Failure],
        fileSystem: FileSystem
    ) -> Result {
        var failures = failures
        do {
            try fileSystem.removeItem(stagingURL)
            return Result(
                finalURL: nil,
                stagingURL: nil,
                copied: copied,
                skipped: skipped,
                failures: failures
            )
        } catch {
            failures.append(Failure(
                stage: .cleanup,
                itemName: stagingURL.lastPathComponent,
                detail: error.localizedDescription
            ))
            return Result(
                finalURL: nil,
                stagingURL: stagingURL,
                copied: copied,
                skipped: skipped,
                failures: failures
            )
        }
    }

    private static func uniqueFinalURL(
        in parentFolder: URL,
        now: Date,
        fileExists: @Sendable (URL) -> Bool
    ) -> URL {
        let timestamp = ISO8601DateFormatter()
            .string(from: now)
            .replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: ":", with: "-")
        let base = "Winston Export \(timestamp.prefix(19))"
        var suffix = 1
        while true {
            let name = suffix == 1 ? base : "\(base) (\(suffix))"
            let candidate = parentFolder.appending(
                path: name,
                directoryHint: .isDirectory
            )
            if !fileExists(candidate) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func safeReadableName(_ requestedName: String) -> String {
        let sanitized = FileNaming.sanitized(requestedName)
        guard let leaf = ManagedLeafName(rawValue: sanitized) else {
            return "Book"
        }
        return leaf.rawValue
    }

    private static func writeCSV(
        _ rows: [ExportRow],
        to url: URL,
        fileSystem: FileSystem
    ) throws {
        let header = ["Title", "Author", "Series", "Series Index", "Year", "Publisher",
                      "Format", "Tags", "Rating", "Status", "File", "Translator",
                      "Work UUID", "Work Title", "Edition UUID", "Edition Statement",
                      "Physical Copy", "Shelf"]
        var lines = [header.map(csvEscape).joined(separator: ",")]
        for r in rows {
            let cells = [r.title, r.author, r.series, r.seriesIndex, r.year, r.publisher,
                         r.format, r.tags, String(r.rating), r.status, r.readableName,
                         r.translator, r.workUUID, r.workTitle, r.editionUUID, r.editionStatement,
                         r.isPhysicalCopy ? "true" : "false", r.shelfLocation]
            lines.append(cells.map(csvEscape).joined(separator: ","))
        }
        try fileSystem.writeData(
            Data(lines.joined(separator: "\n").utf8),
            url
        )
    }

    private static func writeJSON(
        _ rows: [ExportRow],
        to url: URL,
        fileSystem: FileSystem
    ) throws {
        let objects: [[String: Any]] = rows.map {
            [
                "title": $0.title, "author": $0.author, "series": $0.series,
                "seriesIndex": $0.seriesIndex, "year": $0.year, "publisher": $0.publisher,
                "format": $0.format, "tags": $0.tags, "rating": $0.rating,
                "status": $0.status, "file": $0.readableName,
                "translator": $0.translator, "workUUID": $0.workUUID,
                "workTitle": $0.workTitle, "editionUUID": $0.editionUUID,
                "editionStatement": $0.editionStatement,
                "physicalCopy": $0.isPhysicalCopy, "shelf": $0.shelfLocation,
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: objects,
            options: [.prettyPrinted, .sortedKeys]
        )
        try fileSystem.writeData(data, url)
    }

    static func csvEscape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
