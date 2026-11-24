import Foundation
import MerlinShared

/// Stores Nextcloud credentials in the iOS Keychain, shared with the Share
/// Extension through `SharedKeychain` (MerlinShared): the app group
/// `group.dev.merlin` (under xtool `group.XTL-<Team>.dev.merlin`) is the
/// shared Keychain access group, the app's old own group is still read and
/// migrated at launch. See `KeychainAccessGroups` for why a fixed group does
/// not work with xtool.
/// Thread-safe: SecItem* functions are thread-safe, @unchecked Sendable is safe here.
final class CredentialsStore: @unchecked Sendable {

    static let shared = CredentialsStore()
    private init() {}

    private let keychain = SharedKeychain.current
    private typealias Account = SharedKeychain.Account

    /// Welche Art Backend hinter `nextcloudUrl` steckt - steuert API-URL-Präfix,
    /// Login-Flow-Start-URL und ob Nextcloud-only-Features (TTS/SSE/Settings-
    /// Sync/Public-Share/YouTube-Embed-Proxy) angezeigt werden. merlin-server
    /// (`.standalone`) unterstützt aktuell nur die Kern-Leselisten-API.
    enum BackendKind: String {
        case nextcloud
        case standalone
    }

    // MARK: - Properties

    /// Default `.nextcloud` für Bestandsinstallationen ohne gespeicherten Wert -
    /// keine Migration nötig, bestehende Verbindungen funktionieren unverändert.
    /// Wird bewusst NICHT von `clearCredentials()` gelöscht, damit die zuletzt
    /// gewählte Backend-Art als Vorbelegung für die nächste Anmeldung erhalten bleibt.
    var backendKind: BackendKind {
        get { BackendKind(rawValue: keychainRead(.backendKind) ?? "") ?? .nextcloud }
        set { keychainWrite(newValue.rawValue, for: .backendKind) }
    }

    /// Nextcloud-only-Features (TTS, SSE, Settings-Sync, Public-Share,
    /// YouTube-Embed-Proxy) - merlin-server liefert sie (noch) nicht.
    var supportsNextcloudOnlyFeatures: Bool { backendKind == .nextcloud }

    var nextcloudUrl: String {
        get { keychainRead(.nextcloudUrl) ?? "" }
        set {
            let v = newValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/$", with: "", options: .regularExpression)
            keychainWrite(v, for: .nextcloudUrl)
        }
    }

    var username: String {
        get { keychainRead(.username) ?? "" }
        set { keychainWrite(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: .username) }
    }

    var appPassword: String {
        get { keychainRead(.appPassword) ?? "" }
        set { keychainWrite(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: .appPassword) }
    }

    var isConfigured: Bool {
        !nextcloudUrl.isEmpty && !username.isEmpty && !appPassword.isEmpty
    }

    var basicAuthHeader: String? {
        guard isConfigured else { return nil }
        let token = Data("\(username):\(appPassword)".utf8).base64EncodedString()
        return "Basic \(token)"
    }

    // MARK: - Keychain

    private func keychainRead(_ account: Account) -> String? {
        keychain.read(account)
    }

    @discardableResult
    private func keychainWrite(_ value: String, for account: Account) -> Bool {
        let ok = keychain.write(value, for: account)
        print("[CredentialsStore] Keychain write \(ok ? "OK" : "FAILED") for '\(account.rawValue)'")
        return ok
    }

    private func keychainDelete(_ account: Account) {
        keychain.delete(account)
    }

    // MARK: - Debug

    /// Schreibt einen Testwert in die Keychain und liest ihn sofort zurück,
    /// in jeder Access-Group, die Hauptapp und Share-Extension nutzen.
    func debugWriteTest() -> String {
        let backend = SystemKeychainBackend()
        let testKey = "merlin_debug_test"
        let testVal = "ping"
        return keychain.groups.map { group in
            backend.delete(service: SharedKeychain.service, account: testKey, group: group)
            defer { backend.delete(service: SharedKeychain.service, account: testKey, group: group) }
            guard backend.write(testVal, service: SharedKeychain.service, account: testKey, group: group)
            else { return "\(group): write failed" }
            guard backend.read(service: SharedKeychain.service, account: testKey, group: group) == testVal
            else { return "\(group): read failed" }
            return "\(group): OK"
        }.joined(separator: "\n")
    }

    /// Bundle-ID, App-Groups aus dem Profil und Lesestatus je Keychain-Gruppe.
    var keychainDiagnostics: String { keychain.diagnostics() }

    // MARK: - Clear

    func clearCredentials() {
        keychainDelete(.nextcloudUrl)
        keychainDelete(.username)
        keychainDelete(.appPassword)
    }

    // MARK: - Migration from UserDefaults

    /// Call once on app launch. Moves credentials that were stored in UserDefaults
    /// (before the Keychain migration) into the Keychain.
    func migrateToGroupDefaultsIfNeeded() {
        // Login aus der alten Keychain-Group der Hauptapp in die geteilte
        // App-Group kopieren, damit die Share-Extension sie findet.
        let copied = keychain.migrateIfNeeded()
        if !copied.isEmpty {
            print("[CredentialsStore] Keychain migrated to shared group: \(copied.map(\.rawValue))")
        }

        guard nextcloudUrl.isEmpty else { return } // Already in Keychain, nothing to do

        let groupDefaults = UserDefaults(suiteName: "group.dev.merlin")
        let standard      = UserDefaults.standard

        if let url = groupDefaults?.string(forKey: "merlin_nextcloud_url") ?? standard.string(forKey: "merlin_nextcloud_url"), !url.isEmpty {
            nextcloudUrl = url
        }
        if let user = groupDefaults?.string(forKey: "merlin_username") ?? standard.string(forKey: "merlin_username"), !user.isEmpty {
            username = user
        }
        if let pass = groupDefaults?.string(forKey: "merlin_app_password") ?? standard.string(forKey: "merlin_app_password"), !pass.isEmpty {
            appPassword = pass
        }
    }
}
