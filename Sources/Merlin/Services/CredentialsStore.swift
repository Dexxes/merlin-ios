import Foundation
import Security

/// Stores Nextcloud credentials in the shared iOS Keychain.
/// Both the main app and the Share Extension access the same Keychain item via
/// the shared access group "2R735BXV66.dev.merlin" (provisioned by xtool).
/// UserDefaults is NOT used for credentials — Keychain is more secure and works
/// across process boundaries without requiring App Groups.
/// Thread-safe: SecItem* functions are thread-safe, @unchecked Sendable is safe here.
final class CredentialsStore: @unchecked Sendable {

    static let shared = CredentialsStore()
    private init() {}

    private let service     = "dev.merlin.app"
    // Application Identifier der Hauptapp aus dem xtool-Provisioning-Profile.
    // Extension darf darauf zugreifen, weil ihr Profile "2R735BXV66.*" erlaubt.
    private let accessGroup = "2R735BXV66.XTL-2R735BXV66.dev.merlin.app"

    private enum Account: String {
        case nextcloudUrl = "nextcloudUrl"
        case username     = "username"
        case appPassword  = "appPassword"
        case backendKind  = "backendKind"
    }

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
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     service,
            kSecAttrAccount:     account.rawValue,
            kSecAttrAccessGroup: accessGroup,
            kSecReturnData:      true,
            kSecMatchLimit:      kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data   = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    @discardableResult
    private func keychainWrite(_ value: String, for account: Account) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     service,
            kSecAttrAccount:     account.rawValue,
            kSecAttrAccessGroup: accessGroup,
        ]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData] = data
            status = SecItemAdd(newItem as CFDictionary, nil)
        }
        if status != errSecSuccess {
            print("[CredentialsStore] Keychain write FAILED for '\(account.rawValue)': OSStatus \(status)")
        } else {
            print("[CredentialsStore] Keychain write OK for '\(account.rawValue)'")
        }
        return status == errSecSuccess
    }

    private func keychainDelete(_ account: Account) {
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     service,
            kSecAttrAccount:     account.rawValue,
            kSecAttrAccessGroup: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Debug

    /// Schreibt einen Testwert in die Keychain und liest ihn sofort zurück.
    /// Gibt "OK" oder den OSStatus-Fehlercode zurück.
    func debugWriteTest() -> String {
        let testKey  = "merlin_debug_test"
        let testVal  = "ping"
        guard let data = testVal.data(using: .utf8) else { return "data encoding failed" }

        // Aufräumen
        let delQuery: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: testKey, kSecAttrAccessGroup: accessGroup]
        SecItemDelete(delQuery as CFDictionary)

        // Schreiben
        let addQuery: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: testKey, kSecAttrAccessGroup: accessGroup, kSecValueData: data]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { return "write failed: OSStatus \(addStatus)" }

        // Lesen
        let readQuery: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: testKey, kSecAttrAccessGroup: accessGroup, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: AnyObject?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        guard readStatus == errSecSuccess, let d = result as? Data, String(data: d, encoding: .utf8) == testVal
        else { return "read failed: OSStatus \(readStatus)" }

        SecItemDelete(delQuery as CFDictionary)
        return "OK – Keychain funktioniert"
    }

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
