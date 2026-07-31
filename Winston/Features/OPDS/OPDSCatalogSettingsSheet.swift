import SwiftUI

struct OPDSCatalogSettingsPane: View {
    @Environment(AppSettings.self) private var settings
    @Environment(OPDSViewModel.self) private var viewModel

    @State private var editorCatalog: OPDSCatalogConfiguration?
    @State private var removalCandidate: OPDSCatalogConfiguration?
    @State private var confirmsBuiltInReset = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("OPDS Catalogs")
                        .font(.headline)
                    Text(
                        "Add public or private catalogs, choose which ones participate in search, and control their order."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editorCatalog =
                        OPDSCatalogConfiguration.freshCustom(
                            displayOrder:
                                settings.catalogConfigurations.count
                        )
                } label: {
                    Label("Add Catalog", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(18)

            Divider()

            List {
                ForEach(settings.catalogConfigurations) { catalog in
                    OPDSCatalogSettingsRow(
                        catalog: catalog,
                        canMoveUp:
                            catalog.displayOrder > 0,
                        canMoveDown:
                            catalog.displayOrder
                                < settings.catalogConfigurations.count - 1,
                        onSetEnabled: {
                            var updated = catalog
                            updated.isEnabled = $0
                            if settings.saveCatalog(updated) {
                                viewModel
                                    .catalogConfigurationDidChange(
                                        id: catalog.id
                                    )
                            }
                        },
                        onEdit: {
                            editorCatalog = catalog
                        },
                        onMove: { offset in
                            settings.moveCatalog(
                                id: catalog.id,
                                by: offset
                            )
                        },
                        onRemove: {
                            removalCandidate = catalog
                        }
                    )
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Button("Reset Built-in Catalogs") {
                    confirmsBuiltInReset = true
                }
                .help(
                    "Restore the built-in addresses and ordering without deleting custom catalogs"
                )
                Spacer()
                Text(
                    "Passwords are stored in Keychain, never in catalog settings."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .sheet(item: $editorCatalog) { catalog in
            OPDSCatalogEditorSheet(catalog: catalog) { saved in
                viewModel.catalogConfigurationDidChange(id: saved.id)
                editorCatalog = nil
            }
        }
        .confirmationDialog(
            "Remove this catalog?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            )
        ) {
            Button("Remove Catalog", role: .destructive) {
                guard let catalog = removalCandidate else { return }
                if settings.removeCatalog(id: catalog.id) {
                    viewModel.catalogConfigurationDidChange(
                        id: catalog.id
                    )
                }
                removalCandidate = nil
            }
            Button("Cancel", role: .cancel) {
                removalCandidate = nil
            }
        } message: {
            Text(
                "The catalog and its Keychain credential will be removed. Books already imported from it stay in your library."
            )
        }
        .confirmationDialog(
            "Reset built-in catalogs?",
            isPresented: $confirmsBuiltInReset
        ) {
            Button("Reset Built-ins") {
                settings.resetBuiltInCatalogs()
                viewModel.catalogConfigurationsWereReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This restores the built-in addresses, enabled states, and order. Custom catalogs are kept."
            )
        }
    }
}

private struct OPDSCatalogSettingsRow: View {
    let catalog: OPDSCatalogConfiguration
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onSetEnabled: @MainActor @Sendable (Bool) -> Void
    let onEdit: @MainActor @Sendable () -> Void
    let onMove: @MainActor @Sendable (Int) -> Void
    let onRemove: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle(
                "Enable \(catalog.name)",
                isOn: Binding(
                    get: { catalog.isEnabled },
                    set: onSetEnabled
                )
            )
            .labelsHidden()
            .accessibilityLabel("Enable \(catalog.name)")

            Image(systemName: catalog.presentationSystemImage)
                .frame(width: 24)
                .foregroundStyle(
                    catalog.isEnabled
                        ? Color.accentColor
                        : Color.secondary
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: catalog.name)
                        .font(.body.weight(.semibold))
                    if catalog.isBuiltIn {
                        Text("Built-in")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if catalog.authenticationMode == .basic {
                        Label("Basic", systemImage: "lock.fill")
                            .font(.caption2)
                    }
                    if catalog.isHTTP {
                        Label(
                            "HTTP",
                            systemImage:
                                "exclamationmark.triangle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel(
                            "Insecure HTTP explicitly allowed"
                        )
                    }
                }
                Text(verbatim: catalog.rootURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button {
                    onMove(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!canMoveUp)
                .help("Move catalog up")

                Button {
                    onMove(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(!canMoveDown)
                .help("Move catalog down")

                Button("Edit", action: onEdit)

                if !catalog.isBuiltIn {
                    Button(
                        "Remove",
                        role: .destructive,
                        action: onRemove
                    )
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }
}

private struct OPDSCatalogEditorSheet: View {
    private enum HTTPAction {
        case save
        case test
    }

    let catalog: OPDSCatalogConfiguration
    let onSaved: (OPDSCatalogConfiguration) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var name = ""
    @State private var rootURL = ""
    @State private var authenticationMode: OPDSAuthenticationMode = .none
    @State private var username = ""
    @State private var password = ""
    @State private var isEnabled = true
    @State private var isTesting = false
    @State private var testResult: OPDSCatalogTestResult?
    @State private var testError: OPDSServiceError?
    @State private var saveFailed = false
    @State private var pendingHTTPAction: HTTPAction?

    private let service = OPDSService()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        catalog.isBuiltIn
                            ? "Edit Built-in Catalog"
                            : "Catalog Configuration"
                    )
                    .font(.title2.weight(.semibold))
                    Text(
                        "Test the configuration before saving. Testing never changes your catalog list."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                Form {
                    Section("Catalog") {
                        TextField("Name", text: $name)
                        TextField("Root URL", text: $rootURL)
                            .textContentType(.URL)
                        Toggle("Enabled", isOn: $isEnabled)

                        if draftURL?.scheme?.lowercased() == "http" {
                            Label(
                                "HTTP traffic is not encrypted. Winston will never send credentials to this catalog.",
                                systemImage:
                                    "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(
                                "Insecure HTTP warning. Traffic is not encrypted and credentials will not be sent."
                            )
                        }
                    }

                    Section("Authentication") {
                        Picker(
                            "Access",
                            selection: $authenticationMode
                        ) {
                            Text("Anonymous")
                                .tag(OPDSAuthenticationMode.none)
                            Text("HTTP Basic over HTTPS")
                                .tag(OPDSAuthenticationMode.basic)
                        }
                        .onChange(of: authenticationMode) {
                            testResult = nil
                            testError = nil
                        }

                        if authenticationMode == .basic {
                            TextField("Username", text: $username)
                            SecureField(
                                catalogHasCredential
                                    ? "New password (leave blank to keep)"
                                    : "Password",
                                text: $password
                            )
                            Text(
                                "The password is written directly to Keychain and is not shown again after saving."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        if authenticationMode == .basic,
                           draftURL?.scheme?.lowercased() != "https" {
                            Label(
                                "Basic authentication is available only for HTTPS catalogs.",
                                systemImage: "lock.slash"
                            )
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                    }

                    Section("Test Catalog") {
                        HStack {
                            Button {
                                requestTest()
                            } label: {
                                if isTesting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label(
                                        "Test Catalog",
                                        systemImage:
                                            "checkmark.circle"
                                    )
                                }
                            }
                            .disabled(!draftIsValid || isTesting)

                            if isTesting {
                                Text("Checking catalog capabilities…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let testResult {
                            OPDSCatalogTestResultView(
                                result: testResult
                            ) {
                                rootURL =
                                    testResult.resolvedRootURL
                                        .absoluteString
                                self.testResult = nil
                            }
                        } else if let testError {
                            OPDSCatalogTestErrorView(
                                error: testError,
                                suppliedCredential:
                                    suppliedCredential != nil
                            )
                        }
                    }

                    if saveFailed {
                        Label(
                            "The catalog could not be saved. Check the address and credentials, then try again.",
                            systemImage:
                                "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }
                .formStyle(.grouped)
                .padding(.vertical, 8)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Catalog") {
                    requestSave()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draftIsValid || isTesting)
            }
            .padding(16)
        }
        .frame(width: 620, height: 650)
        .task {
            name = catalog.name
            rootURL = catalog.rootURL.absoluteString
            authenticationMode = catalog.authenticationMode
            username =
                settings.catalogCredentialUsername(for: catalog)
                ?? ""
            isEnabled = catalog.isEnabled
        }
        .confirmationDialog(
            "Allow an insecure HTTP catalog?",
            isPresented: Binding(
                get: { pendingHTTPAction != nil },
                set: { if !$0 { pendingHTTPAction = nil } }
            )
        ) {
            Button("Allow HTTP") {
                let action = pendingHTTPAction
                pendingHTTPAction = nil
                switch action {
                case .save:
                    save(allowHTTP: true)
                case .test:
                    test(allowHTTP: true)
                case nil:
                    break
                }
            }
            Button("Cancel", role: .cancel) {
                pendingHTTPAction = nil
            }
        } message: {
            Text(
                "Traffic to this catalog is not encrypted and can be observed or changed in transit. Winston will not send Basic credentials over HTTP."
            )
        }
    }

    private var draftURL: URL? {
        let value = rootURL.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let url = URL(string: value),
              url.isOPDSHTTPURL else {
            return nil
        }
        return url
    }

    private var draftIsValid: Bool {
        guard !name.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty,
        let draftURL else {
            return false
        }
        if authenticationMode == .basic {
            return draftURL.scheme?.lowercased() == "https"
                && !username.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                && (catalogHasCredential || !password.isEmpty)
        }
        return true
    }

    private var catalogHasCredential: Bool {
        settings.catalogCredentialUsername(for: catalog) != nil
    }

    private var suppliedCredential: OPDSBasicCredential? {
        guard authenticationMode == .basic else { return nil }
        if !password.isEmpty {
            let value = OPDSBasicCredential(
                username: username,
                password: password
            )
            return value.isValid ? value : nil
        }
        return settings.catalogAccess(for: catalog).credential
    }

    private func configuration(
        allowHTTP: Bool
    ) -> OPDSCatalogConfiguration? {
        guard let draftURL else { return nil }
        var updated = catalog
        updated.name = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        updated.rootURL = draftURL
        updated.isEnabled = isEnabled
        updated.authenticationMode = authenticationMode
        updated.allowsInsecureHTTP =
            draftURL.scheme?.lowercased() == "http" && allowHTTP
        return updated
    }

    private func requestSave() {
        if draftURL?.scheme?.lowercased() == "http" {
            pendingHTTPAction = .save
        } else {
            save(allowHTTP: false)
        }
    }

    private func save(allowHTTP: Bool) {
        guard let configuration = configuration(
            allowHTTP: allowHTTP
        ) else {
            saveFailed = true
            return
        }
        let replacement =
            authenticationMode == .basic && !password.isEmpty
                ? suppliedCredential
                : nil
        guard settings.saveCatalog(
            configuration,
            replacementCredential: replacement
        ) else {
            saveFailed = true
            return
        }
        password = ""
        saveFailed = false
        onSaved(configuration)
    }

    private func requestTest() {
        if draftURL?.scheme?.lowercased() == "http" {
            pendingHTTPAction = .test
        } else {
            test(allowHTTP: false)
        }
    }

    private func test(allowHTTP: Bool) {
        guard let configuration = configuration(
            allowHTTP: allowHTTP
        ) else {
            return
        }
        testResult = nil
        testError = nil
        isTesting = true
        let access = OPDSCatalogAccess(
            configuration: configuration,
            credential: suppliedCredential
        )
        Task {
            defer { isTesting = false }
            do {
                testResult = try await service.testCatalog(
                    access: access
                )
            } catch let error as OPDSServiceError {
                testError = error
            } catch {
                testError = .network
            }
        }
    }
}

private struct OPDSCatalogTestResultView: View {
    let result: OPDSCatalogTestResult
    let useDiscoveredAddress: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Catalog test succeeded",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.callout.weight(.semibold))
            LabeledContent("Title", value: result.title)
            LabeledContent(
                "Resolved root",
                value: result.resolvedRootURL.absoluteString
            )
            LabeledContent(
                "Format",
                value: formatLabel
            )
            LabeledContent(
                "Browse",
                value: result.canBrowse
                    ? String(localized: "Available")
                    : String(localized: "No root entries")
            )
            LabeledContent(
                "Search",
                value: result.canSearch
                    ? String(localized: "Supported")
                    : String(localized: "Not advertised")
            )
            LabeledContent(
                "Root entries",
                value: "\(result.rootEntryCount)"
            )
            LabeledContent(
                "Import formats",
                value: result.supportedFormats.isEmpty
                    ? String(localized: "None observed")
                    : result.supportedFormats.joined(separator: ", ")
            )
            LabeledContent(
                "Transport",
                value: result.usesSecureTransport
                    ? String(localized: "HTTPS (encrypted)")
                    : String(localized: "HTTP (not encrypted)")
            )
            if result.discoveredRootURL != nil {
                Button(
                    "Use Discovered Address",
                    action: useDiscoveredAddress
                )
                .controlSize(.small)
            }
        }
        .font(.caption)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }

    private var formatLabel: String {
        switch result.documentFormat {
        case .opds1: "OPDS 1"
        case .opds2: "OPDS 2"
        case .atom: "Atom"
        }
    }
}

private struct OPDSCatalogTestErrorView: View {
    let error: OPDSServiceError
    let suppliedCredential: Bool

    var body: some View {
        Label(message, systemImage: "xmark.octagon.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityLabel("Catalog test failed. \(message)")
    }

    private var message: String {
        if error == .authenticationRequired {
            return suppliedCredential
                ? String(
                    localized: "Authentication failed. Check the username and password."
                )
                : String(
                    localized: "This catalog requires authentication. Enter a username and password."
                )
        }
        return error.description
    }
}
