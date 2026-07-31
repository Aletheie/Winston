import Foundation
import Testing
@testable import Winston

@Suite
struct OPDSAuthenticationTests {
    private let credential = OPDSBasicCredential(
        username: "reader",
        password: "never-log-this"
    )

    @Test func `Basic authentication is limited to exact HTTPS origin`() throws {
        let policy = try securePolicy()

        let sameOrigin = try policy.request(
            for: try #require(
                URL(string: "https://catalog.example/books/1")
            )
        )
        let otherHost = try policy.request(
            for: try #require(
                URL(string: "https://downloads.example/book.epub")
            )
        )
        let otherPort = try policy.request(
            for: try #require(
                URL(string: "https://catalog.example:8443/opds")
            )
        )

        #expect(
            sameOrigin.value(forHTTPHeaderField: "Authorization")?
                .hasPrefix("Basic ") == true
        )
        #expect(
            otherHost.value(forHTTPHeaderField: "Authorization") == nil
        )
        #expect(
            otherPort.value(forHTTPHeaderField: "Authorization") == nil
        )
    }

    @Test func `Credentials are never sent over HTTP`() throws {
        var configuration = try secureConfiguration()
        configuration.rootURL = try #require(
            URL(string: "http://catalog.example/opds")
        )
        configuration.allowsInsecureHTTP = true
        let policy = OPDSRequestPolicy(access: OPDSCatalogAccess(
            configuration: configuration,
            credential: credential
        ))

        #expect(throws: OPDSServiceError.insecureTransport) {
            try policy.request(for: configuration.rootURL)
        }
    }

    @Test func `Anonymous HTTP requires explicit allowance and has no auth`() throws {
        let url = try #require(
            URL(string: "http://catalog.example/opds")
        )
        let configuration = OPDSCatalogConfiguration(
            id: "custom.http",
            name: "HTTP",
            rootURL: url,
            authenticationMode: .none,
            allowsInsecureHTTP: true
        )
        let request = try OPDSRequestPolicy(
            access: OPDSCatalogAccess(
                configuration: configuration,
                credential: nil
            )
        ).request(for: url)

        #expect(
            request.value(forHTTPHeaderField: "Authorization") == nil
        )
    }

    @Test func `HTTPS downgrade is rejected`() throws {
        let policy = try securePolicy()
        let proposed = URLRequest(
            url: try #require(
                URL(string: "http://catalog.example/opds")
            )
        )

        #expect(throws: OPDSServiceError.insecureRedirect) {
            try policy.redirectedRequest(
                from: try #require(
                    URL(string: "https://catalog.example/opds")
                ),
                proposedRequest: proposed
            )
        }
    }

    @Test func `Cross-origin redirect strips authorization`() throws {
        let policy = try securePolicy()
        var proposed = URLRequest(
            url: try #require(
                URL(string: "https://cdn.example/book.epub")
            )
        )
        proposed.setValue(
            "Basic leaked-value",
            forHTTPHeaderField: "Authorization"
        )

        let redirected = try policy.redirectedRequest(
            from: try #require(
                URL(string: "https://catalog.example/book.epub")
            ),
            proposedRequest: proposed
        )

        #expect(
            redirected.value(forHTTPHeaderField: "Authorization") == nil
        )
    }

    @Test func `Error descriptions contain no credential text`() {
        for error in [
            OPDSServiceError.authenticationRequired,
            .unsupportedCrossOriginAuthentication,
            .insecureTransport,
            .insecureRedirect,
            .network,
        ] {
            #expect(!error.description.contains(credential.username))
            #expect(!error.description.contains(credential.password))
        }
    }

    private func securePolicy() throws -> OPDSRequestPolicy {
        OPDSRequestPolicy(access: OPDSCatalogAccess(
            configuration: try secureConfiguration(),
            credential: credential
        ))
    }

    private func secureConfiguration()
        throws -> OPDSCatalogConfiguration {
        OPDSCatalogConfiguration(
            id: "custom.secure",
            name: "Secure",
            rootURL: try #require(
                URL(string: "https://catalog.example/opds")
            ),
            authenticationMode: .basic
        )
    }
}
