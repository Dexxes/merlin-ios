import Foundation
import Network

// MARK: – Mutation types

enum PendingMutationKind: String, Codable {
    case toggleArchive
    case toggleFavorite
    case setTags
    case delete
}

struct PendingMutation: Codable, Identifiable {
    let id: UUID
    let articleId: Int
    let kind: PendingMutationKind
    /// Delta — only used for .setTags. Deliberately NOT a "full desired
    /// tag-id set": storing an absolute end-state and diffing it against
    /// whatever is on the server at replay time would delete any tag added
    /// by another client (or another mutation source) while this device was
    /// offline, since that tag wouldn't be part of the recorded end-state.
    /// Storing the actual add/remove delta means replay only ever touches
    /// the tag IDs the user explicitly acted on.
    let addTagIds: [Int]?
    let removeTagIds: [Int]?

    init(articleId: Int, kind: PendingMutationKind, addTagIds: [Int]? = nil, removeTagIds: [Int]? = nil) {
        self.id           = UUID()
        self.articleId    = articleId
        self.kind         = kind
        self.addTagIds    = addTagIds
        self.removeTagIds = removeTagIds
    }
}

// MARK: –

/// Persists mutations that failed due to network errors and replays them
/// once the device is back online.
///
/// Toggle deduplication: an even number of archive/favorite toggles for the
/// same article cancel each other out; an odd number results in one API call.
/// Tag deduplication: only the most recent setTags per article is kept.
/// Delete deduplication: a queued delete supersedes — and is not superseded
/// by — any other queued mutation for the same article, since replaying a
/// favorite/archive/tag change for an article that's about to be removed
/// would be pointless (and could even resurrect it server-side).
final class OfflineMutationQueue: @unchecked Sendable {

    static let shared = OfflineMutationQueue()

    private let key   = "merlin_pending_mutations_v1"
    private let lock  = NSLock()
    private var _pending: [PendingMutation] = []

    private var pending: [PendingMutation] {
        get { lock.withLock { _pending } }
        set { lock.withLock { _pending = newValue } }
    }

    var isEmpty: Bool { pending.isEmpty }

    // Callback invoked on the main actor after a successful drain so the
    // ViewModel can refresh its UI.
    var onDrained: (@MainActor () async -> Void)?

    private var monitor: NWPathMonitor?

    private init() {
        load()
        startMonitoring()
    }

    // MARK: – Enqueue

    func enqueue(_ mutation: PendingMutation) {
        lock.withLock {
            switch mutation.kind {
            case .delete:
                // Supersedes everything else queued for this article — no
                // point replaying a favorite/archive/tag change for a row
                // that's about to be removed.
                _pending.removeAll { $0.articleId == mutation.articleId }
                _pending.append(mutation)
            case .setTags:
                // A delete already queued wins — skip.
                guard !_pending.contains(where: { $0.articleId == mutation.articleId && $0.kind == .delete }) else { return }
                let newAdd    = Set(mutation.addTagIds ?? [])
                let newRemove = Set(mutation.removeTagIds ?? [])
                if let existingIndex = _pending.firstIndex(where: { $0.articleId == mutation.articleId && $0.kind == .setTags }) {
                    // Merge with the already-queued delta: a later add cancels
                    // an earlier queued remove of the same tag (and vice
                    // versa), so repeated offline edits collapse into one
                    // equivalent delta instead of an absolute end-state.
                    let existing        = _pending[existingIndex]
                    let existingAdd     = Set(existing.addTagIds ?? [])
                    let existingRemove  = Set(existing.removeTagIds ?? [])
                    let mergedAdd       = existingAdd.subtracting(newRemove).union(newAdd)
                    let mergedRemove    = existingRemove.subtracting(newAdd).union(newRemove)
                    _pending.remove(at: existingIndex)
                    if !mergedAdd.isEmpty || !mergedRemove.isEmpty {
                        _pending.append(PendingMutation(
                            articleId: mutation.articleId, kind: .setTags,
                            addTagIds: Array(mergedAdd), removeTagIds: Array(mergedRemove)))
                    }
                } else if !newAdd.isEmpty || !newRemove.isEmpty {
                    _pending.append(mutation)
                }
            case .toggleArchive, .toggleFavorite:
                // A delete already queued wins — skip; otherwise append
                // (even count = net no-op, handled in drain).
                guard !_pending.contains(where: { $0.articleId == mutation.articleId && $0.kind == .delete }) else { return }
                _pending.append(mutation)
            }
        }
        save()
    }

    // MARK: – Drain

    /// Executes all effective pending mutations. Keeps failed ones for retry.
    func drain() async {
        guard !pending.isEmpty else { return }

        let snapshot = pending

        // Compute effective operations
        var toExecute: [PendingMutation] = []

        // Toggles: odd count per (article, kind) = one call
        for kind in [PendingMutationKind.toggleArchive, .toggleFavorite] {
            let byArticle = Dictionary(grouping: snapshot.filter { $0.kind == kind }) { $0.articleId }
            for (_, mutations) in byArticle where mutations.count % 2 == 1 {
                toExecute.append(mutations[0])
            }
        }

        // setTags: already deduplicated on enqueue, but keep only last per article in snapshot
        var seenTagArticles = Set<Int>()
        for m in snapshot.reversed() where m.kind == .setTags {
            if seenTagArticles.insert(m.articleId).inserted {
                toExecute.append(m)
            }
        }

        // Deletes: enqueue() guarantees at most one per article (and that it
        // supersedes any other queued mutation for that article), so every
        // queued delete is effective as-is.
        toExecute.append(contentsOf: snapshot.filter { $0.kind == .delete })

        // Clear queue before executing so new mutations aren't wiped
        pending = []
        save()

        var failed: [PendingMutation] = []

        for mutation in toExecute {
            do {
                switch mutation.kind {
                case .toggleArchive:
                    let updated = try await MerlinAPI.shared.toggleArchive(mutation.articleId)
                    // Mirror ArticlesViewModel's online path: keep the cache's
                    // archivedAt/eviction bookkeeping in sync, and drop cached
                    // images for articles that ended up archived — otherwise
                    // mutations replayed from the offline queue would leave
                    // stale state and orphaned images behind indefinitely.
                    await ArticleCacheService.shared.upsert(updated)
                    if updated.isArchived {
                        await ImageCacheService.shared.evict(articleId: updated.id)
                    }

                case .toggleFavorite:
                    let updated = try await MerlinAPI.shared.toggleFavorite(mutation.articleId)
                    await ArticleCacheService.shared.upsert(updated)

                case .setTags:
                    let addIds    = Set(mutation.addTagIds ?? [])
                    let removeIds = Set(mutation.removeTagIds ?? [])
                    guard !addIds.isEmpty || !removeIds.isEmpty else { break }
                    // Re-check current server state right before replaying:
                    // (a) skip adds that are already present — the server has
                    // no unique constraint on (article_id, tag_id), so a
                    // redundant POST would create a duplicate row; (b) this is
                    // the actual fix for the tag-overwrite bug — we only ever
                    // touch the specific IDs in addIds/removeIds, so a tag
                    // added by another client while we were offline (and thus
                    // absent from both sets) is never touched.
                    let article = try await MerlinAPI.shared.getArticle(mutation.articleId)
                    let current = Set(article.tags.map { $0.id })
                    for id in addIds where !current.contains(id) {
                        try await MerlinAPI.shared.addTagToArticle(articleId: mutation.articleId, tagId: id)
                    }
                    for id in removeIds where current.contains(id) {
                        try await MerlinAPI.shared.removeTagFromArticle(articleId: mutation.articleId, tagId: id)
                    }
                    if let refreshed = try? await MerlinAPI.shared.getArticle(mutation.articleId) {
                        await ArticleCacheService.shared.upsert(refreshed)
                    }

                case .delete:
                    try await MerlinAPI.shared.deleteArticle(mutation.articleId)
                    await ArticleCacheService.shared.remove(id: mutation.articleId)
                    await ImageCacheService.shared.evict(articleId: mutation.articleId)
                }
            } catch {
                if mutation.kind == .delete, case MerlinAPIError.notFound = error {
                    // Already gone server-side (e.g. deleted from another
                    // device while we were offline) — treat as success rather
                    // than retrying forever, but still finish local cleanup.
                    await ArticleCacheService.shared.remove(id: mutation.articleId)
                    await ImageCacheService.shared.evict(articleId: mutation.articleId)
                } else {
                    failed.append(mutation)
                }
            }
        }

        if !failed.isEmpty {
            // Re-enqueue failures (without triggering deduplication logic again)
            lock.withLock { _pending.append(contentsOf: failed) }
            save()
        }

        if !toExecute.isEmpty {
            await onDrained?()
        }
    }

    // MARK: – Network monitoring

    private func startMonitoring() {
        let m = NWPathMonitor()
        monitor = m
        m.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            Task { await self.drain() }
        }
        m.start(queue: DispatchQueue(label: "dev.merlin.netmonitor", qos: .utility))
    }

    // MARK: – Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func load() {
        guard let data   = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PendingMutation].self, from: data)
        else { return }
        _pending = decoded
    }
}
