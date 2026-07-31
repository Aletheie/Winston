import Foundation
import OSLog

nonisolated enum ImportSourceLeasePurpose:
    String,
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    case deviceImport
    case catalogDownload

    var directoryPrefix: String {
        switch self {
        case .deviceImport: "lease"
        case .catalogDownload: "opds-lease"
        }
    }
}

nonisolated struct WinstonImportSourceLease: Sendable, Equatable, Hashable {
    let id: UUID
    let directoryURL: URL
    let fileURL: URL
    let createdAt: Date
    let purpose: ImportSourceLeasePurpose

    init(
        id: UUID,
        directoryURL: URL,
        fileURL: URL,
        createdAt: Date,
        purpose: ImportSourceLeasePurpose = .deviceImport
    ) {
        self.id = id
        self.directoryURL = directoryURL
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.purpose = purpose
    }
}

nonisolated enum ImportSource: Sendable, Equatable {
    case external(URL)
    case winstonOwned(WinstonImportSourceLease)

    var url: URL {
        switch self {
        case .external(let url):
            url
        case .winstonOwned(let lease):
            lease.fileURL
        }
    }

    var ownedLease: WinstonImportSourceLease? {
        guard case .winstonOwned(let lease) = self else { return nil }
        return lease
    }
}

nonisolated struct ImportSourceLeaseStore: Sendable {
    private struct Marker: Codable, Sendable, Equatable {
        let version: Int
        let id: UUID
        let fileName: String
        let createdAt: Date
        let purpose: ImportSourceLeasePurpose

        private enum CodingKeys: String, CodingKey {
            case version, id, fileName, createdAt, purpose
        }

        init(
            version: Int,
            id: UUID,
            fileName: String,
            createdAt: Date,
            purpose: ImportSourceLeasePurpose
        ) {
            self.version = version
            self.id = id
            self.fileName = fileName
            self.createdAt = createdAt
            self.purpose = purpose
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            id = try container.decode(UUID.self, forKey: .id)
            fileName = try container.decode(String.self, forKey: .fileName)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            purpose = try container.decodeIfPresent(
                ImportSourceLeasePurpose.self,
                forKey: .purpose
            ) ?? .deviceImport
        }
    }

    static let staleLeaseAge: TimeInterval = 7 * 24 * 60 * 60

    let rootDirectory: URL

    init(rootDirectory: URL = AppPaths.deviceImportLeasesDirectory) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    func create(
        fileName: ManagedLeafName,
        id: UUID = UUID(),
        createdAt: Date = .now,
        purpose: ImportSourceLeasePurpose = .deviceImport
    ) throws -> WinstonImportSourceLease {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let directory = rootDirectory.appending(
            path: "\(purpose.directoryPrefix)-\(id.uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let marker = Marker(
            version: 1,
            id: id,
            fileName: fileName.rawValue,
            createdAt: createdAt,
            purpose: purpose
        )
        do {
            let data = try JSONEncoder().encode(marker)
            try data.write(to: markerURL(in: directory), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        guard let fileURL = fileName.appending(to: directory) else {
            try? FileManager.default.removeItem(at: directory)
            throw DeviceError.invalidFileName
        }
        return WinstonImportSourceLease(
            id: id,
            directoryURL: directory,
            fileURL: fileURL,
            createdAt: createdAt,
            purpose: purpose
        )
    }

    func remove(_ lease: WinstonImportSourceLease) throws {
        let directory = lease.directoryURL.standardizedFileURL
        guard directory.deletingLastPathComponent() == rootDirectory,
              directory.lastPathComponent
                == "\(lease.purpose.directoryPrefix)-\(lease.id.uuidString)",
              lease.fileURL.standardizedFileURL.deletingLastPathComponent()
                == directory else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let marker = try readMarker(in: directory)
        guard marker.version == 1,
              marker.id == lease.id,
              marker.fileName == lease.fileURL.lastPathComponent,
              marker.purpose == lease.purpose else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    func pruneStaleLeases(
        before cutoff: Date = .now.addingTimeInterval(-Self.staleLeaseAge)
    ) throws -> Int {
        guard FileManager.default.fileExists(
            atPath: rootDirectory.path(percentEncoded: false)
        ) else {
            return 0
        }
        let candidates = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        )
        var removed = 0
        for directory in candidates {
            let values = try? directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true,
                  let marker = try? readMarker(in: directory),
                  marker.version == 1,
                  marker.createdAt < cutoff,
                  directory.lastPathComponent
                    == "\(marker.purpose.directoryPrefix)-\(marker.id.uuidString)",
                  marker.fileName == directory
                    .appending(path: marker.fileName)
                    .lastPathComponent else {
                continue
            }
            let lease = WinstonImportSourceLease(
                id: marker.id,
                directoryURL: directory,
                fileURL: directory.appending(path: marker.fileName),
                createdAt: marker.createdAt,
                purpose: marker.purpose
            )
            do {
                try remove(lease)
                removed += 1
            } catch {
                Log.persistence.error(
                    "Could not prune stale import lease \(directory.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return removed
    }

    private func readMarker(in directory: URL) throws -> Marker {
        let data = try Data(contentsOf: markerURL(in: directory))
        return try JSONDecoder().decode(Marker.self, from: data)
    }

    private func markerURL(in directory: URL) -> URL {
        directory.appending(path: ".winston-import-lease.json")
    }
}
