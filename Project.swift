import ProjectDescription

private let mobiTypeIdentifier = "cz.annajung.Winston.mobi-ebook"
private let azw3TypeIdentifier = "cz.annajung.Winston.azw3-ebook"
private let kindleTypeDeclarations: Plist.Value = [
    [
        "UTTypeIdentifier": .string(mobiTypeIdentifier),
        "UTTypeDescription": "Mobipocket eBook",
        "UTTypeConformsTo": ["public.data"],
        "UTTypeTagSpecification": [
            "public.filename-extension": ["mobi", "azw"],
            "public.mime-type": ["application/x-mobipocket-ebook"],
        ],
    ],
    [
        "UTTypeIdentifier": .string(azw3TypeIdentifier),
        "UTTypeDescription": "Kindle AZW3 eBook",
        "UTTypeConformsTo": ["public.data"],
        "UTTypeTagSpecification": [
            "public.filename-extension": ["azw3"],
            "public.mime-type": ["application/vnd.amazon.ebook"],
        ],
    ],
]

private let appSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
    "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
    "SWIFT_INCLUDE_PATHS": "$(SRCROOT)/CLibMTP",
    "LIBRARY_SEARCH_PATHS": "$(inherited) /opt/homebrew/opt/libmtp/lib /opt/homebrew/opt/libusb/lib",
    "OTHER_LDFLAGS": "$(inherited) -lmtp",
    "ENABLE_APP_SANDBOX": "NO",
    "ENABLE_HARDENED_RUNTIME": "YES",
    // Sparkle's binary XCFramework and bundled Homebrew libraries do not ship arm64e.
    "ENABLE_POINTER_AUTHENTICATION": "NO",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
    "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": "4F4YMTN4C5",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "ENABLE_PREVIEWS": "YES",
    // extracts new String(localized:) keys into the catalog at build time
    "SWIFT_EMIT_LOC_STRINGS": "YES",
]

private let testSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    // @testable import Winston transitively needs the C module
    "SWIFT_INCLUDE_PATHS": "$(SRCROOT)/CLibMTP",
    // Test bundles must use the same architecture as their Winston host.
    "ENABLE_POINTER_AUTHENTICATION": "NO",
    "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": "4F4YMTN4C5",
]

private let quickLookSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
    "APPLICATION_EXTENSION_API_ONLY": "YES",
    "ENABLE_APP_SANDBOX": "YES",
    "ENABLE_USER_SELECTED_FILES": "readonly",
    "ENABLE_HARDENED_RUNTIME": "YES",
    // Keep the embedded extension architecture aligned with its Winston host.
    "ENABLE_POINTER_AUTHENTICATION": "NO",
    "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": "4F4YMTN4C5",
    "SKIP_INSTALL": "YES",
]

let project = Project(
    name: "Winston",
    packages: [
        .remote(url: "https://github.com/weichsel/ZIPFoundation.git",
                requirement: .upToNextMajor(from: "0.9.0")),
        // self-update; bundle-libmtp.sh must not touch Sparkle's signed XPC helpers
        .remote(url: "https://github.com/sparkle-project/Sparkle",
                requirement: .upToNextMajor(from: "2.6.0")),
    ],
    // Homebrew's libmtp/libusb ship arm64 only, so a universal Release build can never
    // link — Apple Silicon is the only architecture this app can be built for.
    settings: .settings(base: [
        "MACOSX_DEPLOYMENT_TARGET": "26.4",
        "ARCHS": "arm64",
        "ENABLE_ENHANCED_SECURITY": "YES",
        // single source of truth for the app + QuickLook extension versions
        "MARKETING_VERSION": "0.1",
        "CURRENT_PROJECT_VERSION": "1",
    ]),
    targets: [
        .target(
            name: "Winston",
            destinations: .macOS,
            product: .app,
            bundleId: "cz.annajung.Winston",
            deploymentTargets: .macOS("26.4"),
            infoPlist: .extendingDefault(with: [
                // Tuist's default plist hardcodes 1.0; route it through the build settings
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NSHumanReadableCopyright": "Copyright © 2026 Anna Jungmannová. All rights reserved.",
                "CFBundleHelpBookFolder": "WinstonHelp.help",
                "CFBundleHelpBookName": "cz.annajung.Winston.helpbook",
                "CFBundleDevelopmentRegion": "en",
                "CFBundleLocalizations": .array([.string("en"), .string("cs")]),
                "UTImportedTypeDeclarations": kindleTypeDeclarations,
                // The private half of SUPublicEDKey lives in the login Keychain — losing
                // it means existing users can't accept updates. TODO: point SUFeedURL at
                // the real appcast before distributing (example.com is a placeholder).
                "SUFeedURL": "https://updates.example.com/winston/appcast.xml",
                "SUPublicEDKey": "dVfH2PNHpcWAwFk1ZXq+7voajLGyew9fPAOGex+j8uU=",
            ]),
            sources: ["Winston/**/*.swift"],
            resources: [
                "Winston/Assets.xcassets",
                // Icon Composer icon. A legacy .appiconset is drawn "legacy": macOS 26 insets
                // it into its own glass tile, so the artwork never fills the Dock tile.
                "Winston/AppIcon.icon",
                "Winston/Resources/Localizable.xcstrings",
                .folderReference(path: "Winston/Help/WinstonHelp.help"),
            ],
            entitlements: .dictionary([
                "com.apple.security.hardened-process": true,
                "com.apple.security.hardened-process.enhanced-security-version-string": "2",
                "com.apple.security.hardened-process.hardened-heap": true,
                "com.apple.security.hardened-process.dyld-ro": true,
                "com.apple.security.hardened-process.platform-restrictions-string": "2",
            ]),
            scripts: [
                .post(
                    path: "Scripts/bundle-libmtp.sh",
                    name: "Bundle libmtp",
                    basedOnDependencyAnalysis: false
                ),
            ],
            dependencies: [
                .target(name: "WinstonQuickLook"),
                .package(product: "ZIPFoundation"),
                .package(product: "Sparkle"),
            ],
            settings: .settings(base: appSettings)
        ),
        .target(
            name: "WinstonQuickLook",
            destinations: .macOS,
            product: .appExtension,
            bundleId: "cz.annajung.Winston.QuickLook",
            deploymentTargets: .macOS("26.4"),
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "CFBundleDisplayName": "Winston Quick Look",
                "CFBundleDevelopmentRegion": "en",
                "UTImportedTypeDeclarations": kindleTypeDeclarations,
                "NSExtension": [
                    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).PreviewProvider",
                    "NSExtensionPointIdentifier": "com.apple.quicklook.preview",
                    "NSExtensionAttributes": [
                        "QLSupportedContentTypes": [
                            .string(mobiTypeIdentifier),
                            .string(azw3TypeIdentifier),
                        ],
                        "QLSupportsSearchableItems": false,
                        "QLIsDataBasedPreview": true,
                    ],
                ],
            ]),
            sources: [
                "WinstonQuickLook/**/*.swift",
                "Winston/Core/Metadata/Data+BinaryReading.swift",
                "Winston/Core/Metadata/MOBIIdentifiers.swift",
                "Winston/Core/Metadata/MOBICoverExtractor.swift",
                "Winston/Core/Metadata/KindleQuickLookPreview.swift",
            ],
            entitlements: .dictionary([
                "com.apple.security.app-sandbox": true,
                "com.apple.security.files.user-selected.read-only": true,
            ]),
            settings: .settings(base: quickLookSettings)
        ),
        .target(
            name: "WinstonTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "cz.annajung.WinstonTests",
            deploymentTargets: .macOS("26.4"),
            sources: ["WinstonTests/**/*.swift"],
            dependencies: [
                .target(name: "Winston"),
                .package(product: "ZIPFoundation"),
            ],
            settings: .settings(base: testSettings)
        ),
        .target(
            name: "WinstonUITests",
            destinations: .macOS,
            product: .uiTests,
            bundleId: "cz.annajung.WinstonUITests",
            deploymentTargets: .macOS("26.4"),
            sources: ["WinstonUITests/**/*.swift"],
            dependencies: [.target(name: "Winston")],
            settings: .settings(base: testSettings)
        ),
    ]
)
