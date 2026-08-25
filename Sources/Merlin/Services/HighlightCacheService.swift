import Foundation

/// Persists `Highlight` objects per article to disk so previously synced
/// highlights remain visible when the device is offline — mirrors the
/// `ArticleCacheService` / `ReminderService` pattern (additive JSON cache,
/// actor-isolated, lazily loaded).
///
/// The server is always the source of truth when reachable: a successful
/// `getHighlights` fetch calls `replaceAll`, which fully replaces the set for
/// that article (so highlights deleted elsewhere disappear here too). Local
/// optimistic creates/deletes use `upsert`/`remove` so the cache tracks
/// in-flight changes until the next authoritative refresh.
actor HighlightCacheService {

    static let shared = HighlightCacheService()
    private init() {}

    // MARK: – In-memory store (loaded lazily from disk)

    private var cache: [Int: [Highlight]] = [:]   // articleId → highlights
    private var isLoaded = false

    // MARK: – Disk location

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("merlin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent("highlight-cache.json")
    }

    // MARK: – Public API

    /// Cached highlights for an article, sorted the same way the server
    /// returns them (creation order) — empty if nothing is cached yet.
    func highlights(for articleId: Int) -> [Highlight] {
        loadFromDiskIfNeeded()
        return cache[articleId] ?? []
    }

    /// Replaces the full cached set for an article — called after a
    /// successful server fetch, since the server is authoritative.
    func replaceAll(_ highlights: [Highlight], for articleId: Int) {
        loadFromDiskIfNeeded()
        cache[articleId] = highlights
        saveToDisk()
    }

    /// Inserts or updates a single highlight (e.g. after an optimistic create
    /// succeeds, or once a queued create is replayed).
    func upsert(_ highlight: Highlight) {
        loadFromDiskIfNeeded()
        var list = cache[highlight.articleId] ?? []
        if let idx = list.firstIndex(where: { $0.id == highlight.id }) {
            list[idx] = highlight
        } else {
            list.append(highlight)
        }
        cache[highlight.articleId] = list
        saveToDisk()
    }

    /// Removes a single highlight (e.g. after a delete succeeds or replays).
    func remove(id: Int, articleId: Int) {
        loadFromDiskIfNeeded()
        cache[articleId]?.removeAll { $0.id == id }
        saveToDisk()
    }

    /// Wipes the entire cache (e.g. on logout / account change).
    func clear() {
        cache = [:]
        isLoaded = false
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: – Persistence

    /// On-disk representation: a flat list, since `Highlight` already carries
    /// `articleId` — avoids a nested-dictionary JSON shape.
    private func loadFromDiskIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let flat = try? JSONDecoder().decode([Highlight].self, from: data)
        else { return }
        cache = Dictionary(grouping: flat, by: { $0.articleId })
    }

    private func saveToDisk() {
        let flat = cache.values.flatMap { $0 }
        guard let data = try? JSONEncoder().encode(flat) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
