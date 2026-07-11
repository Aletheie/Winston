import Foundation
import OSLog

// One-time carry-over after the rename from Kalibre: data folder, store file
// and defaults domain. The "Kalibre" literals are the legacy names — keep them.
nonisolated enum RenameMigration {
    static let legacyFolderName = "Kalibre"
    static let legacyStoreName = "Kalibre.store"
    static let legacyDefaultsDomain = "cz.annajung.Kalibre"
    private static let defaultsMarkerKey = "didMigrateKalibreDefaults"

    static func runIfNeeded() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        migrateDataFolder(
            from: base.appending(path: legacyFolderName, directoryHint: .isDirectory),
            to: AppPaths.rootDirectory,
            newStoreName: PersistenceController.storeURL.lastPathComponent
        )
        migrateDefaults(
            from: legacyDefaultsDomain,
            into: .standard,
            appDomain: Bundle.main.bundleIdentifier ?? "cz.annajung.Winston"
        )
    }

    static func migrateDataFolder(from oldRoot: URL, to newRoot: URL, newStoreName: String) {
        let fm = FileManager.default
        let oldRootPath = oldRoot.path(percentEncoded: false)
        let newRootPath = newRoot.path(percentEncoded: false)

        if fm.fileExists(atPath: oldRootPath), !fm.fileExists(atPath: newRootPath) {
            do {
                try fm.moveItem(at: oldRoot, to: newRoot)
                Log.persistence.info("Rename migration: moved \(oldRoot.lastPathComponent, privacy: .public) data folder to \(newRoot.lastPathComponent, privacy: .public)")
            } catch {
                Log.persistence.error("Rename migration: moving the legacy data folder failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        let oldStoreBase = newRoot.appending(path: legacyStoreName).path(percentEncoded: false)
        let newStoreBase = newRoot.appending(path: newStoreName).path(percentEncoded: false)
        guard fm.fileExists(atPath: oldStoreBase), !fm.fileExists(atPath: newStoreBase) else { return }
        for sidecar in ["", "-wal", "-shm"] where fm.fileExists(atPath: oldStoreBase + sidecar) {
            do {
                try fm.moveItem(at: URL(filePath: oldStoreBase + sidecar),
                                to: URL(filePath: newStoreBase + sidecar))
            } catch {
                Log.persistence.error("Rename migration: renaming the store file failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func migrateDefaults(from oldDomain: String, into defaults: UserDefaults, appDomain: String) {
        guard defaults.object(forKey: defaultsMarkerKey) == nil else { return }
        defaults.set(true, forKey: defaultsMarkerKey)
        guard let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else { return }

        let current = defaults.persistentDomain(forName: appDomain) ?? [:]
        for (key, value) in old where current[key] == nil {
            defaults.set(value, forKey: key)
        }
        Log.persistence.info("Rename migration: copied \(old.count) settings from the legacy defaults domain")
    }
}
