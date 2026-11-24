import XCTest
@testable import MerlinShared

/// In-memory Keychain: only the groups in `entitled` can be read or written,
/// like a bundle whose entitlements lack a group (errSecMissingEntitlement).
final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    var items: [String: String] = [:]   // "group|account" -> value
    var entitled: Set<String>
    private let lock = NSLock()

    init(entitled: Set<String>) { self.entitled = entitled }

    private func key(_ account: String, _ group: String) -> String { "\(group)|\(account)" }

    func read(service: String, account: String, group: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard entitled.contains(group) else { return nil }
        return items[key(account, group)]
    }

    @discardableResult
    func write(_ value: String, service: String, account: String, group: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard entitled.contains(group) else { return false }
        items[key(account, group)] = value
        return true
    }

    func delete(service: String, account: String, group: String) {
        lock.lock(); defer { lock.unlock() }
        guard entitled.contains(group) else { return }
        items[key(account, group)] = nil
    }
}

final class KeychainAccessGroupsTests: XCTestCase {

    func testAppGroupFromXtoolBundleIDs() {
        XCTAssertEqual(
            KeychainAccessGroups.appGroupID(forBundleIdentifier: "XTL-2R735BXV66.dev.merlin.app"),
            "group.XTL-2R735BXV66.dev.merlin"
        )
        XCTAssertEqual(
            KeychainAccessGroups.appGroupID(forBundleIdentifier: "XTL-2R735BXV66.dev.merlin.app.MerlinShare"),
            "group.XTL-2R735BXV66.dev.merlin"
        )
    }

    func testAppGroupFromPlainBundleIDs() {
        XCTAssertEqual(KeychainAccessGroups.appGroupID(forBundleIdentifier: "dev.merlin.app"), "group.dev.merlin")
        XCTAssertEqual(
            KeychainAccessGroups.appGroupID(forBundleIdentifier: "dev.merlin.app.MerlinShare"),
            "group.dev.merlin"
        )
    }

    func testAppAndExtensionGetTheSameGroup() {
        for prefix in ["", "XTL-2R735BXV66.", "XTL-ABCDEF1234."] {
            XCTAssertEqual(
                KeychainAccessGroups.appGroupID(forBundleIdentifier: "\(prefix)dev.merlin.app"),
                KeychainAccessGroups.appGroupID(forBundleIdentifier: "\(prefix)dev.merlin.app.MerlinShare")
            )
        }
    }

    func testUnrelatedBundleIDs() {
        XCTAssertNil(KeychainAccessGroups.appGroupID(forBundleIdentifier: "com.example.other"))
        XCTAssertNil(KeychainAccessGroups.appGroupID(forBundleIdentifier: "dev.merlin.application"))
        XCTAssertNil(KeychainAccessGroups.appGroupID(forBundleIdentifier: "xdev.merlin.app"))
    }

    func testGroupsOrder() {
        XCTAssertEqual(
            KeychainAccessGroups.groups(forBundleIdentifier: "XTL-2R735BXV66.dev.merlin.app.MerlinShare"),
            ["group.XTL-2R735BXV66.dev.merlin", KeychainAccessGroups.legacyGroup]
        )
        XCTAssertEqual(KeychainAccessGroups.groups(forBundleIdentifier: nil), [KeychainAccessGroups.legacyGroup])
    }
}

final class SharedKeychainTests: XCTestCase {

    let appGroup = "group.XTL-2R735BXV66.dev.merlin"
    let legacy = KeychainAccessGroups.legacyGroup
    // What xtool signs into each bundle: its own keychain group plus the app group.
    let appOwnGroup = KeychainAccessGroups.legacyGroup
    let extensionOwnGroup = "2R735BXV66.XTL-2R735BXV66.dev.merlin.app.MerlinShare"

    private func stores(_ fake: FakeKeychain) -> (app: SharedKeychain, ext: SharedKeychain) {
        let groups = [appGroup, legacy]
        return (SharedKeychain(groups: groups, backend: fake), SharedKeychain(groups: groups, backend: fake))
    }

    /// The reported bug: login in the app, then the extension finds nothing.
    func testExtensionReadsLoginWrittenByApp() {
        let fake = FakeKeychain(entitled: [appGroup, appOwnGroup])
        let app = SharedKeychain(groups: [appGroup, legacy], backend: fake)
        XCTAssertTrue(app.write("https://cloud.example", for: .nextcloudUrl))
        XCTAssertTrue(app.write("dana", for: .username))
        XCTAssertTrue(app.write("secret", for: .appPassword))

        fake.entitled = [appGroup, extensionOwnGroup]
        let ext = SharedKeychain(groups: [appGroup, legacy], backend: fake)
        XCTAssertEqual(ext.read(.nextcloudUrl), "https://cloud.example")
        XCTAssertEqual(ext.read(.username), "dana")
        XCTAssertEqual(ext.read(.appPassword), "secret")
    }

    /// Existing login in the old group: the app migrates it, then the
    /// extension can read it.
    func testMigrationFromLegacyGroup() {
        let fake = FakeKeychain(entitled: [appGroup, appOwnGroup])
        fake.items["\(legacy)|nextcloudUrl"] = "https://cloud.example"
        fake.items["\(legacy)|username"] = "dana"
        fake.items["\(legacy)|appPassword"] = "secret"

        // Before migration the extension cannot see it.
        fake.entitled = [appGroup, extensionOwnGroup]
        XCTAssertNil(stores(fake).ext.read(.appPassword))

        fake.entitled = [appGroup, appOwnGroup]
        let copied = stores(fake).app.migrateIfNeeded()
        XCTAssertEqual(Set(copied), [.nextcloudUrl, .username, .appPassword])
        XCTAssertEqual(fake.items["\(legacy)|appPassword"], "secret", "legacy copy stays for older builds")

        fake.entitled = [appGroup, extensionOwnGroup]
        XCTAssertEqual(stores(fake).ext.read(.appPassword), "secret")
        XCTAssertEqual(stores(fake).ext.read(.username), "dana")
    }

    func testMigrationKeepsNewerSharedValue() {
        let fake = FakeKeychain(entitled: [appGroup, appOwnGroup])
        fake.items["\(appGroup)|appPassword"] = "new"
        fake.items["\(legacy)|appPassword"] = "old"
        XCTAssertEqual(stores(fake).app.migrateIfNeeded(), [])
        XCTAssertEqual(stores(fake).app.read(.appPassword), "new")
    }

    func testMigrationIsIdempotent() {
        let fake = FakeKeychain(entitled: [appGroup, appOwnGroup])
        fake.items["\(legacy)|username"] = "dana"
        XCTAssertEqual(stores(fake).app.migrateIfNeeded(), [.username])
        XCTAssertEqual(stores(fake).app.migrateIfNeeded(), [])
    }

    /// A new login replaces the password in both groups, so a stale legacy
    /// password can never win later.
    func testWriteUpdatesExistingLegacyCopy() {
        let fake = FakeKeychain(entitled: [appGroup, appOwnGroup])
        fake.items["\(legacy)|appPassword"] = "old"
        XCTAssertTrue(stores(fake).app.write("new", for: .appPassword))
        XCTAssertEqual(fake.items["\(appGroup)|appPassword"], "new")
        XCTAssertEqual(fake.items["\(legacy)|appPassword"], "new")
    }

    /// Signed without the app group (older xtool on a free team): fall back
    /// to the old group, as before this change.
    func testFallsBackToLegacyWithoutAppGroup() {
        let fake = FakeKeychain(entitled: [appOwnGroup])
        let app = stores(fake).app
        XCTAssertTrue(app.write("dana", for: .username))
        XCTAssertEqual(fake.items["\(legacy)|username"], "dana")
        XCTAssertEqual(app.read(.username), "dana")
        XCTAssertEqual(app.migrateIfNeeded(), [])
    }

    /// Credentials typed into the extension's own login form reach the app.
    func testAppReadsLoginWrittenByExtension() {
        let fake = FakeKeychain(entitled: [appGroup, extensionOwnGroup])
        XCTAssertTrue(stores(fake).ext.write("secret", for: .appPassword))
        fake.entitled = [appGroup, appOwnGroup]
        XCTAssertEqual(stores(fake).app.read(.appPassword), "secret")
    }

    func testDeleteRemovesFromAllGroups() {
        let fake = FakeKeychain(entitled: [appGroup, appOwnGroup])
        fake.items["\(appGroup)|appPassword"] = "a"
        fake.items["\(legacy)|appPassword"] = "b"
        stores(fake).app.delete(.appPassword)
        XCTAssertNil(stores(fake).app.read(.appPassword))
        XCTAssertTrue(fake.items.isEmpty)
    }
}
