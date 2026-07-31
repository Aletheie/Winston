import Foundation

nonisolated enum OPDSBuiltInCatalog: String, Codable, Sendable, CaseIterable {
    case projectGutenberg = "project-gutenberg"
    case standardEbooks = "standard-ebooks"

    var stableID: String {
        "builtin.\(rawValue)"
    }
}

nonisolated enum OPDSAuthenticationMode: String, Codable, Sendable, CaseIterable {
    case none
    case basic
}

nonisolated struct OPDSBasicCredential: Codable, Equatable, Sendable {
    let username: String
    let password: String

    var isValid: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }
}

nonisolated struct OPDSCatalogConfiguration:
    Codable,
    Hashable,
    Identifiable,
    Sendable
{
    let id: String
    var name: String
    var rootURL: URL
    var isEnabled: Bool
    var displayOrder: Int
    var builtIn: OPDSBuiltInCatalog?
    var authenticationMode: OPDSAuthenticationMode
    var credentialKey: String?
    var allowsInsecureHTTP: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        rootURL: URL,
        isEnabled: Bool = true,
        displayOrder: Int = 0,
        builtIn: OPDSBuiltInCatalog? = nil,
        authenticationMode: OPDSAuthenticationMode = .none,
        credentialKey: String? = nil,
        allowsInsecureHTTP: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.isEnabled = isEnabled
        self.displayOrder = displayOrder
        self.builtIn = builtIn
        self.authenticationMode = authenticationMode
        self.credentialKey = credentialKey
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }

    var resolvedCredentialKey: String {
        credentialKey ?? "opds-catalog-credential.\(id)"
    }

    var isBuiltIn: Bool {
        builtIn != nil
    }

    var isHTTP: Bool {
        rootURL.scheme?.lowercased() == "http"
    }

    static let builtInDefaults: [OPDSCatalogConfiguration] = [
        OPDSCatalogConfiguration(
            id: OPDSBuiltInCatalog.projectGutenberg.stableID,
            name: "Project Gutenberg",
            rootURL: URL(string: "https://www.gutenberg.org/ebooks.opds/")!,
            displayOrder: 0,
            builtIn: .projectGutenberg
        ),
        OPDSCatalogConfiguration(
            id: OPDSBuiltInCatalog.standardEbooks.stableID,
            name: "Standard Ebooks",
            rootURL: URL(
                string: "https://standardebooks.org/feeds/atom/new-releases"
            )!,
            displayOrder: 1,
            builtIn: .standardEbooks
        ),
    ]

    static func freshCustom(displayOrder: Int) -> OPDSCatalogConfiguration {
        OPDSCatalogConfiguration(
            name: "",
            rootURL: URL(string: "https://example.com/opds")!,
            isEnabled: true,
            displayOrder: displayOrder
        )
    }
}

nonisolated struct OPDSOrigin: Codable, Equatable, Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}

nonisolated struct OPDSCatalogAccess: Sendable {
    let configuration: OPDSCatalogConfiguration
    let credential: OPDSBasicCredential?

    var credentialOrigin: OPDSOrigin? {
        guard configuration.authenticationMode == .basic,
              configuration.rootURL.scheme?.lowercased() == "https",
              credential?.isValid == true else {
            return nil
        }
        return OPDSOrigin(url: configuration.rootURL)
    }

    var catalogID: String {
        configuration.id
    }
}

nonisolated struct CatalogSearchSeed: Equatable, Sendable {
    let title: String
    let author: String?
    let isbn: String?
    let context: String?

    init(
        title: String,
        author: String?,
        isbn: String? = nil,
        context: String? = nil
    ) {
        self.title = title
        self.author = author
        self.isbn = isbn
        self.context = context
    }

    var query: String {
        if let canonicalISBN = MetadataNormalizer.canonicalISBN13(isbn) {
            return canonicalISBN
        }
        return [title, author]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension CatalogSearchSeed {
    @MainActor
    init(book: Book) {
        self.init(
            title: book.displayTitle,
            author: book.displayAuthor,
            isbn: book.isbn,
            context: nil
        )
    }

    @MainActor
    init(wishlistItem: WishlistItem) {
        self.init(
            title: wishlistItem.title,
            author: wishlistItem.author,
            context: String(localized: "Wishlist")
        )
    }

    @MainActor
    init(notice: LibraryNotice) {
        self.init(
            title: notice.bookTitle,
            author: notice.author,
            context: notice.seriesName
        )
    }

    nonisolated init(
        seriesBook: HardcoverSeriesBook,
        seriesName: String
    ) {
        let position = seriesBook.positionText
            ?? seriesBook.position.map {
                $0.formatted(
                    .number.precision(.fractionLength(0...2))
                )
            }
        self.init(
            title: seriesBook.title,
            author: seriesBook.authors.first,
            context: [
                seriesName,
                position.map { String(localized: "Book \($0)") },
            ]
            .compactMap { $0 }
            .joined(separator: " · ")
        )
    }
}

@MainActor
enum CatalogSearchRouter {
    static func open(_ seed: CatalogSearchSeed) {
        NotificationCenter.default.post(
            name: .showCatalogsDestination,
            object: seed
        )
    }
}

nonisolated extension OPDSCatalogConfiguration {
    var presentationShortcuts: [OPDSNavigationItem] {
        guard builtIn == .projectGutenberg else { return [] }
        return [
            OPDSNavigationItem(
                title: String(localized: "Czech books"),
                subtitle: String(
                    localized: "Project Gutenberg books in Czech"
                ),
                url: URL(
                    string: "https://www.gutenberg.org/ebooks/search.opds/?query=l.cs"
                )!,
                coverURL: nil
            ),
            OPDSNavigationItem(
                title: String(localized: "All books"),
                subtitle: String(
                    localized: "Browse the complete Project Gutenberg catalog"
                ),
                url: URL(
                    string: "https://www.gutenberg.org/ebooks/search.opds/"
                )!,
                coverURL: nil
            ),
        ]
    }

    var presentationSystemImage: String {
        switch builtIn {
        case .projectGutenberg:
            "text.book.closed.fill"
        case .standardEbooks:
            "book.pages.fill"
        case nil:
            "books.vertical.fill"
        }
    }
}
