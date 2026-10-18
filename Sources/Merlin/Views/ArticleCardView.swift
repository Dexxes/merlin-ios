import SwiftUI

// MARK: – Card view (grid layout)

struct ArticleCardView: View {
    let article: Article
    let onToggleFavorite: () -> Void
    let onToggleArchive: () -> Void
    let onDelete: () -> Void
    var onEditTags: () -> Void = {}
    /// „Umbenennen…“ im Kontextmenü, nur bei Datei-Einträgen.
    var onRename: (() -> Void)? = nil
    var onTap: () -> Void = {}
    var showFavoriteAction: Bool = true
    var showArchiveAction: Bool = true
    /// Archivierte Artikel mit Plakette und abgeblendet zeigen (gemischte
    /// Listen wie Tag-Ansicht und Favoriten); die Archiv-Ansicht schaltet es ab.
    var showArchivedState: Bool = true

    @State private var readProgress: CGFloat = 0
    @AppStorage("merlin_accent_progress_color") private var accentColorHex: String = "#FF3B30"
    @AppStorage("merlin_developer_mode")        private var developerMode:   Bool   = false

    private var isMarkedArchived: Bool { showArchivedState && article.isArchived }

    var body: some View {
        cardBody
            .onTapGesture { onTap() }
    }

    @ViewBuilder
    private func imageCacheDebugBanner(for url: URL) -> some View {
        let cached = ImageCacheService.shared.localURL(for: url)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: cached != nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(cached != nil ? Color.green : Color.orange)
                Text(cached != nil ? "CACHED" : "NOT CACHED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(cached != nil ? Color.green : Color.orange)
            }
            Text(url.absoluteString)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let filename = cached?.lastPathComponent {
                Text(filename)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((cached != nil ? Color.green : Color.orange).opacity(0.07))
        .overlay(alignment: .top) {
            (cached != nil ? Color.green : Color.orange)
                .opacity(0.3)
                .frame(height: 1)
        }
    }

    private func reloadProgress() {
        readProgress = PreferencesStore.shared.savedScrollProgress(for: article.id)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Hero image / placeholder – always 16:9.
            // Color.clear establishes the layout frame (width × 9/16),
            // the overlay fills it exactly so scaledToFill() can never
            // push the card wider than its column.
            Color.clear
                .aspectRatio(CGSize(width: 16, height: 9), contentMode: .fit)
                .overlay(
                    Group {
                        if let imgStr = article.imageUrl, !imgStr.isEmpty,
                           let imgUrl = URL(string: imgStr) {
                            CachedAsyncImage(url: imgUrl) { img in
                                img.scaledToFill()
                            } placeholder: {
                                NoImageView()
                            }
                        } else {
                            cardPlaceholder
                        }
                    }
                    .clipped()
                    .opacity(isMarkedArchived ? 0.6 : 1)
                )
                .overlay(alignment: .topLeading) {
                    if isMarkedArchived {
                        ArchivedBadge()
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if readProgress > 0.01 && readProgress < 0.99 {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(Color(hexString: accentColorHex) ?? .red)
                                .frame(width: geo.size.width * readProgress, height: 3)
                        }
                        .frame(height: 3)
                    }
                }
                .frame(maxWidth: .infinity)
                .clipped()

            // Text content
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(article.displayTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .opacity(isMarkedArchived ? 0.6 : 1)
                    if article.isProcessing {
                        ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                    }
                    if article.requiresLoginDomain != nil || article.isPaywalled {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if article.unsupportedSiteDomain != nil {
                        Image(systemName: "xmark.octagon")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 4) {
                    Text(article.displaySiteName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if article.readingTime > 0 {
                        Text("· \(article.readingTime) min")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if article.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }

                if !article.tags.isEmpty {
                    ArticleTagLine(tags: article.tags)
                }
            }
            .padding(10)

            // MARK: Dev-mode image cache info
            if developerMode,
               let imgStr = article.imageUrl, !imgStr.isEmpty,
               let imgUrl = URL(string: imgStr) {
                imageCacheDebugBanner(for: imgUrl)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .onAppear { reloadProgress() }
        .onReceive(NotificationCenter.default.publisher(for: .articleProgressDidUpdate)) { notif in
            guard let id = notif.object as? Int, id == article.id else { return }
            reloadProgress()
        }
        .contextMenu {
            if article.isFavorite {
                Button { onToggleFavorite() } label: {
                    Label(L("articleActions.menu.removeFromFavorites"), systemImage: "star.slash")
                }
            } else if showFavoriteAction {
                Button { onToggleFavorite() } label: {
                    Label(L("articleActions.menu.addToFavorites"), systemImage: "star")
                }
            }
            if article.isArchived {
                Button { onToggleArchive() } label: {
                    Label(L("articleActions.menu.markAsUnread"), systemImage: "tray.and.arrow.up")
                }
            } else if showArchiveAction {
                Button { onToggleArchive() } label: {
                    Label(L("articleActions.menu.archive"), systemImage: "archivebox")
                }
            }
            Divider()
            Button { onEditTags() } label: {
                Label(L("articleActions.menu.editTags"), systemImage: "tag")
            }
            if article.fileId != nil, let onRename {
                Button { onRename() } label: {
                    Label(L("fileRename.menu"), systemImage: "pencil")
                }
            }
            Divider()
            ArticleShareLink(article: article) {
                Label(L("articleActions.menu.share"), systemImage: "square.and.arrow.up")
            }
            if URL(string: article.url) != nil {
                Button { UIPasteboard.general.string = article.url } label: {
                    Label(L("articleActions.menu.copyLink"), systemImage: "link")
                }
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label(L("common.delete"), systemImage: "trash")
            }
        }
    }

    private var cardPlaceholder: some View {
        NoImageView(isPDF: article.isPDF)
    }
}

// MARK: – Archived badge

/// Kleine Plakette "Archiviert" auf dem Kartenbild. Bewusst dunkel und
/// nicht abgeblendet, damit sie auf jedem Vorschaubild lesbar bleibt.
struct ArchivedBadge: View {
    var body: some View {
        Label(L("articleList.archivedBadge"), systemImage: "archivebox.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.65), in: Capsule())
    }
}
