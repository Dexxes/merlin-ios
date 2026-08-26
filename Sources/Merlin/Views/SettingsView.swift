import SwiftUI
import WebKit

struct SettingsView: View {
    // Callback wird nach erfolgreichem Login aufgerufen, nachdem dismiss() schon
    // ausgelöst wurde — für optionale Nachbereitung im aufrufenden View.
    var onLoginSuccess: (() -> Void)? = nil


    @Environment(\.dismiss) private var dismiss

    @State private var backendKind   = CredentialsStore.shared.backendKind
    @State private var nextcloudUrl  = CredentialsStore.shared.nextcloudUrl.isEmpty
                                         ? "https://"
                                         : CredentialsStore.shared.nextcloudUrl
    @State private var username      = CredentialsStore.shared.username
    @State private var appPassword   = CredentialsStore.shared.appPassword
    @State private var defaultFilter  = PreferencesStore.shared.defaultFilter
    @State private var progressEdge   = PreferencesStore.shared.progressEdge
    @State private var saveProgress   = PreferencesStore.shared.saveProgress
    @State private var resumeOnOpen   = PreferencesStore.shared.resumeOnOpen
    @State private var prefetchWifiOnly      = PreferencesStore.shared.prefetchImagesOnWifiOnly
    /// Slider braucht Double; Persistenz erfolgt als Int (siehe PreferencesStore.cacheRetentionDays).
    @State private var cacheRetentionDays    = Double(PreferencesStore.shared.cacheRetentionDays)
    @AppStorage("merlin_developer_mode") private var developerMode: Bool = false
    @State private var isTesting              = false
    @State private var showClearCacheConfirm  = false
    @State private var showLogoutConfirm      = false
    @State private var cacheCleared           = false
    @State private var testResult: TestResult? = nil
    @State private var serverStorageUsage: MerlinAPI.StorageUsage? = nil
    @State private var serverStorageError     = false
    @State private var localCacheBytes: Int64? = nil
    @FocusState private var focusedField: Field?

    @StateObject private var loginFlow   = LoginFlowService()
    @State private var isPolling         = false
    @State private var loginFlowError: String? = nil
    @State private var showLoginSuccess  = false
    @State private var keychainDebugInfo: String? = nil
    @State private var pollTask: Task<Void, Never>? = nil
    @State private var safariLoginURL: IdentifiableURL? = nil
    @State private var showSiteCredentials = false

    enum Field { case url, username, password }
    enum TestResult { case success(String), failure(String) }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Login Flow
                Section {
                    Picker("Backend", selection: $backendKind) {
                        Text("Nextcloud").tag(CredentialsStore.BackendKind.nextcloud)
                        Text("Standalone-Server").tag(CredentialsStore.BackendKind.standalone)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: backendKind) { _, newValue in
                        CredentialsStore.shared.backendKind = newValue
                    }

                    LabeledContent(L("settings.account.urlLabel")) {
                        TextField(L("settings.account.urlPlaceholder"), text: $nextcloudUrl)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .url)
                            .onSubmit { saveURL() }
                    }

                    Button {
                        saveURL()
                        startLoginFlow()
                    } label: {
                        HStack {
                            Label(L("settings.account.loginButton"), systemImage: "arrow.right.circle")
                            Spacer()
                            if loginFlow.isLoading {
                                ProgressView().progressViewStyle(.circular)
                            }
                        }
                    }
                    .disabled(nextcloudUrl.isEmpty || nextcloudUrl == "https://" || loginFlow.isLoading || isPolling)

                    if isPolling {
                        HStack(spacing: 8) {
                            ProgressView().progressViewStyle(.circular)
                            Text(L("settings.account.waitingForBrowser"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(L("common.cancel"), role: .cancel) { cancelLoginFlow() }
                                .font(.footnote)
                        }
                    }

                    if showLoginSuccess {
                        Label(L("settings.account.loggedInSuccess"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    }

                    if CredentialsStore.shared.isConfigured {
                        Button(role: .destructive) {
                            showLogoutConfirm = true
                        } label: {
                            Label(L("common.logout"), systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .confirmationDialog(
                            L("settings.account.logoutDialogTitle"),
                            isPresented: $showLogoutConfirm,
                            titleVisibility: .visible
                        ) {
                            Button(L("common.logout"), role: .destructive) { logout() }
                            Button(L("common.cancel"), role: .cancel) {}
                        } message: {
                            Text(L("settings.account.logoutDialogMessage"))
                        }
                    }

                    if developerMode, let info = keychainDebugInfo {
                        Text(info)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(8)
                            .background(Color(.systemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    if let err = loginFlowError {
                        Label(err, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                } header: {
                    Text(L("settings.account.sectionHeader"))
                } footer: {
                    Text(L("settings.account.footer"))
                }

                // MARK: - Test Connection
                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Label(L("settings.testConnection.button"), systemImage: "network")
                            Spacer()
                            if isTesting { ProgressView().progressViewStyle(.circular) }
                        }
                    }
                    .disabled(isTesting || !CredentialsStore.shared.isConfigured)

                    if let result = testResult {
                        switch result {
                        case .success(let msg):
                            Label(msg, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.footnote)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red).font(.footnote)
                        }
                    }
                }

                // MARK: - Paywall-Abos
                Section {
                    Button {
                        showSiteCredentials = true
                    } label: {
                        Label(L("settings.paywall.rowTitle"), systemImage: "lock.shield")
                    }
                } footer: {
                    Text(L("settings.paywall.footer"))
                }
                .sheet(isPresented: $showSiteCredentials) {
                    SiteCredentialsView()
                }

                // MARK: - App preferences
                Section {
                    Picker(L("settings.preferences.defaultViewLabel"), selection: $defaultFilter) {
                        ForEach(ArticleFilter.allCases) { filter in
                            Label(filter.label, systemImage: filter.systemImage)
                                .tag(filter)
                        }
                    }
                    .onChange(of: defaultFilter) { _, new in
                        PreferencesStore.shared.defaultFilter = new
                        syncPreferences()
                    }
                    Picker(L("settings.preferences.progressBarLabel"), selection: $progressEdge) {
                        ForEach(ProgressEdge.allCases, id: \.self) { edge in
                            Label(edge.label, systemImage: edge.systemImage)
                                .tag(edge)
                        }
                    }
                    .onChange(of: progressEdge) { _, new in
                        PreferencesStore.shared.progressEdge = new
                        syncPreferences()
                    }
                    Toggle(L("settings.preferences.saveProgressLabel"), isOn: $saveProgress)
                        .onChange(of: saveProgress) { _, new in
                            PreferencesStore.shared.saveProgress = new
                            syncPreferences()
                        }
                    Toggle(L("settings.preferences.resumeOnOpenLabel"), isOn: $resumeOnOpen)
                        .onChange(of: resumeOnOpen) { _, new in
                            PreferencesStore.shared.resumeOnOpen = new
                            syncPreferences()
                        }
                } header: {
                    Text(L("settings.preferences.sectionHeader"))
                } footer: {
                    Text(L("settings.preferences.footer"))
                }

                // MARK: - Cache
                Section {
                    Toggle(L("settings.cache.wifiOnlyToggle"), isOn: $prefetchWifiOnly)
                        .onChange(of: prefetchWifiOnly) { _, new in
                            PreferencesStore.shared.prefetchImagesOnWifiOnly = new
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("settings.cache.retentionLabel"))
                        Slider(value: $cacheRetentionDays, in: 0...365, step: 1)
                            .onChange(of: cacheRetentionDays) { _, new in
                                PreferencesStore.shared.cacheRetentionDays = Int(new)
                            }
                        Text(cacheRetentionDays == 0
                             ? L("settings.cache.retentionOff")
                             : String(format: L("settings.cache.retentionDaysFormat"), Int(cacheRetentionDays)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        showClearCacheConfirm = true
                    } label: {
                        Label(L("settings.cache.clearButton"), systemImage: "trash")
                    }
                    .confirmationDialog(
                        L("settings.cache.clearDialogTitle"),
                        isPresented: $showClearCacheConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(L("settings.cache.clearDialogConfirm"), role: .destructive) { clearCache() }
                        Button(L("common.cancel"), role: .cancel) {}
                    } message: {
                        Text(L("settings.cache.clearDialogMessage"))
                    }

                    if cacheCleared {
                        Label(L("settings.cache.clearedSuccess"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    }
                } header: {
                    Text(L("settings.cache.sectionHeader"))
                } footer: {
                    Text(L("settings.cache.footer"))
                }

                // MARK: - Storage
                Section {
                    LabeledContent(L("settings.storage.serverLabel")) {
                        if let usage = serverStorageUsage {
                            Text(Self.byteFormatter.string(fromByteCount: Int64(usage.totalBytes)))
                                .foregroundStyle(.secondary)
                        } else if serverStorageError {
                            Text(L("settings.storage.loadError"))
                                .font(.footnote)
                                .foregroundStyle(.red)
                        } else if CredentialsStore.shared.isConfigured {
                            ProgressView().progressViewStyle(.circular)
                        } else {
                            Text("–").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent(L("settings.storage.localLabel")) {
                        if let bytes = localCacheBytes {
                            Text(Self.byteFormatter.string(fromByteCount: bytes))
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().progressViewStyle(.circular)
                        }
                    }
                } header: {
                    Text(L("settings.storage.sectionHeader"))
                } footer: {
                    Text(L("settings.storage.footer"))
                }

                // MARK: - About
                Section {
                    HStack {
                        Text(L("settings.about.versionLabel"))
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(L("settings.about.commitLabel"))
                        Spacer()
                        Text(BuildInfo.commit)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L("settings.about.sectionHeader"))
                }

                // MARK: - Developer
                Section {
                    Toggle(isOn: $developerMode) {
                        Label(L("settings.developer.modeToggle"), systemImage: "hammer")
                    }
                    if developerMode {
                        CredentialDebugView()
                    }
                } header: {
                    Text(L("settings.developer.sectionHeader"))
                }
            }
            .navigationTitle(L("common.settings"))
            .navigationBarTitleDisplayMode(.inline)
            // fullScreenCover statt sheet — nested sheets auf iOS können
            // dazu führen dass beim Schließen des inneren Sheets der äußere
            // mitgeschlossen wird.
            .fullScreenCover(item: $safariLoginURL) { item in
                SafariLoginView(url: item.url)
                    .ignoresSafeArea()
            }
            .task { await loadStorageUsage() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
        }
    }

    // MARK: - Login Flow

    // MARK: - Auto-save helpers

    private func saveURL() {
        CredentialsStore.shared.nextcloudUrl = nextcloudUrl
    }

    private func syncPreferences() {
        Task {
            do {
                try await MerlinAPI.shared.updateSettings(PreferencesStore.shared.toServerDict())
            } catch {
                if case MerlinAPIError.networkError = error {
                    // Offline — SettingsSyncQueue retries with the latest
                    // local state once connectivity returns, so the change
                    // isn't silently lost for other devices.
                    SettingsSyncQueue.shared.markDirty()
                }
            }
        }
    }

    // MARK: - Login Flow

    private func startLoginFlow() {
        loginFlowError   = nil
        showLoginSuccess = false

        let serverUrl = nextcloudUrl
        pollTask = Task {
            do {
                let loginUrl = try await loginFlow.start(serverUrl: serverUrl)
                safariLoginURL = IdentifiableURL(url: loginUrl)

                isPolling = true
                try await loginFlow.pollForCredentials()
                // Credentials are now in CredentialsStore — update local state for display
                nextcloudUrl = CredentialsStore.shared.nextcloudUrl
                username     = CredentialsStore.shared.username
                appPassword  = CredentialsStore.shared.appPassword
                isPolling    = false
                safariLoginURL = nil

                // Pull preferences from server and update local state
                if let serverSettings = try? await MerlinAPI.shared.getSettings() {
                    PreferencesStore.shared.loadFromServer(serverSettings)
                    defaultFilter    = PreferencesStore.shared.defaultFilter
                    progressEdge     = PreferencesStore.shared.progressEdge
                    saveProgress     = PreferencesStore.shared.saveProgress
                    resumeOnOpen     = PreferencesStore.shared.resumeOnOpen
                    prefetchWifiOnly = PreferencesStore.shared.prefetchImagesOnWifiOnly
                }

                // Debug: direkt nach dem Speichern prüfen ob Keychain lesbar ist
                let urlStatus  = CredentialsStore.shared.debugWriteTest()
                let store      = CredentialsStore.shared
                keychainDebugInfo = """
                    write-test: \(urlStatus)
                    url:  \(!store.nextcloudUrl.isEmpty  ? "✓ \(store.nextcloudUrl)" : "✗ leer")
                    user: \(!store.username.isEmpty      ? "✓ \(store.username)"     : "✗ leer")
                    pass: \(!store.appPassword.isEmpty   ? "✓ gesetzt"               : "✗ leer")
                    isConfigured: \(store.isConfigured   ? "✓" : "✗")
                    """

                showLoginSuccess = true
                onLoginSuccess?()
            } catch is CancellationError {
                isPolling = false
            } catch {
                isPolling      = false
                loginFlowError = error.localizedDescription
            }
        }
    }

    private func cancelLoginFlow() {
        pollTask?.cancel()
        pollTask       = nil
        isPolling      = false
        safariLoginURL = nil
        loginFlow.cancel()
    }

    private func logout() {
        cancelLoginFlow()
        CredentialsStore.shared.clearCredentials()
        // Browser-Session löschen damit beim nächsten Login ein anderer
        // Nextcloud-User gewählt werden kann (kein Cookie-/Session-Carry-over).
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
        URLCache.shared.removeAllCachedResponses()
        nextcloudUrl = "https://"
        username     = ""
        appPassword  = ""
        showLoginSuccess = false
        keychainDebugInfo = nil
        testResult = nil
    }

    private func clearCache() {
        PreferencesStore.shared.clearReadingPositions()
        URLCache.shared.removeAllCachedResponses()
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
        CredentialsStore.shared.clearCredentials()
        nextcloudUrl = "https://"
        username     = ""
        appPassword  = ""
        cacheCleared = true
        serverStorageUsage = nil
        serverStorageError = false
        Task {
            await ArticleCacheService.shared.clear()
            await ImageCacheService.shared.clear()
            await HighlightCacheService.shared.clear()
            await loadStorageUsage()
        }
    }

    // MARK: - Storage

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private func loadStorageUsage() async {
        // Verzeichnis-Enumeration ist blockierendes IO — vom Main-Actor weg,
        // damit die Form beim Öffnen der Settings nicht ruckelt.
        localCacheBytes = await Task.detached(priority: .utility) {
            LocalStorageService.totalCacheBytes()
        }.value

        guard CredentialsStore.shared.isConfigured else { return }
        do {
            serverStorageUsage = try await MerlinAPI.shared.getStorageUsage()
            serverStorageError = false
        } catch {
            serverStorageError = true
        }
    }

    private func testConnection() {
        isTesting  = true
        testResult = nil
        Task {
            do {
                try await MerlinAPI.shared.testConnection()
                testResult = .success("Connection successful!")
            } catch {
                testResult = .failure(error.localizedDescription)
            }
            isTesting = false
        }
    }

    // MARK: - Helpers

    /// Wraps URL to satisfy `Identifiable` for `.sheet(item:)`.
    private struct IdentifiableURL: Identifiable {
        let id = UUID()
        let url: URL
    }
}

// MARK: - Credential Debug View

private struct CredentialDebugView: View {
    private let store = CredentialsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Keychain Store", systemImage: "key.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            row("accessGroup", value: "2R735BXV66.dev.merlin")
            row("kc.url",      value: store.nextcloudUrl.isEmpty  ? "<nil>" : store.nextcloudUrl)
            row("kc.user",     value: store.username.isEmpty      ? "<nil>" : store.username)
            row("kc.pass",     value: store.appPassword.isEmpty   ? "<nil>" : "<gesetzt>")

            Divider()

            row("isConfigured", value: store.isConfigured ? "✓ true" : "✗ false")
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(10)
        .background(Color(.systemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ key: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Ephemeral WKWebView login wrapper

/// Zeigt die Nextcloud-Login-Seite in einem WKWebView mit nicht-persistentem
/// DataStore (nonPersistent). Dadurch gibt es keine geteilten Cookies mit Safari
/// und jeder Login-Versuch startet mit einer frischen Session — kein
/// "falscher User" durch einen alten Cookie.
private struct SafariLoginView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
