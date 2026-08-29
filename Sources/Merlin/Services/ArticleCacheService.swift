import Foundation

/// Persists Article objects (including full content) to disk so the app
/// remains usable when the device is offline.
///
/// **Eviction policy:** Articles are kept for `PreferencesStore.shared.cacheRetentionDays`
/// days since they were last synced (upserted) locally — applies uniformly to
/// ALL articles regardless of archive/favorite status. User-configurable via
/// Settings → Cache ("Artikel offline speichern", 0–365 Tage). 0 days means
/// nothing is retained beyond the current session. Deleted articles are
/// removed immediately. The cache is an additive merge keyed by article ID —
/// fetching the Unread list does not discard previously cached Favorites, etc.
actor ArticleCacheService {

    static let shared = ArticleCacheService()
    private init() {}

    /// Wraps a cached article with the local timestamp of its last sync –
    /// drives retention-based eviction. `cachedAt` is purely local bookkeeping,
    /// never sent to/received from the server.
    private struct CacheEntry: Codable {
        var article: Article
        var cachedAt: Date
    }

    // MARK: – In-memory store (loaded lazily from disk)

    private var cache: [Int: CacheEntry] = [:]
    private var isLoaded = false

    // MARK: – Disk location

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("merlin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent("article-cache.json")
    }

    // MARK: – Public API

    /// Returns cached articles that match `filter` / `tagId`, evicting stale
    /// entries first.  Returns an empty array when no cache exists yet.
    func loadFiltered(filter: ArticleFilter, tagId: Int?, showArchivedForTag: Bool = false) -> [Article] {
        loadFromDiskIfNeeded()
        evictExpiredInternal()
        let matching = cache.values
            .map(\.article)
            .filter { matches(article: $0, filter: filter, tagId: tagId, showArchivedForTag: showArchivedForTag) }
        if filter == .pagesFavorites || filter == .videosFavorites {
            return matching.sorted { ($0.favoritedAt ?? "") > ($1.favoritedAt ?? "") }
        }
        return matching.sorted { $0.createdAt > $1.createdAt }
    }

    /// All cached articles without any filter (independent of archive/favorite
    /// status or Pages/Videos category) - for fallback lookups that go beyond
    /// the six `ArticleFilter` views, e.g. warming the image cache at launch.
    func loadAllCached() -> [Article] {
        loadFromDiskIfNeeded()
        return cache.values.map(\.article)
    }

    /// Merges a batch of articles into the cache and writes to disk. Refreshes
    /// `cachedAt` for every entry — retention counts from the most recent sync,
    /// not the first time the article was ever cached.
    func upsert(_ articles: [Article]) {
        loadFromDiskIfNeeded()
        let now = Date()
        for a in articles { cache[a.id] = CacheEntry(article: a, cachedAt: now) }
        saveToDisk()
    }

    /// Merges a single article into the cache and writes to disk.
    func upsert(_ article: Article) {
        upsert([article])
    }

    /// Looks up a single cached article by id, independent of any filter
    /// (i.e. works for archived articles too). Used as an offline fallback
    /// when resolving a deep link (e.g. a tapped reminder notification) for
    /// an article that isn't in the caller's currently loaded, filtered list.
    func article(id: Int) -> Article? {
        loadFromDiskIfNeeded()
        return cache[id]?.article
    }

    /// Removes a single article (called after a permanent delete).
    func remove(id: Int) {
        loadFromDiskIfNeeded()
        cache.removeValue(forKey: id)
        saveToDisk()
    }

    /// Explicitly evicts articles past the configured retention window.
    /// Called once at app launch so stale data never accumulates silently.
    func evict() {
        loadFromDiskIfNeeded()
        evictExpiredInternal()
    }

    /// Wipes the entire cache (e.g. on logout / account change).
    func clear() {
        cache = [:]
        isLoaded = false
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: – Eviction

    private func evictExpiredInternal() {
        let retentionDays = PreferencesStore.shared.cacheRetentionDays
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)

        let before = cache.count
        cache = cache.filter { _, entry in entry.cachedAt > cutoff }
        if cache.count != before { saveToDisk() }
    }

    // MARK: – Filter replication (mirrors ArticlesViewModel.fetchForFilter)

    private func matches(article: Article, filter: ArticleFilter, tagId: Int?, showArchivedForTag: Bool = false) -> Bool {
        if let tagId {
            guard article.tags.contains(where: { $0.id == tagId }) else { return false }
            // Einzel-Tag-Ansicht ignoriert den aktiven Filter komplett (siehe
            // `ArticlesViewModel.fetchForFilter`) – stattdessen entscheidet
            // `showArchivedForTag`, ob archivierte Artikel mitgezählt werden.
            return showArchivedForTag || !article.isArchived
        }
        let isVideo = article.category == "Video"
        switch filter {
        case .pagesUnread:     return !article.isArchived && !isVideo
        // Bewusst OHNE isArchived-Bedingung: Favoriten unabhängig vom Archiv-Status.
        case .pagesFavorites:  return  article.isFavorite  && !isVideo
        case .pagesArchive:    return  article.isArchived  && !isVideo
        case .videosUnread:    return !article.isArchived  &&  isVideo
        case .videosFavorites: return  article.isFavorite  &&  isVideo
        case .videosArchive:   return  article.isArchived  &&  isVideo
        }
    }

    // MARK: – Persistence

    private func loadFromDiskIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data    = try? Data(contentsOf: cacheURL),
              let entries = try? JSONDecoder().decode([CacheEntry].self, from: data)
        else { return }
        for e in entries { cache[e.article.id] = e }
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(Array(cache.values)) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
