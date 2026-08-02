import Foundation
import Testing
@testable import Winston

@MainActor
@Suite(.serialized)
struct OPDSCatalogConfigurationTests {
    @Test func `Fresh settings seed stable built-in catalogs`() {
        let fixture = SettingsFixture()

        #expect(fixture.settings.catalogConfigurations.map(\.id) == [
            OPDSBuiltInCatalog.projectGutenberg.stableID,
            OPDSBuiltInCatalog.standardEbooks.stableID,
            OPDSBuiltInCatalog.unglueIt.stableID,
            OPDSBuiltInCatalog.wikisource.stableID,
        ])
    }

    @Test func `Custom catalog survives reload and rename keeps identity`() throws {
        let fixture = SettingsFixture()
        var custom = OPDSCatalogConfiguration(
            id: "custom.private-library",
            name: "Private Library",
            rootURL: try #require(
                URL(string: "https://catalog.example/opds")
            ),
            displayOrder: 2
        )
        #expect(fixture.settings.saveCatalog(custom))

        custom.name = "Renamed Library"
        #expect(fixture.settings.saveCatalog(custom))
        let reloaded = AppSettings(
            secretStore: fixture.secrets,
            defaults: fixture.defaults
        )
        let saved = try #require(
            reloaded.catalogConfigurations.first {
                $0.id == custom.id
            }
        )

        #expect(saved.name == "Renamed Library")
        #expect(saved.id == "custom.private-library")
        #expect(saved.resolvedCredentialKey ==
            "opds-catalog-credential.custom.private-library")
    }

    @Test func `Malformed record does not discard valid catalogs`() throws {
        let fixture = SettingsFixture()
        let valid = OPDSCatalogConfiguration(
            id: "custom.valid",
            name: "Valid",
            rootURL: try #require(
                URL(string: "https://valid.example/opds")
            ),
            displayOrder: 2
        )
        let encoded = try JSONEncoder().encode(valid)
        fixture.defaults.set(
            [Data("not-json".utf8), encoded],
            forKey: "opdsCatalogConfigurations"
        )

        let reloaded = AppSettings(
            secretStore: fixture.secrets,
            defaults: fixture.defaults
        )

        #expect(reloaded.catalogConfigurations.contains {
            $0.id == valid.id
        })
        #expect(reloaded.catalogConfigurations.filter(\.isBuiltIn).count == 4)
    }

    @Test(arguments: [
        (AppLanguage.czech, ["en"], "Česká Wikisource", "cs"),
        (AppLanguage.english, ["cs"], "English Wikisource", "en"),
        (AppLanguage.system, ["cs-CZ", "en"], "Česká Wikisource", "cs"),
        (AppLanguage.system, ["de-DE"], "English Wikisource", "en"),
    ])
    func `Wikisource follows effective application language with English fallback`(
        language: AppLanguage,
        preferredLocalizations: [String],
        expectedName: String,
        expectedCode: String
    ) throws {
        let catalogs = OPDSCatalogConfiguration.builtInDefaults(
            for: language,
            preferredLocalizations: preferredLocalizations
        )
        let wikisource = try #require(catalogs.first {
            $0.builtIn == .wikisource
        })

        #expect(wikisource.id == OPDSBuiltInCatalog.wikisource.stableID)
        #expect(wikisource.name == expectedName)
        #expect(wikisource.rootURL.host == "\(expectedCode).wikisource.org")
    }

    @Test func `Changing application language updates the stable Wikisource built-in`() throws {
        let fixture = SettingsFixture()
        let originalLanguage = fixture.settings.appLanguage
        defer { fixture.settings.appLanguage = originalLanguage }

        fixture.settings.appLanguage = .czech
        let czech = try #require(
            fixture.settings.catalogConfigurations.first {
                $0.builtIn == .wikisource
            }
        )
        #expect(czech.id == OPDSBuiltInCatalog.wikisource.stableID)
        #expect(czech.name == "Česká Wikisource")
        #expect(czech.rootURL.host == "cs.wikisource.org")

        fixture.settings.appLanguage = .english
        let english = try #require(
            fixture.settings.catalogConfigurations.first {
                $0.builtIn == .wikisource
            }
        )
        #expect(english.id == czech.id)
        #expect(english.name == "English Wikisource")
        #expect(english.rootURL.host == "en.wikisource.org")
    }

    @Test func `Unglue built-in uses the documented OPDS root and title search`() throws {
        let unglue = try #require(
            OPDSCatalogConfiguration.builtInDefaults.first {
                $0.builtIn == .unglueIt
            }
        )

        #expect(unglue.rootURL.absoluteString == "https://unglue.it/api/opds/")
        guard case .template(let template) = unglue.builtInSearchLink else {
            Issue.record("Expected the documented Unglue.it title-search template.")
            return
        }
        #expect(template == "https://unglue.it/api/opds/s.{searchTerms}/")
    }

    @Test func `Deleting custom catalog deletes credential`() throws {
        let fixture = SettingsFixture()
        let catalog = OPDSCatalogConfiguration(
            id: "custom.secure",
            name: "Secure",
            rootURL: try #require(
                URL(string: "https://secure.example/opds")
            ),
            displayOrder: 2,
            authenticationMode: .basic
        )
        let credential = OPDSBasicCredential(
            username: "reader",
            password: "top-secret"
        )
        #expect(fixture.settings.saveCatalog(
            catalog,
            replacementCredential: credential
        ))
        #expect(fixture.secrets.string(
            for: catalog.resolvedCredentialKey
        ) != nil)

        #expect(fixture.settings.removeCatalog(id: catalog.id))
        #expect(fixture.secrets.string(
            for: catalog.resolvedCredentialKey
        ) == nil)
    }

    @Test func `Malformed credential is ignored without exposing text`() throws {
        let fixture = SettingsFixture()
        let catalog = OPDSCatalogConfiguration(
            id: "custom.malformed-secret",
            name: "Secure",
            rootURL: try #require(
                URL(string: "https://secure.example/opds")
            ),
            authenticationMode: .basic
        )
        fixture.secrets.set(
            #"{"username":"reader","password":}"#,
            for: catalog.resolvedCredentialKey
        )

        #expect(
            fixture.settings.catalogAccess(for: catalog).credential == nil
        )
    }
}

@MainActor
private struct SettingsFixture {
    let suiteName = "OPDSCatalogConfigurationTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let secrets = TestCatalogSecretStore()
    let settings: AppSettings

    init() {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        self.defaults = defaults
        settings = AppSettings(
            secretStore: secrets,
            defaults: defaults
        )
    }
}

private final class TestCatalogSecretStore:
    SecretStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(for account: String) -> String? {
        lock.withLock { values[account] }
    }

    @discardableResult
    func set(_ value: String?, for account: String) -> Bool {
        lock.withLock {
            values[account] = value
        }
        return true
    }
}
