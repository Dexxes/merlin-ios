import Foundation
import Network

/// Retries the settings → server push when it fails offline.
///
/// `PreferencesStore` is the local source of truth (see `pushAppearanceToServer`
/// / `syncPreferences`, which intentionally swallow push errors with `try?` so
/// a flaky connection never blocks the UI). That's fine for the *current*
/// session, but it means changes made while offline previously never reached
/// the server — other devices would simply never see them.
///
/// This queue doesn't need to remember *what* changed (unlike
/// `OfflineMutationQueue`/`OfflineHighlightQueue`): settings are pushed as one
/// flat snapshot, so it's enough to remember *that* a push is owed and replay
/// it with `PreferencesStore.shared.toServerDict()` — i.e. the current local
/// state — once connectivity returns. That naturally coalesces any number of
/// offline edits into a single PUT.
final class SettingsSyncQueue: @unchecked Sendable {

    static let shared = SettingsSyncQueue()

    private let key = "merlin_settings_needs_sync_v1"
    private let defaults = UserDefaults.standard
    private var monitor: NWPathMonitor?

    private init() {
        startMonitoring()
    }

    /// Whether a previous push failed and is still owed to the server.
    var isDirty: Bool { defaults.bool(forKey: key) }

    /// Marks that the local settings differ from what the server has —
    /// call this when `updateSettings` fails with a network error.
    func markDirty() {
        defaults.set(true, forKey: key)
    }

    /// If a push is owed, retries it with the *current* local settings.
    /// Stays dirty on failure so the next reconnect tries again.
    func retryIfNeeded() async {
        guard isDirty else { return }
        do {
            try await MerlinAPI.shared.updateSettings(PreferencesStore.shared.toServerDict())
            defaults.set(false, forKey: key)
        } catch {
            // Still offline / still failing — leave the dirty flag set.
        }
    }

    // MARK: – Network monitoring

    private func startMonitoring() {
        let m = NWPathMonitor()
        monitor = m
        m.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            Task { await self.retryIfNeeded() }
        }
        m.start(queue: DispatchQueue(label: "dev.merlin.settings-netmonitor", qos: .utility))
    }
}
