import SwiftUI

struct ArticleListView: View {
    @Environment(AppNavigator.self) private var navigator
    @Environment(ArticlesViewModel.self) private var viewModel
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var piperTTS = PiperAudioService()

    @State private var selectedArticle: Article? = nil
    @State private var tagSheetArticle: Article? = nil
    @State private var showAddSheet:    Bool = false
    @State private var showSettings:    Bool = false
    @State private var showTagFilter:   Bool = false
    @State private var activeSwipeId: Int? = nil
    // Custom pull-to-refresh tracking for the card grid — see articleGrid below.
    @State private var cardPullDistance: CGFloat = 0
    @State private var cardRefreshTriggered = false
    private let cardRefreshThreshold: CGFloat = 60
    @AppStorage("merlinIsCardView") private var isCardView: Bool = true
    @AppStorage("merlin_tour_done") private var tourDone: Bool = false
    @AppStorage("merlin_developer_mode") private var developerMode: Bool = false
    @State private var showTour = false

    var body: some View {
        NavigationStack {
            Group {
                if !CredentialsStore.shared.isConfigured {
                    unconfiguredView
                } else if viewModel.filteredArticles.isEmpty && !viewModel.isLoading {
                    emptyView
                } else {
                    if isCardView { articleGrid } else { articleList }
                }
            }
            .navigationTitle(viewModel.selectedFilter.label)
            .navigationBarTitleDisplayMode(.inline)
            // placement: .always verhindert, dass die Suchleiste beim Scrollen
            // ein-/ausklappt (Standardverhalten bei .automatic). Dieses dynamische
            // Ein-/Ausblenden kollidiert mit der Positionsberechnung von
            // .refreshable, wodurch der Ladeindikator beim Pull-to-Refresh
            // zunächst über der Suchleiste erscheint und dann darunter springt.
            .searchable(
                text: Bindable(viewModel).searchQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(L("articleList.searchPlaceholder"))
            )
            .toolbar {
                // Logo + filter name as custom navigation title
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        if let uiImage = UIImage(named: "AppIcon") {
                            Image(uiImage: uiImage)
                                .resizable()
                                .frame(width: 26, height: 26)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        if let tagName = viewModel.selectedTagName {
                            Label(tagName, systemImage: "tag.fill")
                                .font(.headline)
                        } else {
                            Text(viewModel.selectedFilter.label)
                                .font(.headline)
                        }
                    }
                }

                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        // In der Einzel-Tag-Ansicht übernimmt derselbe Button die
                        // Archiv-Sichtbarkeit für diesen Tag statt des Tag-Filter-Sheets
                        // (das dort keinen Sinn ergibt, da bereits auf einen Tag gefiltert ist).
                        if viewModel.selectedTagId != nil {
                            viewModel.showArchivedInTagView.toggle()
                            Task { await viewModel.load() }
                        } else {
                            showTagFilter = true
                        }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: viewModel.selectedTagId != nil
                                  ? (viewModel.showArchivedInTagView ? "eye" : "eye.slash")
                                  : "eye.slash")
                                .font(.system(size: 16))
                            if viewModel.selectedTagId == nil, !viewModel.excludedTagIds.isEmpty {
                                Text("\(viewModel.excludedTagIds.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(.blue, in: Capsule())
                                    .offset(x: 8, y: -6)
                            }
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .task {
                if viewModel.articles.isEmpty {
                    await viewModel.load()
                }
                if viewModel.allTags.isEmpty {
                    await viewModel.loadTags()
                }
            }
            .onChange(of: viewModel.selectedFilter) { _, _ in
                Task { await viewModel.load() }
            }
            .onChange(of: scenePhase) { old, new in
                // Reload whenever the app comes back from the background / a task
                // so the list always reflects the latest articles.
                if old != .active && new == .active && !viewModel.articles.isEmpty {
                    Task { await viewModel.load() }
                }
            }
            .alert(L("common.error"), isPresented: .init(
                get: { viewModel.error != nil },
                set: { if !$0 { viewModel.error = nil } }
            )) {
                Button(L("common.ok")) { viewModel.error = nil }
            } message: {
                Text(viewModel.error ?? "")
            }
            .sheet(isPresented: $showAddSheet) {
                AddArticleSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                guard CredentialsStore.shared.isConfigured else { return }
                Task { await viewModel.load() }
            }) {
                SettingsView()
            }
            // Deep-link: notification tapped → open article
            .onChange(of: navigator.articleIdToOpen) { _, id in
                openArticle(id: id)
            }
            .onChange(of: viewModel.articles) { _, _ in
                // Retry after articles finish loading (app was cold-started by tap)
                openArticle(id: navigator.articleIdToOpen)
            }
            .sheet(isPresented: $showTagFilter) {
                TagFilterSheet(
                    allTags: viewModel.allTags,
                    excludedTagIds: viewModel.excludedTagIds,
                    onToggle: { tagId in viewModel.toggleTagExclusion(tagId) },
                    onClearAll: { viewModel.excludedTagIds.removeAll() }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $tagSheetArticle) { article in
                ArticleTagSheet(
                    article: article,
                    allTags: viewModel.allTags
                ) { tagIds in
                    Task { await viewModel.setTags(for: article, tagIds: tagIds) }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(item: $selectedArticle) { article in
                ArticleReaderView(
                    article: article,
                    initialFraction: resolvedInitialFraction(for: article),
                    viewModel: viewModel,
                    onNavigateNext: nextArticle(after: article).map { next in { selectedArticle = next } },
                    piperTTS: piperTTS
                )
            }
            // ── Shake-to-undo ──────────────────────────────────────────────
            .onShake {
                guard viewModel.canUndo else { return }
                Task { await viewModel.undo() }
            }
            .overlay(alignment: .top) {
                // Undo confirmation wins over the archive confirmation — undo()
                // clears archiveToast, so both never compete for the slot.
                if let msg = viewModel.undoToast {
                    UndoToast(message: msg)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.undoToast)
                        .padding(.top, 8)
                } else if let msg = viewModel.archiveToast {
                    ArchiveToast(message: msg) {
                        Task { await viewModel.undo() }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.archiveToast)
                    .padding(.top, 8)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if piperTTS.hasContent {
                persistentMiniPlayer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: piperTTS.hasContent)
        .listFlyout(viewModel: viewModel)
        .overlay {
            if showTour {
                OnboardingTourView(isPresented: $showTour)
                    .ignoresSafeArea()
                    .zIndex(100)
            }
        }
        .onAppear {
            if !tourDone || developerMode { showTour = true }
        }
        .onChange(of: tourDone) { _, done in
            if !done { showTour = true }
        }
    }

    // MARK: – Sub-views

    // MARK: Persistent mini player (visible in list while audio plays in background)

    private var currentlyPlayingTitle: String? {
        guard let id = piperTTS.currentArticleId else { return nil }
        return viewModel.articles.first(where: { $0.id == id })?.title
    }

    private var persistentMiniPlayer: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 6) {
                // ── Controls row ─────────────────────────────────────────────
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    // Scrolling article title
                    MarqueeText(
                        text: currentlyPlayingTitle ?? L("articleList.miniPlayer.fallbackTitle"),
                        font: .caption.weight(.medium)
                    )
                    .foregroundStyle(.primary)

                    // Play/pause or loading spinner
                    if piperTTS.isPlaying || piperTTS.isPaused {
                        Button { piperTTS.togglePlayPause() } label: {
                            Image(systemName: piperTTS.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 30, height: 30)
                        }
                    } else if piperTTS.isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                            .frame(width: 30, height: 30)
                    }

                    // Stop button
                    Button { piperTTS.stop() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 30)
                    }
                }

                // ── Progress bar (indented to align with title) ───────────────
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 3)
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * piperTTS.progress, height: 3)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 3)
                .padding(.leading, 30) // align with title
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .contentShape(Rectangle())
            .onTapGesture {
                if let articleId = piperTTS.currentArticleId,
                   let article = viewModel.articles.first(where: { $0.id == articleId }) {
                    selectedArticle = article
                }
            }
        }
    }

    private var articleGrid: some View {
        // Echte List-Zeilen statt eines einzelnen LazyVGrid als Row-Inhalt:
        // GridItem(.flexible()) ist ohnehin nur eine Spalte, das LazyVGrid
        // stapelt die Karten also nur vertikal wie eine Liste. Als einzelne
        // List-Zeile verwirrte das aber die Positionsberechnung von
        // .refreshable in Kombination mit .searchable (Ladeindikator sprang
        // über die Suchleiste). Mit echten, mehreren List-Zeilen pro Artikel
        // – wie in articleList – verhält sich der Refresh-Control korrekt.
        List(viewModel.filteredArticles) { article in
            ArticleCardView(
                article: article,
                activeSwipeId: $activeSwipeId,
                onToggleFavorite: { Task { await viewModel.toggleFavorite(article) } },
                onToggleArchive:  { Task { await viewModel.toggleArchive(article) } },
                onDelete:         { Task { await viewModel.delete(article) } },
                onEditTags:       { tagSheetArticle = article },
                onTap:            { selectedArticle = article },
                showFavoriteAction: viewModel.selectedFilter != .pagesFavorites && viewModel.selectedFilter != .videosFavorites,
                showArchiveAction:  viewModel.selectedFilter != .pagesArchive && viewModel.selectedFilter != .videosArchive
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Custom pull-to-refresh instead of .refreshable: the native UIRefreshControl
        // it produces still renders misplaced next to .searchable's search bar (the
        // iOS 26 SwiftUI bug noted on ArticleCardView's RowSwipeGesture), and there's
        // no supported way to reposition or hide just that one control. Tracking the
        // pull ourselves sidesteps it — there's no native control left to go wrong,
        // and our own indicator can fade in from the very first pixel of the pull
        // instead of only appearing once the load is already under way.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
        } action: { _, newValue in
            cardPullDistance = newValue
        }
        .onChange(of: cardPullDistance) { _, newValue in
            if newValue >= cardRefreshThreshold, !cardRefreshTriggered {
                cardRefreshTriggered = true
                Task { await viewModel.load() }
            } else if newValue < 4 {
                // Back near rest (released without reaching the threshold, or the
                // triggered load already sprang the list back) — re-arm for the
                // next pull.
                cardRefreshTriggered = false
            }
        }
        .overlay(alignment: .top) {
            // Fades in as the user pulls, sitting in the gap the List's own bounce
            // already reveals above the first row — no space reservation needed
            // here, unlike the isLoading state below.
            if cardPullDistance > 0, !viewModel.isLoading {
                ProgressView()
                    .padding(.top, 10)
                    .opacity(min(1, cardPullDistance / cardRefreshThreshold))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Once the finger lifts the List springs back to rest immediately
            // (no .refreshable holding it open), so reserve real space here for
            // however long the load actually takes.
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(.systemGroupedBackground))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isLoading)
        .background(Color(.systemGroupedBackground))
    }

    private var articleList: some View {
        List(viewModel.filteredArticles) { article in
            Button {
                selectedArticle = article
            } label: {
                ArticleRowView(
                    article: article,
                    activeSwipeId: $activeSwipeId,
                    showThumbnail:      true,
                    onToggleFavorite:   { Task { await viewModel.toggleFavorite(article) } },
                    onToggleArchive:    { Task { await viewModel.toggleArchive(article) } },
                    onDelete:           { Task { await viewModel.delete(article) } },
                    onEditTags:         { tagSheetArticle = article },
                    showFavoriteAction: viewModel.selectedFilter != .pagesFavorites && viewModel.selectedFilter != .videosFavorites,
                    showArchiveAction:  viewModel.selectedFilter != .pagesArchive && viewModel.selectedFilter != .videosArchive
                )
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .refreshable { await viewModel.load() }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.selectedFilter.systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(L("articleList.emptyState.title"))
                .font(.headline)
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(L("articleList.emptyState.refreshButton")) {
                Task { await viewModel.load() }
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unconfiguredView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(L("articleList.unconfigured.title"))
                .font(.headline)
            Text(L("articleList.unconfigured.message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(L("articleList.unconfigured.openSettingsButton")) {
                showSettings = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: – Helpers

    private var emptyMessage: String {
        if let name = viewModel.selectedTagName {
            return String(format: L("articleList.emptyState.taggedMessage"), name)
        }
        switch viewModel.selectedFilter {
        case .pagesContinue:   return L("articleList.emptyState.continueReadingMessage")
        case .pagesUnread:     return L("articleList.emptyState.allMessage")
        case .pagesFavorites:  return L("articleList.emptyState.favoritesMessage")
        case .pagesArchive:    return L("articleList.emptyState.archiveMessage")
        case .videosContinue:  return L("articleList.emptyState.continueWatchingMessage")
        case .videosUnread:    return L("articleList.emptyState.unseenMessage")
        case .videosFavorites: return L("articleList.emptyState.favoritesMessage")
        case .videosArchive:   return L("articleList.emptyState.archiveMessage")
        }
    }

    private func nextArticle(after article: Article) -> Article? {
        let list = viewModel.filteredArticles
        guard let idx = list.firstIndex(where: { $0.id == article.id }),
              idx + 1 < list.count else { return nil }
        return list[idx + 1]
    }

    /// Löst die wiederherzustellende Leseposition (Fraktion 0…1) aus lokalem und
    /// Server-Wert per Last-Write-Wins auf: der Eintrag mit dem neueren
    /// `scrollUpdatedAt` gewinnt. Respektiert die `resumeOnOpen`-Einstellung.
    /// Hinweis: nutzt den Server-Wert aus dem (ggf. zuletzt aktualisierten)
    /// Listen-Artikel – eine an einem anderen Gerät gespeicherte Position wird
    /// also erst nach einem Listen-Refresh sichtbar.
    private func resolvedInitialFraction(for article: Article) -> CGFloat {
        guard PreferencesStore.shared.resumeOnOpen else { return 0 }
        let localTs  = PreferencesStore.shared.savedScrollTimestamp(for: article.id)
        let localPct = PreferencesStore.shared.savedScrollProgress(for: article.id)
        let serverTs  = article.scrollUpdatedAt ?? 0
        let serverPct = CGFloat(article.scrollProgress ?? 0)
        return serverTs > localTs ? serverPct : localPct
    }

    /// Opens the article with `id`, resolving it from the loaded list, a direct
    /// fetch, or the offline cache (in that order); clears the navigator request.
    private func openArticle(id: Int?) {
        guard let id else { return }
        if let article = viewModel.articles.first(where: { $0.id == id }) {
            selectedArticle = article
            navigator.articleIdToOpen = nil
            return
        }
        // Not in the currently loaded (filtered) list. This happens e.g. when a
        // reminder fires for an article that was archived in the meantime: the
        // default "All"/Unread filter excludes archived articles, so the lookup
        // above silently found nothing and the notification tap used to appear
        // to do nothing. Fall back to fetching the article directly by id
        // (archive status doesn't restrict single-article GETs), then fall back
        // to the offline cache (which is not filter-scoped) if we're offline.
        Task {
            if let fetched = try? await MerlinAPI.shared.getArticle(id) {
                selectedArticle = fetched
                navigator.articleIdToOpen = nil
            } else if let cached = await ArticleCacheService.shared.article(id: id) {
                selectedArticle = cached
                navigator.articleIdToOpen = nil
            } else {
                // Article is truly gone (deleted) — clear the pending deep link
                // so we stop retrying, rather than leaving it dangling.
                navigator.articleIdToOpen = nil
            }
        }
    }
}

// MARK: – Marquee text (horizontal ticker for long titles)

private struct MarqueeWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Zeigt kurzen Text statisch; ist der Text breiter als der Container, scrollt er
/// wie ein Ticker kontinuierlich von rechts nach links und wiederholt sich nahtlos.
private struct MarqueeText: View {
    let text: String
    let font: Font

    @State private var offset:          CGFloat = 0
    @State private var textWidth:       CGFloat = 0
    @State private var containerWidth:  CGFloat = 0

    /// Punkte pro Sekunde (Scrollgeschwindigkeit)
    private let speed:   CGFloat = 38
    /// Lücke zwischen den beiden Kopien des Textes
    private let spacing: CGFloat = 48

    private var needsScroll: Bool { textWidth > containerWidth && containerWidth > 0 }
    private var cycleDuration: Double { Double(textWidth + spacing) / Double(speed) }

    var body: some View {
        ZStack(alignment: .leading) {
            if needsScroll {
                // Zwei Kopien nebeneinander für nahtlosen Loop
                HStack(spacing: spacing) {
                    Text(text).fixedSize().lineLimit(1)
                    Text(text).fixedSize().lineLimit(1)
                }
                .font(font)
                .offset(x: offset)
            } else {
                Text(text).font(font).lineLimit(1)
            }
        }
        .clipped()
        // GeometryReader im Hintergrund: liest Breite, ohne die Höhe zu beeinflussen
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { containerWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in containerWidth = w }
        })
        // Unsichtbarer Text zum Messen der echten Textbreite
        .background(
            Text(text).font(font).fixedSize().lineLimit(1).hidden()
                .background(GeometryReader { g in
                    Color.clear.preference(key: MarqueeWidthKey.self, value: g.size.width)
                })
        )
        .onPreferenceChange(MarqueeWidthKey.self) { textWidth = $0 }
        // Task auf ZStack-Ebene: startet neu wenn Text oder Scroll-Bedarf sich ändern
        .task(id: "\(text)|\(needsScroll)") {
            offset = 0
            guard needsScroll else { return }
            // Kurze Pause bevor das Scrollen beginnt
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            while !Task.isCancelled {
                withAnimation(.linear(duration: cycleDuration)) {
                    offset = -(textWidth + spacing)
                }
                try? await Task.sleep(nanoseconds: UInt64(cycleDuration * 1_000_000_000))
                guard !Task.isCancelled else { break }
                // Sofort zurücksetzen, dann kurz pausieren
                offset = 0
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }
}

// MARK: – Undo toast

/// Brief confirmation banner that slides in from the top after a shake-to-undo.
private struct UndoToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.title3)
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(.label).opacity(0.88), in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }
}

// MARK: – Archive toast

/// Confirmation banner after archiving/unarchiving — same style as UndoToast,
/// plus an inline undo button (more discoverable than shake-to-undo).
private struct ArchiveToast: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox.fill")
                .font(.title3)
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
            Button(action: onUndo) {
                Text(L("articleList.archiveToast.undoButton"))
                    .font(.subheadline.weight(.semibold))
                    .underline()
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(.label).opacity(0.88), in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }
}
