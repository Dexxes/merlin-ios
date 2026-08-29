import Foundation
import Observation

// MARK: – Undo

/// Describes a single reversible mutation so shake-to-undo can replay it.
struct UndoableAction {
    enum Kind {
        case toggleFavorite
        case toggleArchive
    }
    let kind:        Kind
    let article:     Article   // snapshot BEFORE the mutation
    var description: String {
        switch kind {
        case .toggleFavorite:
            return article.isFavorite ? L("articleList.undo.unfavorite") : L("articleList.undo.favorite")
        case .toggleArchive:
            return article.isArchived ? L("articleList.undo.unarchive") : L("articleList.undo.archive")
        }
    }
}

// MARK: –

/// Zwei oberste Kategorien (Seiten/Videos), je mit eigener Unread(/Unseen)-
/// /Favorites-/Archive-Unteransicht - siehe getCounts() in
/// merlin-standalone-server/src/Db/ArticleRepository.php für das
/// serverseitige Äquivalent dieser Aufteilung.
enum ArticleFilter: String, CaseIterable, Identifiable {
    case pagesUnread     = "PagesUnread"
    case pagesFavorites  = "PagesFavorites"
    case pagesArchive    = "PagesArchive"
    case videosUnread    = "VideosUnread"
    case videosFavorites = "VideosFavorites"
    case videosArchive   = "VideosArchive"

    var id: String { rawValue }

    /// Ob dieser Filter zur Videos- oder zur Seiten-Gruppe gehört (UI-Gruppierung).
    var isVideo: Bool {
        switch self {
        case .videosUnread, .videosFavorites, .videosArchive: return true
        case .pagesUnread, .pagesFavorites, .pagesArchive:     return false
        }
    }

    var label: String {
        switch self {
        case .pagesUnread:     return L("articleList.filter.unread")
        case .pagesFavorites:  return L("articleList.filter.favorites")
        case .pagesArchive:    return L("articleList.filter.archive")
        case .videosUnread:    return L("articleList.filter.unseen")
        case .videosFavorites: return L("articleList.filter.favorites")
        case .videosArchive:   return L("articleList.filter.archive")
        }
    }

    var systemImage: String {
        switch self {
        case .pagesUnread:     return "tray.full"
        case .pagesFavorites:  return "star"
        case .pagesArchive:    return "archivebox"
        case .videosUnread:    return "play.rectangle"
        case .videosFavorites: return "star"
        case .videosArchive:   return "archivebox"
        }
    }

    /// Wert den der Server für diesen Filter verwendet (defaultView-Setting),
    /// identisch zur Web-Oberfläche (siehe App.vue/SettingsController.php in
    /// merlin-nextcloud) und zu `ArticleFilter.serverValue` (Kotlin).
    var serverValue: String {
        switch self {
        case .pagesUnread:     return "pages-unread"
        case .pagesFavorites:  return "pages-favorites"
        case .pagesArchive:    return "pages-archived"
        case .videosUnread:    return "videos-unread"
        case .videosFavorites: return "videos-favorites"
        case .videosArchive:   return "videos-archived"
        }
    }

    /// Aus Server-Wert (z.B. "pages-unread", "videos-favorites") in iOS-Filter konvertieren.
    static func fromServerValue(_ value: String) -> ArticleFilter {
        switch value {
        case "pages-unread":     return .pagesUnread
        case "pages-favorites":  return .pagesFavorites
        case "pages-archived":   return .pagesArchive
        case "videos-unread":    return .videosUnread
        case "videos-favorites": return .videosFavorites
        case "videos-archived":  return .videosArchive
        // Legacy-Werte aus der Zeit vor der Pages/Videos-Aufteilung.
        case "favorites":        return .pagesFavorites
        case "video":            return .videosUnread
        default:                 return .pagesUnread
        }
    }
}

@MainActor
@Observable
final class ArticlesViewModel {

    // MARK: – Init

    init() {
        // Evict stale cache entries (archived > 24 h ago) once per app launch.
        Task { await ArticleCacheService.shared.evict() }
        // Retroactively prefetch images for all currently cached unread articles
        // so offline reading works immediately, even for articles from prior sessions.
        Task.detached(priority: .background) {
            let cached = await ArticleCacheService.shared.loadAllCached()
            await ImageCacheService.shared.prefetch(for: cached)
        }
        // When the NWPathMonitor fires a drain (connectivity restored between loads),
        // reload so the UI reflects the server-reconciled state.
        OfflineMutationQueue.shared.onDrained = { [weak self] in
            await self?.load()
        }
        // Touch the highlight- and settings-sync queues so their NWPathMonitors
        // start at launch — otherwise a "needs sync" flag left over from a
        // previous offline session would only get retried after the *next*
        // local edit, instead of as soon as connectivity returns.
        _ = OfflineHighlightQueue.shared
        _ = SettingsSyncQueue.shared
        _ = ProgressSyncQueue.shared
    }

    // MARK: – State

    /// Whether the current article list was served from the local cache
    /// (i.e. the device is offline).
    private(set) var isOffline = false

    var articles: [Article] = []
    var selectedFilter: ArticleFilter = PreferencesStore.shared.defaultFilter
    var searchQuery: String = ""
    var isLoading = false
    var error: String? = nil
    var counts = ArticleCounts()

    /// Tag-IDs, deren Artikel aus der Liste ausgeblendet werden.
    /// Wird automatisch in UserDefaults persistiert.
    var excludedTagIds: Set<Int> = PreferencesStore.shared.excludedTagIds {
        didSet { PreferencesStore.shared.excludedTagIds = excludedTagIds }
    }

    // MARK: – Undo stack

    /// The last reversible action.  Replaced on every new mutation, cleared after undo.
    private(set) var lastUndoableAction: UndoableAction? = nil
    /// Toast shown after a successful undo ("Rückgängig: Archivieren")
    var undoToast: String? = nil
    /// Confirmation banner after a user-initiated archive/unarchive, with an
    /// inline undo button (more discoverable than shake-to-undo).
    var archiveToast: String? = nil
    /// Guards the auto-clear against racing a newer toast of the same kind.
    private var archiveToastToken = UUID()

    var canUndo: Bool { lastUndoableAction != nil }

    /// Shows the archive confirmation and auto-clears it after 4 s — long
    /// enough to reach the inline undo button.
    private func showArchiveToast(_ message: String) {
        archiveToast = message
        let token = UUID()
        archiveToastToken = token
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if archiveToastToken == token { archiveToast = nil }
        }
    }

    /// Reverses the last recorded action and reloads the list.
    func undo() async {
        guard let action = lastUndoableAction else { return }
        lastUndoableAction = nil   // consume immediately so double-shake is a no-op
        archiveToast = nil         // the confirmation is obsolete once undone

        switch action.kind {
        case .toggleFavorite: await toggleFavorite(action.article, recordUndo: false)
        case .toggleArchive:  await toggleArchive(action.article,  recordUndo: false)
        }

        // Always reload so the article list reflects the reverted server state.
        await load()

        undoToast = action.description
        // Auto-clear toast after 2.5 s
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            undoToast = nil
        }
    }

    // MARK: – Computed

    var filteredArticles: [Article] {
        var result = articles

        // Artikel mit ausgeblendeten Tags entfernen
        if !excludedTagIds.isEmpty {
            result = result.filter { article in
                article.tags.allSatisfy { !excludedTagIds.contains($0.id) }
            }
        }

        guard !searchQuery.isEmpty else { return result }
        let q = searchQuery.lowercased()
        return result.filter {
            $0.displayTitle.lowercased().contains(q) ||
            ($0.excerpt?.lowercased().contains(q) ?? false) ||
            ($0.siteName?.lowercased().contains(q) ?? false)
        }
    }

    /// Schaltet den Exclusion-Filter für einen Tag um.
    func toggleTagExclusion(_ tagId: Int) {
        if excludedTagIds.contains(tagId) {
            excludedTagIds.remove(tagId)
        } else {
            excludedTagIds.insert(tagId)
        }
    }

    // MARK: – Load

    func load() async {
        prefetchTask?.cancel()
        isLoading = true
        error = nil
        do {
            let fetched = try await fetchForFilter(selectedFilter)
            counts      = try await MerlinAPI.shared.getCounts()
            articles    = fetched
            isOffline   = false
            // Persist to cache so offline reads work later.
            await ArticleCacheService.shared.upsert(fetched)
            prefetchImages(for: fetched)
            startProcessingListenerIfNeeded()
            // Replay any mutations that were queued while offline.
            await OfflineMutationQueue.shared.drain()
        } catch {
            // Network failed – serve from the local cache if available.
            let cached = await ArticleCacheService.shared.loadFiltered(
                filter: selectedFilter, tagId: selectedTagId, showArchivedForTag: showArchivedInTagView)
            if !cached.isEmpty {
                articles  = cached
                isOffline = true
                // Don't overwrite `counts` – keep whatever we have from the last online session.
            } else {
                isOffline       = false
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func fetchForFilter(_ filter: ArticleFilter) async throws -> [Article] {
        if let tagId = selectedTagId {
            // In der Einzel-Tag-Ansicht blendet `showArchivedInTagView` archivierte
            // Artikel standardmäßig aus (sonst mischt der Server Archiv + Aktiv,
            // da `isArchived` beim Tag-Filter sonst gar nicht gesetzt wird).
            return try await MerlinAPI.shared.getArticles(
                isArchived: showArchivedInTagView ? nil : false, tagId: tagId)
        }
        let contentType = filter.isVideo ? "video" : "page"
        switch filter {
        case .pagesUnread, .videosUnread:
            return try await MerlinAPI.shared.getArticles(isArchived: false, contentType: contentType)
        case .pagesFavorites, .videosFavorites:
            // Bewusst OHNE isArchived-Filter: Favoriten sollen unabhängig vom
            // Archiv-Status angezeigt werden. Chronologisch nach
            // Favorisierungszeitpunkt sortieren (Server sortiert bereits so,
            // client-seitig hier abgesichert – analog zum .archive-Fall unten).
            let fetched = try await MerlinAPI.shared.getArticles(isFavorite: true, contentType: contentType)
            return fetched.sorted { ($0.favoritedAt ?? "") > ($1.favoritedAt ?? "") }
        case .pagesArchive, .videosArchive:
            let fetched = try await MerlinAPI.shared.getArticles(isArchived: true, contentType: contentType)
            return fetched.sorted { ($0.archivedAt ?? "") > ($1.archivedAt ?? "") }
        }
    }

    // MARK: – Tags

    var allTags: [Tag] = []
    var selectedTagId: Int? = nil

    /// Blendet archivierte Artikel innerhalb der Einzel-Tag-Ansicht ein/aus
    /// (Toggle über den Augen-Button in `ArticleListView`, siehe dort).
    /// Startzustand bewusst `false` – konsistent mit der normalen Liste, die
    /// archivierte Artikel ebenfalls nicht standardmäßig mischt.
    var showArchivedInTagView: Bool = false

    var selectedTagName: String? {
        guard let id = selectedTagId else { return nil }
        return allTags.first(where: { $0.id == id })?.name
    }

    func loadTags() async {
        allTags = (try? await MerlinAPI.shared.getTags()) ?? []
    }

    func selectTag(_ tagId: Int?) async {
        selectedTagId = tagId
        showArchivedInTagView = false // frischer Start pro Tag/Tag-Wechsel
        await load()
    }

    // MARK: – Add

    func addArticle(url: String, tagIds: [Int] = []) async throws {
        let article = try await MerlinAPI.shared.createArticle(url: url, tagIds: tagIds)
        articles.insert(article, at: 0)
        // Kategorie steht erst nach der (async) Extraktion fest - optimistisch als
        // Seite zählen, der nächste Server-Fetch korrigiert bei Bedarf.
        counts.pages.total += 1
        await ArticleCacheService.shared.upsert(article)
        prefetchImages(for: [article])
        startProcessingListenerIfNeeded()
    }

    /// Retries extraction for an article that got stuck without content
    /// (server-side extraction failed once and gave up, e.g. because of a
    /// transient network error while fetching the source URL). Called from
    /// the "no content" empty state in `ArticleReaderView`.
    func retryExtraction(_ article: Article) async {
        guard let refreshed = try? await MerlinAPI.shared.retryExtraction(article.id) else { return }
        applyUpdate(refreshed)
        await ArticleCacheService.shared.upsert(refreshed)
        startProcessingListenerIfNeeded()
    }

    // MARK: – Processing listener

    /// Stored handle for the active image prefetch task.
    private var prefetchTask: Task<Void, Never>?

    /// Persists all images (hero, favicon, content) for the given articles to
    /// disk via `ImageCacheService`.  Supersedes the old `URLCache`-based
    /// thumbnail warm-up.
    private func prefetchImages(for articles: [Article]) {
        prefetchTask?.cancel()
        prefetchTask = Task.detached(priority: .utility) {
            await ImageCacheService.shared.prefetch(for: articles)
        }
    }

    /// Stored handle for the active polling task.
    /// Prevents duplicate concurrent tasks when called multiple times.
    private var processingListenerTask: Task<Void, Never>?

    /// Polls the server every 2 seconds until every article that shows a
    /// loading spinner has finished processing.  Any existing listener is
    /// cancelled before a new one starts so there is never more than one
    /// polling loop running at a time.
    ///
    /// Polling is used instead of SSE here because the SSE endpoint holds
    /// the HTTP connection open for up to 55 s, which means the client gets
    /// no update until the server closes the stream — effectively delaying
    /// the spinner removal by up to a minute on slow or misconfigured
    /// proxies.  Polling every 2 s is simpler, always reliable, and the
    /// extra API traffic is negligible (a few lightweight GET requests per
    /// article save).
    func startProcessingListenerIfNeeded() {
        guard articles.contains(where: { $0.isProcessing }) else { return }
        processingListenerTask?.cancel()
        processingListenerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.articles.contains(where: { $0.isProcessing }) {
                // Wait before each poll so the server has time to start
                // extraction and so we don't hammer the API on every loop tick.
                try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 s
                guard !Task.isCancelled else { break }
                for id in self.articles.filter({ $0.isProcessing }).map({ $0.id }) {
                    if let refreshed = try? await MerlinAPI.shared.getArticle(id) {
                        self.applyUpdate(refreshed)
                        // Cache the now-complete article (includes extracted content).
                        await ArticleCacheService.shared.upsert(refreshed)
                        await ImageCacheService.shared.prefetch(for: [refreshed])
                    }
                }
            }
            self.processingListenerTask = nil
        }
    }

    // MARK: – Mutations

    func toggleFavorite(_ article: Article, recordUndo: Bool = true) async {
        if recordUndo { lastUndoableAction = UndoableAction(kind: .toggleFavorite, article: article) }

        // Optimistic update — also reconciles list membership for the active
        // filter, e.g. un-favoriting while viewing "Favoriten" hides the row
        // immediately instead of leaving a stale entry until the next reload.
        var optimistic = article
        optimistic.setFavorite(!article.isFavorite)
        applyListMembership(optimistic)
        HapticFeedback.lightTap()

        do {
            let updated = try await MerlinAPI.shared.toggleFavorite(article.id)
            applyListMembership(updated)
            await ArticleCacheService.shared.upsert(updated)
        } catch {
            if isNetworkError(error) {
                // Keep optimistic state; sync when back online. Persist the
                // optimistic article to the offline cache too, so relaunching
                // the app while still offline shows the pending state instead
                // of the stale server state from before the toggle.
                await ArticleCacheService.shared.upsert(optimistic)
                OfflineMutationQueue.shared.enqueue(
                    PendingMutation(articleId: article.id, kind: .toggleFavorite))
            } else {
                // Real server error: roll back, restoring the row if the
                // optimistic update had hidden it from the current filter.
                reinsertIfMissing(article)
                self.error = error.localizedDescription
            }
        }
    }

    func toggleArchive(_ article: Article, recordUndo: Bool = true) async {
        if recordUndo { lastUndoableAction = UndoableAction(kind: .toggleArchive, article: article) }

        // Optimistic update: flip the state immediately before the network call.
        let willBeArchived = !article.isArchived
        var optimistic = article
        optimistic.isArchived = willBeArchived
        optimistic.archivedAt = willBeArchived ? ISO8601DateFormatter().string(from: Date()) : nil
        applyListMembership(optimistic)
        HapticFeedback.mediumTap()

        // Confirmation toast only for user-initiated toggles (undo() calls with
        // recordUndo: false and shows its own "Rückgängig: …" toast instead).
        if recordUndo {
            showArchiveToast(willBeArchived
                ? L("articleList.archiveToast.archived")
                : L("articleList.archiveToast.unarchived"))
        }

        do {
            let updated = try await MerlinAPI.shared.toggleArchive(article.id)
            // Reconcile with the server's authoritative response.
            applyListMembership(updated)
            // archivedAt is now set on the server – upsert so the cache records
            // the timestamp and eviction works correctly.
            await ArticleCacheService.shared.upsert(updated)
            if updated.isArchived {
                // Evict images immediately – archived articles won't be read offline.
                await ImageCacheService.shared.evict(articleId: updated.id)
            }
            await refreshCounts()
        } catch {
            if isNetworkError(error) {
                // Keep optimistic state; sync when back online. Persist the
                // optimistic article to the offline cache too, so relaunching
                // the app while still offline shows the pending state instead
                // of the stale server state from before the toggle.
                await ArticleCacheService.shared.upsert(optimistic)
                OfflineMutationQueue.shared.enqueue(
                    PendingMutation(articleId: article.id, kind: .toggleArchive))
            } else {
                // Real server error: roll back, restoring the row if the
                // optimistic update had hidden it from the current filter.
                reinsertIfMissing(article)
                self.error = error.localizedDescription
            }
        }
    }

    /// Applies `article` and reconciles its membership in the currently
    /// visible list: rows the active filter would hide are removed right
    /// away — mirrors the server-side filtering in `fetchForFilter` /
    /// `ArticleCacheService.matches`, so optimistic updates and
    /// server-reconciled updates behave identically.
    private func applyListMembership(_ article: Article) {
        if shouldHide(article, in: selectedFilter) {
            articles.removeAll { $0.id == article.id }
        } else {
            applyUpdate(article)
        }
    }

    /// Whether `article` would be hidden by `filter`. Shared by
    /// `applyListMembership` (to drop rows optimistically) and
    /// `reinsertIfMissing` (to decide whether a rolled-back row needs
    /// restoring).
    private func shouldHide(_ article: Article, in filter: ArticleFilter) -> Bool {
        let isVideo = article.category == "Video"
        switch filter {
        case .pagesUnread:     return article.isArchived || isVideo
        case .pagesFavorites:  return !article.isFavorite || isVideo
        case .pagesArchive:    return !article.isArchived || isVideo
        case .videosUnread:    return article.isArchived || !isVideo
        case .videosFavorites: return !article.isFavorite || !isVideo
        case .videosArchive:   return !article.isArchived || !isVideo
        }
    }

    /// Restores `article` to the list — in roughly sorted position — if the
    /// active filter would show it and it isn't currently present. Used to
    /// undo an optimistic removal when the server call ultimately fails with
    /// a real (non-network) error; without this, `applyUpdate` alone is a
    /// no-op for rows that were already removed, leaving them stuck hidden
    /// until the next full reload.
    private func reinsertIfMissing(_ article: Article) {
        guard !shouldHide(article, in: selectedFilter) else { return }
        guard !articles.contains(where: { $0.id == article.id }) else {
            applyUpdate(article)
            return
        }
        let idx: Int
        if selectedFilter == .pagesArchive || selectedFilter == .videosArchive {
            idx = articles.firstIndex { ($0.archivedAt ?? "") < (article.archivedAt ?? "") } ?? articles.endIndex
        } else {
            idx = articles.firstIndex { $0.createdAt < article.createdAt } ?? articles.endIndex
        }
        articles.insert(article, at: idx)
    }

    func delete(_ article: Article) async {
        // Optimistic removal — mirrors the toggle/archive pattern so the row
        // disappears immediately regardless of connectivity. Remember its
        // index so a real server error can restore it in place.
        let removedIndex = articles.firstIndex { $0.id == article.id }
        if let removedIndex { articles.remove(at: removedIndex) }
        HapticFeedback.heavyTap()

        do {
            try await MerlinAPI.shared.deleteArticle(article.id)
            await ArticleCacheService.shared.remove(id: article.id)
            await ImageCacheService.shared.evict(articleId: article.id)
            await refreshCounts()
        } catch {
            if isNetworkError(error) {
                // Keep the optimistic removal and queue the delete for replay
                // once we're back online. Drop it from the offline cache too —
                // otherwise a relaunch while offline would resurrect the row
                // from stale cached data even though it's queued for deletion.
                // (Counts will reconcile via `onDrained` → `load()` once the
                // queue drains; not worth guessing the exact deltas here.)
                await ArticleCacheService.shared.remove(id: article.id)
                await ImageCacheService.shared.evict(articleId: article.id)
                OfflineMutationQueue.shared.enqueue(
                    PendingMutation(articleId: article.id, kind: .delete))
            } else {
                // Real server error: restore the row where it was.
                if let removedIndex {
                    articles.insert(article, at: min(removedIndex, articles.count))
                }
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: – Tag editing

    /// Diffs the article's current tags against `tagIds` and applies adds/removes.
    func setTags(for article: Article, tagIds: Set<Int>) async {
        // Optimistic update: build a patched article with the new tag set.
        let desiredTagObjects = allTags.filter { tagIds.contains($0.id) }
        var optimistic = article
        optimistic.tags = desiredTagObjects
        applyUpdate(optimistic)

        // Diff against server-fresh state rather than the `article` snapshot
        // the caller captured when the tag sheet was opened. That snapshot
        // can go stale (another device, or another mutation on this device,
        // changed the article's tags in the meantime); diffing against it
        // would treat a tag added elsewhere as "should be removed" and wipe
        // it out here. Falls back to the passed-in snapshot when offline.
        let baseline = (try? await MerlinAPI.shared.getArticle(article.id)) ?? article
        let currentIds = Set(baseline.tags.map { $0.id })
        let toAdd    = tagIds.subtracting(currentIds)
        let toRemove = currentIds.subtracting(tagIds)
        do {
            for id in toAdd    { try await MerlinAPI.shared.addTagToArticle(articleId: article.id, tagId: id) }
            for id in toRemove { try await MerlinAPI.shared.removeTagFromArticle(articleId: article.id, tagId: id) }
            // Refresh to pick up server-canonical state.
            if let refreshed = try? await MerlinAPI.shared.getArticle(article.id) {
                applyUpdate(refreshed)
                await ArticleCacheService.shared.upsert(refreshed)
            }
        } catch {
            if isNetworkError(error) {
                // Keep optimistic state; sync when back online. Persist it to
                // the offline cache too, so a relaunch while offline shows the
                // pending tag set instead of the stale server state.
                await ArticleCacheService.shared.upsert(optimistic)
                // Queue the actual delta, not the absolute desired set — see
                // PendingMutation's doc comment. Replay must only touch the
                // tags the user acted on here, never anything added by
                // another client while this device was offline.
                if !toAdd.isEmpty || !toRemove.isEmpty {
                    OfflineMutationQueue.shared.enqueue(
                        PendingMutation(articleId: article.id, kind: .setTags,
                                        addTagIds: Array(toAdd), removeTagIds: Array(toRemove)))
                }
            } else {
                applyUpdate(article)   // roll back
                self.error = error.localizedDescription
            }
        }
        // Reload the master tag list so newly created tags are available for
        // subsequent ArticleTagSheet presentations (Bug #2).
        await loadTags()
    }

    // MARK: – Helpers

    private func applyUpdate(_ updated: Article) {
        if let idx = articles.firstIndex(where: { $0.id == updated.id }) {
            articles[idx] = updated
        }
    }

    private func isNetworkError(_ error: Error) -> Bool {
        if case MerlinAPIError.networkError = error { return true }
        return false
    }

    private func refreshCounts() async {
        if let newCounts = try? await MerlinAPI.shared.getCounts() {
            counts = newCounts
        }
    }
}
