import SwiftUI

// MARK: – Row view (list layout)

struct ArticleRowView: View {
    let article: Article
    @Binding var activeSwipeId: Int?
    var showThumbnail: Bool = false
    let onToggleFavorite: () -> Void
    let onToggleArchive: () -> Void
    let onDelete: () -> Void
    var onEditTags: () -> Void = {}
    var showFavoriteAction: Bool = true
    var showArchiveAction: Bool = true

    @AppStorage("merlin_developer_mode")        private var developerMode:   Bool   = false
    @AppStorage("merlin_accent_progress_color") private var accentColorHex: String = "#FF3B30"
    @State private var readProgress: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(article.displayTitle)
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if article.isProcessing {
                        ProgressView()
                            .scaleEffect(0.65)
                            .frame(width: 14, height: 14)
                    }
                    if article.requiresLoginDomain != nil {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(article.displaySiteName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if article.readingTime > 0 {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("\(article.readingTime) min")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if readProgress > 0.01 && readProgress < 0.99 {
                        let accentColor = Color(hexString: accentColorHex) ?? .red
                        ZStack {
                            Circle()
                                .stroke(accentColor.opacity(0.2), lineWidth: 1.5)
                            Circle()
                                .trim(from: 0, to: readProgress)
                                .stroke(accentColor,
                                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 10, height: 10)
                        Text("\(Int(readProgress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if article.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }

                if !article.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(article.tags) { tag in
                                let chipColor = tag.color.flatMap { Color(hexString: $0) } ?? Color(.systemGray4)
                                Text(tag.name)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(chipColor.opacity(0.2))
                                    .foregroundStyle(chipColor)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().strokeBorder(chipColor.opacity(0.4), lineWidth: 0.5))
                            }
                        }
                    }
                }

                // MARK: Dev-mode image cache info
                if developerMode,
                   let imgStr = article.imageUrl, !imgStr.isEmpty,
                   let imgUrl = URL(string: imgStr) {
                    imageCacheDebugBanner(for: imgUrl)
                }
            }

            // Thumbnail – served from disk cache when available
            if showThumbnail {
                Group {
                    if let imgStr = article.imageUrl, !imgStr.isEmpty,
                       let imgUrl = URL(string: imgStr) {
                        CachedAsyncImage(url: imgUrl) { img in
                            img.aspectRatio(contentMode: .fill)
                        } placeholder: {
                            NoImageView()
                        }
                    } else {
                        NoImageView()
                    }
                }
                .frame(width: 72, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .onAppear { reloadProgress() }
        .onReceive(NotificationCenter.default.publisher(for: .articleProgressDidUpdate)) { notif in
            guard let id = notif.object as? Int, id == article.id else { return }
            reloadProgress()
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let url = URL(string: article.url) {
                ShareLink(item: url, subject: Text(article.displayTitle)) {
                    Label(L("articleActions.share"), systemImage: "square.and.arrow.up")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // First action = full-swipe target (Mail pattern): archive, never
            // the destructive delete — that one sits innermost.
            if article.isArchived {
                Button {
                    onToggleArchive()
                } label: {
                    Label(L("articleActions.menu.markAsUnread"), systemImage: "tray.and.arrow.up")
                }
                .tint(.orange)
            } else if showArchiveAction {
                Button {
                    onToggleArchive()
                } label: {
                    Label(L("articleActions.menu.archive"), systemImage: "archivebox")
                }
                .tint(.orange)
            }

            if article.isFavorite {
                Button {
                    onToggleFavorite()
                } label: {
                    Label(L("articleActions.favoriteRemove"), systemImage: "star.slash")
                }
                .tint(.yellow)
            } else if showFavoriteAction {
                Button {
                    onToggleFavorite()
                } label: {
                    Label(L("articleActions.favoriteAdd"), systemImage: "star")
                }
                .tint(.yellow)
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(L("common.delete"), systemImage: "trash")
            }
        }
        .contextMenu {
            if article.isFavorite {
                Button {
                    onToggleFavorite()
                } label: {
                    Label(L("articleActions.menu.removeFromFavorites"), systemImage: "star.slash")
                }
            } else if showFavoriteAction {
                Button {
                    onToggleFavorite()
                } label: {
                    Label(L("articleActions.menu.addToFavorites"), systemImage: "star")
                }
            }

            if article.isArchived {
                Button {
                    onToggleArchive()
                } label: {
                    Label(L("articleActions.menu.markAsUnread"), systemImage: "tray.and.arrow.up")
                }
            } else if showArchiveAction {
                Button {
                    onToggleArchive()
                } label: {
                    Label(L("articleActions.menu.archive"), systemImage: "archivebox")
                }
            }

            Divider()

            Button {
                onEditTags()
            } label: {
                Label(L("articleActions.menu.editTags"), systemImage: "tag")
            }

            Divider()

            Button {
                UIPasteboard.general.string = article.url
            } label: {
                Label(L("articleActions.menu.copyLink"), systemImage: "link")
            }
            if let url = URL(string: article.url) {
                ShareLink(item: url, subject: Text(article.displayTitle)) {
                    Label(L("articleActions.menu.share"), systemImage: "square.and.arrow.up")
                }
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(L("common.delete"), systemImage: "trash")
            }
        }
    }

    // MARK: – Dev-mode helper

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
        .padding(.vertical, 4)
    }

    private func reloadProgress() {
        readProgress = PreferencesStore.shared.savedScrollProgress(for: article.id)
    }
}
