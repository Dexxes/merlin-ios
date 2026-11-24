import Foundation

/// Which Keychain access groups the main app and the Share Extension use to
/// share the login (URL, username, app password, backend kind).
///
/// Why not one fixed group: xtool rewrites the signed entitlements of every
/// bundle. It replaces `keychain-access-groups` with exactly one group of its
/// own, `<Team-ID>.<rewritten bundle ID>`, so the app gets
/// `…XTL-<Team>.dev.merlin.app` and the extension
/// `…XTL-<Team>.dev.merlin.app.MerlinShare`. The extension therefore cannot
/// read the app's group. Since xtool 2.0 (rcodesign instead of zsign, app
/// groups allowed on free teams) the extension really is signed that way, and
/// it asked for credentials although the app was logged in.
///
/// What both bundles always share is the app group from the entitlements
/// (`group.dev.merlin`), which xtool rewrites to `group.XTL-<Team>.dev.merlin`.
/// An app group can be used as a Keychain access group on iOS, so the login is
/// stored there. Its rewritten name is derived from the bundle ID at runtime
/// (xtool rewrites `CFBundleIdentifier` with the same prefix), which also gives
/// plain `group.dev.merlin` in an Xcode build without rewriting.
public enum KeychainAccessGroups {

    /// Bundle ID of the main app as written in xtool.yml / Info.plist.
    public static let appBundleID = "dev.merlin.app"

    /// App group as written in the entitlements, before any rewriting.
    public static let appGroupBase = "dev.merlin"

    /// The group the login was stored in up to now: the main app's own
    /// Keychain group under xtool. Still read (and migrated from) so existing
    /// logins keep working.
    public static let legacyGroup = "2R735BXV66.XTL-2R735BXV66.dev.merlin.app"

    /// The app group ID that belongs to a (possibly rewritten) bundle ID of the
    /// main app or one of its extensions.
    ///
    /// - `dev.merlin.app` → `group.dev.merlin`
    /// - `XTL-2R735BXV66.dev.merlin.app.MerlinShare` → `group.XTL-2R735BXV66.dev.merlin`
    ///
    /// Returns nil when the bundle ID does not contain the app's bundle ID.
    public static func appGroupID(forBundleIdentifier bundleID: String) -> String? {
        var searchRange = bundleID.startIndex..<bundleID.endIndex
        while let range = bundleID.range(of: appBundleID, range: searchRange) {
            let startsComponent = range.lowerBound == bundleID.startIndex
                || bundleID[bundleID.index(before: range.lowerBound)] == "."
            let endsComponent = range.upperBound == bundleID.endIndex
                || bundleID[range.upperBound] == "."
            if startsComponent && endsComponent {
                let prefix = bundleID[..<range.lowerBound]
                return "group.\(prefix)\(appGroupBase)"
            }
            searchRange = range.upperBound..<bundleID.endIndex
        }
        return nil
    }

    /// Whether an app group ID is Merlin's (`group.dev.merlin`, also with any
    /// xtool prefix, e.g. an older `group.XTL-<other>.dev.merlin` that xtool
    /// reuses because it matches by the unprefixed name).
    public static func isMerlinAppGroup(_ groupID: String) -> Bool {
        guard groupID.hasPrefix("group.") else { return false }
        let rest = groupID.dropFirst("group.".count)
        return rest == appGroupBase || rest.hasSuffix(".\(appGroupBase)") && rest.hasPrefix("XTL-")
    }

    /// The app groups in the bundle's embedded.mobileprovision: the groups
    /// xtool really provisioned (and signed into the entitlements), whatever
    /// name they got. The file is a CMS envelope around an XML plist.
    public static func appGroups(fromMobileprovision data: Data) -> [String] {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups
    }

    /// The groups to use, in order: Merlin's app groups from the provisioning
    /// profile, then the one derived from the bundle ID (written to the first
    /// that accepts it), then the legacy group (read, and migrated from).
    public static func groups(forBundleIdentifier bundleID: String?, provisionedAppGroups: [String] = []) -> [String] {
        var groups: [String] = provisionedAppGroups.filter(isMerlinAppGroup)
        if let bundleID, let appGroup = appGroupID(forBundleIdentifier: bundleID) {
            groups.append(appGroup)
        }
        groups.append(legacyGroup)
        var seen = Set<String>()
        return groups.filter { seen.insert($0).inserted }
    }
}
