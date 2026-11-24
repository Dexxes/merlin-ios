import Foundation

/// Where a Keychain item lives: one entry per access group, so the lookup
/// order can be tested without the real Keychain.
public protocol KeychainBackend: Sendable {
    /// The value for `account` in `group`, or nil (missing or not readable).
    func read(service: String, account: String, group: String) -> String?
    /// Writes or updates the value. Returns false when the group is not in
    /// this bundle's entitlements or the write fails otherwise.
    @discardableResult
    func write(_ value: String, service: String, account: String, group: String) -> Bool
    func delete(service: String, account: String, group: String)
}

/// The login shared by the main app and the Share Extension.
///
/// Reads look in the shared app group first and then in the legacy group
/// (see `KeychainAccessGroups`). Writes go to the first group that accepts
/// them. `migrateIfNeeded()` copies a login from the legacy group into the
/// shared group; the main app calls it at launch, because only the app can
/// read the legacy group.
public struct SharedKeychain: Sendable {

    public static let service = "dev.merlin.app"

    public enum Account: String, CaseIterable, Sendable {
        case nextcloudUrl
        case username
        case appPassword
        case backendKind
    }

    public let groups: [String]
    private let backend: KeychainBackend

    public init(groups: [String], backend: KeychainBackend) {
        self.groups = groups
        self.backend = backend
    }

    public func read(_ account: Account) -> String? {
        for group in groups {
            if let value = backend.read(service: Self.service, account: account.rawValue, group: group) {
                return value
            }
        }
        return nil
    }

    @discardableResult
    public func write(_ value: String, for account: Account) -> Bool {
        for group in groups {
            if backend.write(value, service: Self.service, account: account.rawValue, group: group) {
                // An older copy further down the list would otherwise win
                // once this group becomes unreadable (e.g. other signing).
                for other in groups where other != group {
                    if backend.read(service: Self.service, account: account.rawValue, group: other) != nil {
                        backend.write(value, service: Self.service, account: account.rawValue, group: other)
                    }
                }
                return true
            }
        }
        return false
    }

    public func delete(_ account: Account) {
        for group in groups {
            backend.delete(service: Self.service, account: account.rawValue, group: group)
        }
    }

    /// Copies values that exist only in a later group (legacy) into the first
    /// group (shared app group), so the Share Extension finds them. The legacy
    /// copy stays, so an older build of the extension keeps working.
    /// Returns the accounts that were copied.
    @discardableResult
    public func migrateIfNeeded() -> [Account] {
        guard let shared = groups.first, groups.count > 1 else { return [] }
        var copied: [Account] = []
        for account in Account.allCases {
            if backend.read(service: Self.service, account: account.rawValue, group: shared) != nil { continue }
            for group in groups.dropFirst() {
                guard let value = backend.read(service: Self.service, account: account.rawValue, group: group) else { continue }
                if backend.write(value, service: Self.service, account: account.rawValue, group: shared) {
                    copied.append(account)
                }
                break
            }
        }
        return copied
    }
}

#if canImport(Security)
import Security

/// The real iOS Keychain (generic passwords).
public struct SystemKeychainBackend: KeychainBackend {

    public init() {}

    public func read(service: String, account: String, group: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     service,
            kSecAttrAccount:     account,
            kSecAttrAccessGroup: group,
            kSecReturnData:      true,
            kSecMatchLimit:      kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            if status != errSecItemNotFound && status != errSecSuccess {
                print("[SharedKeychain] read '\(account)' in \(group): OSStatus \(status)")
            }
            return nil
        }
        return string
    }

    @discardableResult
    public func write(_ value: String, service: String, account: String, group: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     service,
            kSecAttrAccount:     account,
            kSecAttrAccessGroup: group,
        ]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData] = data
            status = SecItemAdd(newItem as CFDictionary, nil)
        }
        if status != errSecSuccess {
            print("[SharedKeychain] write '\(account)' in \(group): OSStatus \(status)")
        }
        return status == errSecSuccess
    }

    public func delete(service: String, account: String, group: String) {
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     service,
            kSecAttrAccount:     account,
            kSecAttrAccessGroup: group,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension SharedKeychain {
    /// The store for the running bundle (app or extension).
    public static let current = SharedKeychain(
        groups: KeychainAccessGroups.groups(
            forBundleIdentifier: Bundle.main.bundleIdentifier,
            provisionedAppGroups: provisionedAppGroups
        ),
        backend: SystemKeychainBackend()
    )

    /// App groups from this bundle's embedded.mobileprovision (empty in the
    /// simulator and in App Store builds, which have none).
    public static var provisionedAppGroups: [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return [] }
        return KeychainAccessGroups.appGroups(fromMobileprovision: data)
    }

    /// The Keychain group this bundle writes to when none is given: the first
    /// entry of its signed keychain-access-groups.
    public static var defaultAccessGroup: String? {
        let probe: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: "dev.merlin.probe",
            kSecAttrAccount: "probe",
        ]
        SecItemDelete(probe as CFDictionary)
        var added = probe
        added[kSecValueData] = Data("1".utf8)
        added[kSecReturnAttributes] = true
        var result: AnyObject?
        guard SecItemAdd(added as CFDictionary, &result) == errSecSuccess else { return nil }
        SecItemDelete(probe as CFDictionary)
        return (result as? [String: Any])?[kSecAttrAccessGroup as String] as? String
    }

    /// One line per fact, for the debug output in app and extension: bundle
    /// ID, provisioned app groups, default group, and per group whether the
    /// login can be read (OSStatus).
    public func diagnostics() -> String {
        var lines = [
            "bundle: \(Bundle.main.bundleIdentifier ?? "-")",
            "profile groups: \(Self.provisionedAppGroups.joined(separator: ", "))",
            "default group: \(Self.defaultAccessGroup ?? "-")",
        ]
        for group in groups {
            let query: [CFString: Any] = [
                kSecClass:           kSecClassGenericPassword,
                kSecAttrService:     Self.service,
                kSecAttrAccount:     Account.appPassword.rawValue,
                kSecAttrAccessGroup: group,
                kSecMatchLimit:      kSecMatchLimitOne,
            ]
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            let text = status == errSecSuccess ? "found"
                : status == errSecItemNotFound ? "empty"
                : "OSStatus \(status)"
            lines.append("\(group): \(text)")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
