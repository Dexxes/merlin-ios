import Foundation
import Network

/// Retries the per-article reading-position push when it fails offline.
///
/// Like `SettingsSyncQueue`, the local store (`PreferencesStore`) is the source
/// of truth and `MerlinAPI.updateProgress` is fire-and-forget — a flaky
/// connection must never block closing the reader. But a position saved while
/// offline would otherwise never reach the server, so other devices would never
/// see it. This queue remembers the latest position *owed* to the server per
/// article and replays it once connectivity returns.
///
/// Unlike `OfflineMutationQueue`/`OfflineHighlightQueue` this needs no ordering
/// or coalescing logic: reading progress is last-write-wins and idempotent, so
/// keeping only the *latest* entry per article (a dictionary keyed by id) is
/// enough — any number of offline scrolls collapse into one pending push.
final class ProgressSyncQueue: @unchecked Sendable {

    static let shared = ProgressSyncQueue()

    private struct Pending: Codable {
        var progress: Double
        var updatedAt: Int
    }

    /// JSON object keys must be strings, so the pending map is keyed by
    /// `String(articleId)` and converted at the boundary.
    private let key = "merlin_progress_pending_v1"
    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private var monitor: NWPathMonitor?

    private init() {
        startMonitoring()
    }

    /// Whether any position is still owed to the server.
    var isDirty: Bool {
        lock.lock(); defer { lock.unlock() }
        return !load().isEmpty
    }

    // MARK: – Enqueue / retry

    /// Records the latest position owed to the server for `articleId`. Always
    /// overwrites any previous pending entry for that article (last-write-wins).
    func enqueue(articleId: Int, progress: Double, updatedAt: Int) {
        lock.lock(); defer { lock.unlock() }
        var dict = load()
        dict[String(articleId)] = Pending(progress: progress, updatedAt: updatedAt)
        store(dict)
    }

    /// Pushes every owed position; drops entries that succeed and keeps the rest
    /// so the next reconnect tries again. An entry that was superseded by a newer
    /// `enqueue` during the await is intentionally NOT dropped — its newer value
    /// will be pushed on the following pass (LWW converges either way).
    func retryIfNeeded() async {
        let pending = pendingSnapshot()
        guard !pending.isEmpty else { return }

        for (idStr, entry) in pending {
            guard let id = Int(idStr) else { continue }
            do {
                try await MerlinAPI.shared.updateProgress(id, progress: entry.progress, updatedAt: entry.updatedAt)
                dropIfNotSuperseded(idStr, pushedUpdatedAt: entry.updatedAt)
            } catch {
                // Still offline / still failing — leave it for the next reconnect.
            }
        }
    }

    /// Synchronous, lock-guarded snapshot. `NSLock` must not be held across an
    /// `await`, so all locking happens inside synchronous helpers like this one.
    private func pendingSnapshot() -> [String: Pending] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    /// Synchronous, lock-guarded removal: drops the entry only if it wasn't
    /// superseded by a newer `enqueue` during the await (LWW converges either way).
    private func dropIfNotSuperseded(_ idStr: String, pushedUpdatedAt: Int) {
        lock.lock(); defer { lock.unlock() }
        var dict = load()
        if let current = dict[idStr], current.updatedAt <= pushedUpdatedAt {
            dict.removeValue(forKey: idStr)
            store(dict)
        }
    }

    // MARK: – Persistence (caller holds `lock`)

    private func load() -> [String: Pending] {
        guard let data = defaults.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: Pending].self, from: data) else { return [:] }
        return dict
    }

    private func store(_ dict: [String: Pending]) {
        if dict.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(try? JSONEncoder().encode(dict), forKey: key)
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
        m.start(queue: DispatchQueue(label: "dev.merlin.progress-netmonitor", qos: .utility))
    }
}
