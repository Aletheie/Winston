import Foundation
import SwiftUI
import Observation
import Security

nonisolated protocol SecretStoring: Sendable {
    func string(for account: String) -> String?
    @discardableResult func set(_ value: String?, for account: String) -> Bool
}

nonisolated final class KeychainSecretStore: SecretStoring, Sendable {
    private let service: String

    init(service: String = "cz.annajung.Winston") {
        self.service = service
    }

    func string(for account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func set(_ value: String?, for account: String) -> Bool {
        let query = baseQuery(for: account)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var attributes = query
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(for account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }
}

nonisolated final class VolatileSecretStore: SecretStoring, @unchecked Sendable {
    static let shared = VolatileSecretStore()

    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(for account: String) -> String? {
        lock.withLock { values[account] }
    }

    @discardableResult
    func set(_ value: String?, for account: String) -> Bool {
        lock.withLock { values[account] = value }
        return true
    }
}

nonisolated enum AppSecretStoreFactory {
    static func make() -> any SecretStoring {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return VolatileSecretStore.shared
        }
        return KeychainSecretStore()
    }
}

nonisolated enum ExternalBookSearchURL {
    static func make(
        websiteURL: String,
        title: String,
        author: String?
    ) -> URL? {
        let websiteURL = websiteURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{query}", with: "")
        guard !websiteURL.isEmpty,
              var components = URLComponents(string: websiteURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host != nil else { return nil }

        let query = [title, author]
            .compactMap { value in
                value.map(normalizedSearchTerm)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty else { return nil }

        components.path = searchPath(from: components.path)
        components.query = nil
        components.fragment = nil
        components.percentEncodedQuery = "index=&page=1&sort=&display=&q=\(formEncoded(query))"
        return components.url
    }

    private static func normalizedSearchTerm(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func searchPath(from configuredPath: String) -> String {
        var path = configuredPath
        while path.hasSuffix("/") { path.removeLast() }
        if let lastComponent = path.split(separator: "/").last,
           lastComponent.lowercased() == "search" {
            return String(path.dropLast(lastComponent.count)) + "search"
        }
        return path + "/search"
    }

    private static func formEncoded(_ value: String) -> String {
        let hexadecimal = Array("0123456789ABCDEF")
        var result = ""
        result.reserveCapacity(value.utf8.count)

        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39,
                 0x2D, 0x2E, 0x5F, 0x7E:
                result.append(Character(UnicodeScalar(byte)))
            case 0x20:
                result.append("+")
            default:
                result.append("%")
                result.append(hexadecimal[Int(byte >> 4)])
                result.append(hexadecimal[Int(byte & 0x0F)])
            }
        }
        return result
    }
}

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, english, czech

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:  String(localized: "System", comment: "Follow the macOS system language")
        case .english: "English"
        case .czech:   "Čeština"
        }
    }

    var localeCodes: [String]? {
        switch self {
        case .system:  nil
        case .english: ["en"]
        case .czech:   ["cs"]
        }
    }

    nonisolated func effectiveLocalizationCode(
        preferredLocalizations: [String]
    ) -> String {
        switch self {
        case .czech:
            "cs"
        case .english:
            "en"
        case .system:
            preferredLocalizations.contains {
                $0.lowercased().hasPrefix("cs")
            } ? "cs" : "en"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    nonisolated private enum Keys {
        static let onlineMetadata = "onlineMetadataEnabled"
        static let watchEnabled = "watchFolderEnabled"
        static let watchPath = "watchFolderPath"
        static let appLanguage = "appLanguage"
        static let hardcoverToken = "hardcoverToken"
        static let externalBookWebsiteURL = "externalBookWebsiteURL"
        static let legacyExternalBookSearchURLTemplate = "externalBookSearchURLTemplate"
        static let autoBackupEnabled = "autoBackupEnabled"
        static let backupPath = "backupFolderPath"
        static let lastBackupAt = "lastBackupAt"
        static let releaseCheckEnabled = "releaseCheckEnabled"
        static let lastReleaseCheckAt = "lastReleaseCheckAt"
        static let readingGoal = "readingGoal"
        static let gridZoom = "gridZoom"
        static let showDiscoverInSidebar = "showDiscoverInSidebar"
        static let showCatalogsInSidebar = "showCatalogsInSidebar"
        static let inspectBeforeKindleTransfer = "inspectBeforeKindleTransfer"
        static let alwaysReviewImports = "alwaysReviewImports"
        static let opdsCatalogConfigurations = "opdsCatalogConfigurations"
        static let enabledPlugins = "enabledPluginIDs"
        static let pluginGrants = "pluginGrants"
    }

    static let defaultGridZoom = 0.35
    static let gridZoomStep = 0.125
    nonisolated static let hardcoverTokenAccount = "hardcover-token"

    @ObservationIgnored private let secretStore: any SecretStoring
    @ObservationIgnored private let defaults: UserDefaults

    // Never reassign inside didSet — @Observable turns stored properties into accessors and the setter recurses (clamping lives in adjustGridZoom).
    var gridZoom: Double {
        didSet { UserDefaults.standard.set(gridZoom, forKey: Keys.gridZoom) }
    }

    func adjustGridZoom(by delta: Double) {
        gridZoom = min(1, max(0, gridZoom + delta))
    }

    var onlineMetadataEnabled: Bool {
        didSet { UserDefaults.standard.set(onlineMetadataEnabled, forKey: Keys.onlineMetadata) }
    }

    var watchFolderEnabled: Bool {
        didSet { UserDefaults.standard.set(watchFolderEnabled, forKey: Keys.watchEnabled) }
    }

    var watchFolderPath: String? {
        didSet { UserDefaults.standard.set(watchFolderPath, forKey: Keys.watchPath) }
    }

    var hardcoverToken: String {
        didSet {
            let value = hardcoverToken.isEmpty ? nil : hardcoverToken
            if secretStore.set(value, for: Self.hardcoverTokenAccount) {
                UserDefaults.standard.removeObject(forKey: Keys.hardcoverToken)
            }
        }
    }

    var externalBookWebsiteURL: String {
        didSet {
            UserDefaults.standard.set(
                externalBookWebsiteURL,
                forKey: Keys.externalBookWebsiteURL
            )
        }
    }

    var autoBackupEnabled: Bool {
        didSet { UserDefaults.standard.set(autoBackupEnabled, forKey: Keys.autoBackupEnabled) }
    }

    var backupFolderPath: String? {
        didSet { UserDefaults.standard.set(backupFolderPath, forKey: Keys.backupPath) }
    }

    var lastBackupAt: Date? {
        get { UserDefaults.standard.object(forKey: Keys.lastBackupAt) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastBackupAt) }
    }

    var releaseCheckEnabled: Bool {
        didSet { UserDefaults.standard.set(releaseCheckEnabled, forKey: Keys.releaseCheckEnabled) }
    }

    var lastReleaseCheckAt: Date? {
        get { UserDefaults.standard.object(forKey: Keys.lastReleaseCheckAt) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastReleaseCheckAt) }
    }

    var readingGoal: Int {
        didSet { UserDefaults.standard.set(readingGoal, forKey: Keys.readingGoal) }
    }

    var showDiscoverInSidebar: Bool {
        didSet { UserDefaults.standard.set(showDiscoverInSidebar, forKey: Keys.showDiscoverInSidebar) }
    }

    var showCatalogsInSidebar: Bool {
        didSet { UserDefaults.standard.set(showCatalogsInSidebar, forKey: Keys.showCatalogsInSidebar) }
    }

    var inspectBeforeKindleTransfer: Bool {
        didSet {
            UserDefaults.standard.set(
                inspectBeforeKindleTransfer,
                forKey: Keys.inspectBeforeKindleTransfer
            )
        }
    }

    var alwaysReviewImports: Bool {
        didSet {
            UserDefaults.standard.set(
                alwaysReviewImports,
                forKey: Keys.alwaysReviewImports
            )
        }
    }

    var catalogConfigurations: [OPDSCatalogConfiguration] {
        didSet {
            Self.persistCatalogs(catalogConfigurations, to: defaults)
        }
    }

    var enabledPluginIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabledPluginIDs).sorted(), forKey: Keys.enabledPlugins) }
    }

    var pluginGrants: [String: [String]] {
        didSet { UserDefaults.standard.set(pluginGrants, forKey: Keys.pluginGrants) }
    }

    var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: Keys.appLanguage)
            if let codes = appLanguage.localeCodes {
                UserDefaults.standard.set(codes, forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
            guard oldValue != appLanguage else { return }
            catalogConfigurations = Self.normalizedCatalogs(
                catalogConfigurations,
                builtInDefaults: localizedBuiltInCatalogs
            )
        }
    }

    init(
        secretStore: any SecretStoring = AppSecretStoreFactory.make(),
        defaults: UserDefaults = .standard
    ) {
        self.secretStore = secretStore
        self.defaults = defaults
        let storedToken = secretStore.string(for: Self.hardcoverTokenAccount)
        let legacyToken = UserDefaults.standard.string(forKey: Keys.hardcoverToken)
        let resolvedAppLanguage = UserDefaults.standard.string(
            forKey: Keys.appLanguage
        ).flatMap(AppLanguage.init(rawValue:)) ?? .system
        onlineMetadataEnabled = UserDefaults.standard.bool(forKey: Keys.onlineMetadata)
        watchFolderEnabled = UserDefaults.standard.bool(forKey: Keys.watchEnabled)
        watchFolderPath = UserDefaults.standard.string(forKey: Keys.watchPath)
        autoBackupEnabled = UserDefaults.standard.bool(forKey: Keys.autoBackupEnabled)
        backupFolderPath = UserDefaults.standard.string(forKey: Keys.backupPath)
        releaseCheckEnabled = UserDefaults.standard.object(forKey: Keys.releaseCheckEnabled) as? Bool ?? true
        let goal = UserDefaults.standard.integer(forKey: Keys.readingGoal)
        readingGoal = goal > 0 ? goal : 12
        let storedZoom = UserDefaults.standard.object(forKey: Keys.gridZoom) as? Double ?? Self.defaultGridZoom
        gridZoom = min(1, max(0, storedZoom))
        showDiscoverInSidebar = UserDefaults.standard.object(forKey: Keys.showDiscoverInSidebar) as? Bool ?? true
        showCatalogsInSidebar = UserDefaults.standard.object(forKey: Keys.showCatalogsInSidebar) as? Bool ?? true
        inspectBeforeKindleTransfer = UserDefaults.standard.object(
            forKey: Keys.inspectBeforeKindleTransfer
        ) as? Bool ?? false
        alwaysReviewImports = UserDefaults.standard.object(
            forKey: Keys.alwaysReviewImports
        ) as? Bool ?? false
        appLanguage = resolvedAppLanguage
        catalogConfigurations = Self.loadCatalogs(
            from: defaults,
            builtInDefaults: OPDSCatalogConfiguration.builtInDefaults(
                for: resolvedAppLanguage,
                preferredLocalizations: Bundle.main.preferredLocalizations
            )
        )
        enabledPluginIDs = Set(UserDefaults.standard.stringArray(forKey: Keys.enabledPlugins) ?? [])
        pluginGrants = (UserDefaults.standard.dictionary(forKey: Keys.pluginGrants) as? [String: [String]]) ?? [:]
        hardcoverToken = storedToken ?? legacyToken ?? ""
        externalBookWebsiteURL = UserDefaults.standard.string(
            forKey: Keys.externalBookWebsiteURL
        ) ?? UserDefaults.standard.string(
            forKey: Keys.legacyExternalBookSearchURLTemplate
        ) ?? ""
        if storedToken != nil {
            UserDefaults.standard.removeObject(forKey: Keys.hardcoverToken)
        } else if let legacyToken,
                  secretStore.set(legacyToken, for: Self.hardcoverTokenAccount) {
            UserDefaults.standard.removeObject(forKey: Keys.hardcoverToken)
        }
    }

    func catalogAccess(
        for configuration: OPDSCatalogConfiguration
    ) -> OPDSCatalogAccess {
        OPDSCatalogAccess(
            configuration: configuration,
            credential: configuration.authenticationMode == .basic
                ? catalogCredential(for: configuration)
                : nil
        )
    }

    func catalogCredentialUsername(
        for configuration: OPDSCatalogConfiguration
    ) -> String? {
        catalogCredential(for: configuration)?.username
    }

    @discardableResult
    func setCatalogCredential(
        _ credential: OPDSBasicCredential?,
        for configuration: OPDSCatalogConfiguration
    ) -> Bool {
        guard let credential else {
            return secretStore.set(
                nil,
                for: configuration.resolvedCredentialKey
            )
        }
        guard credential.isValid,
              let data = try? JSONEncoder().encode(credential),
              let encoded = String(data: data, encoding: .utf8) else {
            return false
        }
        return secretStore.set(
            encoded,
            for: configuration.resolvedCredentialKey
        )
    }

    @discardableResult
    func saveCatalog(
        _ configuration: OPDSCatalogConfiguration,
        replacementCredential: OPDSBasicCredential? = nil
    ) -> Bool {
        var configuration = configuration
        if configuration.builtIn == .wikisource,
           let localized = localizedBuiltInCatalogs.first(
               where: { $0.builtIn == .wikisource }
           ) {
            configuration.name = localized.name
            configuration.rootURL = localized.rootURL
            configuration.authenticationMode = .none
            configuration.credentialKey = nil
            configuration.allowsInsecureHTTP = false
        }
        let trimmedName = configuration.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              configuration.rootURL.isOPDSHTTPURL else {
            return false
        }
        configuration.name = trimmedName
        configuration.credentialKey = configuration.resolvedCredentialKey

        if configuration.authenticationMode == .basic {
            guard !configuration.isHTTP else { return false }
            if let replacementCredential {
                guard setCatalogCredential(
                    replacementCredential,
                    for: configuration
                ) else {
                    return false
                }
            } else if catalogCredential(for: configuration) == nil {
                return false
            }
        } else {
            guard setCatalogCredential(nil, for: configuration) else {
                return false
            }
        }

        var catalogs = catalogConfigurations
        if let index = catalogs.firstIndex(where: {
            $0.id == configuration.id
        }) {
            catalogs[index] = configuration
        } else {
            configuration.displayOrder = catalogs.count
            catalogs.append(configuration)
        }
        catalogConfigurations = Self.normalizedCatalogs(
            catalogs,
            builtInDefaults: localizedBuiltInCatalogs
        )
        return true
    }

    @discardableResult
    func removeCatalog(id: String) -> Bool {
        guard let catalog = catalogConfigurations.first(where: {
            $0.id == id && !$0.isBuiltIn
        }) else {
            return false
        }
        guard setCatalogCredential(nil, for: catalog) else { return false }
        catalogConfigurations = Self.normalizedCatalogs(
            catalogConfigurations.filter { $0.id != id },
            builtInDefaults: localizedBuiltInCatalogs
        )
        return true
    }

    func moveCatalog(id: String, by offset: Int) {
        guard offset != 0,
              let source = catalogConfigurations.firstIndex(where: {
                  $0.id == id
              }) else {
            return
        }
        let destination = min(
            max(0, source + offset),
            catalogConfigurations.count - 1
        )
        guard source != destination else { return }
        var catalogs = catalogConfigurations
        let catalog = catalogs.remove(at: source)
        catalogs.insert(catalog, at: destination)
        for index in catalogs.indices {
            catalogs[index].displayOrder = index
        }
        catalogConfigurations = catalogs
    }

    func resetBuiltInCatalogs() {
        for catalog in catalogConfigurations where catalog.isBuiltIn {
            _ = setCatalogCredential(nil, for: catalog)
        }
        var catalogs = localizedBuiltInCatalogs
            + catalogConfigurations.filter { !$0.isBuiltIn }
        for index in catalogs.indices {
            catalogs[index].displayOrder = index
        }
        catalogConfigurations = catalogs
    }

    private func catalogCredential(
        for configuration: OPDSCatalogConfiguration
    ) -> OPDSBasicCredential? {
        guard let value = secretStore.string(
            for: configuration.resolvedCredentialKey
        ),
        let data = value.data(using: .utf8),
        let credential = try? JSONDecoder().decode(
            OPDSBasicCredential.self,
            from: data
        ),
        credential.isValid else {
            return nil
        }
        return credential
    }

    private var localizedBuiltInCatalogs: [OPDSCatalogConfiguration] {
        OPDSCatalogConfiguration.builtInDefaults(
            for: appLanguage,
            preferredLocalizations: Bundle.main.preferredLocalizations
        )
    }

    nonisolated private static func loadCatalogs(
        from defaults: UserDefaults,
        builtInDefaults: [OPDSCatalogConfiguration]
    ) -> [OPDSCatalogConfiguration] {
        let encoded = defaults.array(
            forKey: Keys.opdsCatalogConfigurations
        ) as? [Data] ?? []
        var decoded: [OPDSCatalogConfiguration] = []
        var seenIDs: Set<String> = []
        for data in encoded {
            guard var catalog = try? JSONDecoder().decode(
                OPDSCatalogConfiguration.self,
                from: data
            ),
            !catalog.id.isEmpty,
            !catalog.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
            catalog.rootURL.isOPDSHTTPURL,
            seenIDs.insert(catalog.id).inserted else {
                continue
            }
            if let builtIn = OPDSBuiltInCatalog.allCases.first(where: {
                $0.stableID == catalog.id
            }) {
                catalog.builtIn = builtIn
            } else {
                catalog.builtIn = nil
            }
            decoded.append(catalog)
        }
        return normalizedCatalogs(
            decoded,
            builtInDefaults: builtInDefaults
        )
    }

    nonisolated private static func normalizedCatalogs(
        _ catalogs: [OPDSCatalogConfiguration],
        builtInDefaults: [OPDSCatalogConfiguration]
    ) -> [OPDSCatalogConfiguration] {
        let defaultsByID = Dictionary(
            uniqueKeysWithValues: builtInDefaults.map { ($0.id, $0) }
        )
        var seenIDs: Set<String> = []
        var result = catalogs
            .filter { seenIDs.insert($0.id).inserted }
            .sorted {
                if $0.displayOrder != $1.displayOrder {
                    return $0.displayOrder < $1.displayOrder
                }
                return $0.id < $1.id
            }
        for index in result.indices
        where result[index].builtIn == .wikisource {
            guard let localized = defaultsByID[result[index].id] else {
                continue
            }
            result[index].name = localized.name
            result[index].rootURL = localized.rootURL
            result[index].authenticationMode = .none
            result[index].credentialKey = nil
            result[index].allowsInsecureHTTP = false
        }
        let existingIDs = Set(result.map(\.id))
        result.append(contentsOf:
            builtInDefaults.filter {
                !existingIDs.contains($0.id)
            }
        )
        for index in result.indices {
            result[index].displayOrder = index
        }
        return result
    }

    nonisolated private static func persistCatalogs(
        _ catalogs: [OPDSCatalogConfiguration],
        to defaults: UserDefaults
    ) {
        let encoded = catalogs.compactMap {
            try? JSONEncoder().encode($0)
        }
        defaults.set(encoded, forKey: Keys.opdsCatalogConfigurations)
    }
}
