import Foundation
import Network

// MARK: – Mutation types

enum PendingHighlightKind: String, Codable {
    case create
    case delete
    case update
}

struct PendingHighlightMutation: Codable, Identifiable {
    let id: UUID
    let articleId: Int
    let kind: PendingHighlightKind

    /// `.create` only — the placeholder id the WebView assigned before the
    /// server confirmed (e.g. "tmp_1718999999999"); used to swap in the real
    /// id once replayed, and to cancel the create if the user deletes the
    /// highlight again before it ever reaches the server.
    let tempId: String?
    /// `.create` only — the payload to send once back online.
    let payload: HighlightCreate?
    /// `.delete`/`.update` — the server-confirmed highlight id.
    let highlightId: Int?
    /// `.update` only — the new passage (and colour) to send once back online.
    /// Optional so entries persisted by older builds still decode.
    var change: HighlightUpdate? = nil

    init(articleId: Int, kind: PendingHighlightKind,
         tempId: String? = nil, payload: HighlightCreate? = nil, highlightId: Int? = nil,
         change: HighlightUpdate? = nil) {
        self.id          = UUID()
        self.articleId   = articleId
        self.kind        = kind
        self.tempId      = tempId
        self.payload     = payload
        self.highlightId = highlightId
        self.change      = change
    }
}

// MARK: –

/// Persists highlight create/delete calls that failed due to network errors
/// and replays them once the device is back online — the same pattern as
/// `OfflineMutationQueue`, kept separate because highlights identify
/// not-yet-synced rows by a string `tempId` rather than a server `Int` id
/// (so the dedup/cancellation rules differ from the article mutation queue).
///
/// Highlights created offline keep their `tmp_…` id in the WebView until this
/// queue replays the create and the page is reloaded; if the user deletes
/// such a highlight before it ever reaches the server, the queued create is
/// simply cancelled — there is nothing to delete server-side.
final class OfflineHighlightQueue: @unchecked Sendable {

    static let shared = OfflineHighlightQueue()

    private let key  = "merlin_pending_highlight_mutations_v1"
    private let lock = NSLock()
    private var _pending: [PendingHighlightMutation] = []

    private var pending: [PendingHighlightMutation] {
        get { lock.withLock { _pending } }
        set { lock.withLock { _pending = newValue } }
    }

    var isEmpty: Bool { pending.isEmpty }

    private var monitor: NWPathMonitor?

    private init() {
        load()
        startMonitoring()
    }

    // MARK: – Enqueue

    func enqueueCreate(articleId: Int, tempId: String, payload: HighlightCreate) {
        lock.withLock {
            _pending.append(PendingHighlightMutation(
                articleId: articleId, kind: .create, tempId: tempId, payload: payload))
        }
        save()
    }

    /// Only the latest change per highlight is kept; a colour set by an
    /// earlier, still queued change carries over.
    func enqueueUpdate(articleId: Int, highlightId: Int, change: HighlightUpdate) {
        lock.withLock {
            var change = change
            if change.color == nil,
               let earlier = _pending.last(where: { $0.kind == .update && $0.highlightId == highlightId })?.change {
                change.color = earlier.color
            }
            _pending.removeAll { $0.kind == .update && $0.highlightId == highlightId }
            _pending.append(PendingHighlightMutation(
                articleId: articleId, kind: .update, highlightId: highlightId, change: change))
        }
        save()
    }

    func enqueueDelete(articleId: Int, highlightId: Int) {
        lock.withLock {
            // Deleted anyway: a queued change would only fail with 404.
            _pending.removeAll { $0.kind == .update && $0.highlightId == highlightId }
            _pending.append(PendingHighlightMutation(
                articleId: articleId, kind: .delete, highlightId: highlightId))
        }
        save()
    }

    /// Cancels a still-queued `.create` for `tempId` — used when the user
    /// deletes a highlight that was created offline and never made it to the
    /// server: there's nothing to delete remotely, and replaying the create
    /// would resurrect a highlight the user explicitly removed.
    func cancelPendingCreate(tempId: String, articleId: Int) {
        lock.withLock {
            _pending.removeAll { $0.kind == .create && $0.tempId == tempId && $0.articleId == articleId }
        }
        save()
    }

    // MARK: – Drain

    func drain() async {
        guard !pending.isEmpty else { return }

        let snapshot = pending
        // Clear before executing so mutations enqueued mid-drain aren't wiped.
        pending = []
        save()

        var failed: [PendingHighlightMutation] = []

        for mutation in snapshot {
            do {
                switch mutation.kind {
                case .create:
                    guard let payload = mutation.payload else { continue }
                    let saved = try await MerlinAPI.shared.createHighlight(mutation.articleId, payload: payload)
                    await HighlightCacheService.shared.upsert(saved)

                case .delete:
                    guard let highlightId = mutation.highlightId else { continue }
                    try await MerlinAPI.shared.deleteHighlight(highlightId)
                    await HighlightCacheService.shared.remove(id: highlightId, articleId: mutation.articleId)

                case .update:
                    guard let highlightId = mutation.highlightId, let change = mutation.change else { continue }
                    let saved = try await MerlinAPI.shared.updateHighlight(highlightId, payload: change)
                    await HighlightCacheService.shared.upsert(saved)
                }
            } catch {
                if mutation.kind == .delete, case MerlinAPIError.notFound = error, let hid = mutation.highlightId {
                    // Already gone server-side — treat as success.
                    await HighlightCacheService.shared.remove(id: hid, articleId: mutation.articleId)
                } else if mutation.kind == .update, !Self.isNetworkError(error) {
                    // Rejected (highlight deleted elsewhere, older server …):
                    // retrying won't help; the next fetch restores the truth.
                } else {
                    failed.append(mutation)
                }
            }
        }

        if !failed.isEmpty {
            lock.withLock { _pending.append(contentsOf: failed) }
            save()
        }
    }

    private static func isNetworkError(_ error: Error) -> Bool {
        if case MerlinAPIError.networkError = error { return true }
        return false
    }

    // MARK: – Network monitoring

    private func startMonitoring() {
        let m = NWPathMonitor()
        monitor = m
        m.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            Task { await self.drain() }
        }
        m.start(queue: DispatchQueue(label: "dev.merlin.highlight-netmonitor", qos: .utility))
    }

    // MARK: – Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func load() {
        guard let data    = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PendingHighlightMutation].self, from: data)
        else { return }
        _pending = decoded
    }
}
