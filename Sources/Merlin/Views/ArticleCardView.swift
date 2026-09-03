import SwiftUI

// MARK: – UIActivityViewController wrapper (used for swipe-to-share on cards)

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let title: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url, title], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: – Row swipe gesture (UIKit-backed)

/// Bridges the card's swipe-to-reveal-actions drag to a real `UIPanGestureRecognizer`
/// instead of SwiftUI's `.simultaneousGesture(DragGesture(...))`. On iOS 26,
/// `.simultaneousGesture` stopped reliably letting the parent List's own pan gesture
/// track alongside it (Apple Feedback FB18199844), which broke the List's
/// pull-to-refresh indicator positioning on every row that used it here — the list
/// view, which has no per-row gesture and relies on native `.swipeActions` instead,
/// was never affected. `UIGestureRecognizerRepresentable` with an explicit
/// `UIGestureRecognizerDelegate` is the workaround Apple has pointed developers to.
private struct RowSwipeGesture: UIGestureRecognizerRepresentable {
    let onChanged: (_ translation: CGSize, _ startLocation: CGPoint) -> Void
    let onEnded:   (_ translation: CGSize, _ velocity: CGSize) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {}

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard let view = recognizer.view else { return }
        let location       = recognizer.location(in: view)
        let translation    = recognizer.translation(in: view)
        // UIPanGestureRecognizer only reports cumulative translation, not where the
        // touch began — derive it (current location minus translation) since
        // handleDragChanged needs it for the edge-swipe/flyout exclusion below.
        let startLocation  = CGPoint(x: location.x - translation.x, y: location.y - translation.y)

        switch recognizer.state {
        case .began, .changed:
            onChanged(CGSize(width: translation.x, height: translation.y), startLocation)
        case .ended, .cancelled:
            let velocity = recognizer.velocity(in: view)
            onEnded(CGSize(width: translation.x, height: translation.y), CGSize(width: velocity.x, height: velocity.y))
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

// MARK: – Card view (grid layout)

struct ArticleCardView: View {
    let article: Article
    @Binding var activeSwipeId: Int?
    let onToggleFavorite: () -> Void
    let onToggleArchive: () -> Void
    let onDelete: () -> Void
    var onEditTags: () -> Void = {}
    var onTap: () -> Void = {}
    var showFavoriteAction: Bool = true
    var showArchiveAction: Bool = true

    @State private var readProgress: CGFloat = 0
    @AppStorage("merlin_accent_progress_color") private var accentColorHex: String = "#FF3B30"
    @AppStorage("merlin_developer_mode")        private var developerMode:   Bool   = false

    // Swipe state — custom pill/full-swipe UX that native .swipeActions can't
    // replicate, so it's tracked manually (see RowSwipeGesture above).
    @State private var swipeOffset: CGFloat = 0  // live display value (rubber-banded past the snap positions)
    @State private var dragBase:    CGFloat = 0  // snapped position at drag start
    @State private var dragActive:  Bool    = false
    @State private var gestureConsumed = false   // vertical/edge start: ignore the rest of this gesture
    @State private var activationDx: CGFloat = 0 // translation already consumed by minimumDistance at activation
    @State private var pastOpenThreshold = false // haptic latch for the open snap point
    @State private var inCommitZone = false      // full-swipe archive zone (haptic + pill emphasis)
    @State private var showShareSheet = false
    private let actionW:       CGFloat = 72   // width of the trailing pill column
    private let shareW:        CGFloat = 72   // width of the leading share pill
    private let snapDist:      CGFloat = 55   // trailing open threshold (from closed)
    private let shareSnapDist: CGFloat = 100  // leading open threshold — higher to avoid accidental share
    private let closeDist:     CGFloat = 20   // close threshold from open
    private let commitDist:    CGFloat = 200  // full-swipe archive commit (raw finger travel, Mail pattern)
    private let rubberFactor:  CGFloat = 0.25 // drag resistance beyond the snap positions

    // Display value: follows the finger 1:1 within the snap range, damped beyond it
    private var clamped: CGFloat { swipeOffset }

    var body: some View {
        ZStack(alignment: .center) {
            // Leading: Share (swipe right) — pill button matching trailing style
            HStack(spacing: 0) {
                Button {
                    showShareSheet = true
                    closeSwipe()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.blue)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
                            .shadow(color: .black.opacity(0.10), radius: 1, x: 0, y: 1)
                        Text(L("articleActions.share"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: shareW)
                .frame(width: max(0, clamped), alignment: .leading)
                .clipped()
                .opacity(clamped > 4 ? 1 : 0)
                Spacer()
            }

            // Trailing: floating pills — revealed as the card slides left.
            HStack(spacing: 0) {
                Spacer()
                ZStack(alignment: .trailing) {
                    // Mail-style commit feedback: in the full-swipe zone the whole
                    // revealed area turns solid orange — unmistakable "release
                    // archives now", far clearer than a subtle pill scale.
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.orange)
                        .overlay(
                            Image(systemName: article.isArchived
                                  ? "tray.and.arrow.up.fill" : "archivebox.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                        .opacity(inCommitZone ? 1 : 0)

                    VStack(spacing: 8) {
                        if article.isFavorite {
                            pillButton(
                                icon: "star.slash.fill",
                                tint: Color(red: 1.0, green: 0.8, blue: 0.0),   // iOS systemYellow
                                label: L("articleActions.favoriteRemove")
                            ) {
                                onToggleFavorite()
                                closeSwipe()
                            }
                        } else if showFavoriteAction {
                            pillButton(
                                icon: "star.fill",
                                tint: Color(red: 1.0, green: 0.8, blue: 0.0),   // iOS systemYellow
                                label: L("articleActions.favoriteAdd")
                            ) {
                                onToggleFavorite()
                                closeSwipe()
                            }
                        }
                        if article.isArchived {
                            pillButton(
                                icon: "tray.and.arrow.up.fill",
                                tint: .orange,
                                label: L("articleActions.archiveRemove")
                            ) {
                                onToggleArchive()
                                closeSwipe()
                            }
                        } else if showArchiveAction {
                            pillButton(
                                icon: "archivebox.fill",
                                tint: .orange,
                                label: L("articleActions.archiveAdd")
                            ) {
                                onToggleArchive()
                                closeSwipe()
                            }
                        }
                        pillButton(
                            icon: "trash.fill",
                            tint: .red,
                            label: L("common.delete"),
                            role: .destructive
                        ) {
                            onDelete()
                        }
                    }
                    .frame(width: actionW)
                    .opacity(inCommitZone ? 0 : 1)
                }
                // Variable outer frame reveals the content from the right as
                // the user swipes. .clipped() hides any overflow into the card
                // area during the drag.
                .frame(width: max(0, -clamped), alignment: .trailing)
                .clipped()
            }

                // Card content — tap opens article when closed, or bounces shut when swiped open.
                // NOTE: no separate overlay here — it would sit above the pill buttons in the
                // ZStack and swallow their taps before they reach the Button targets.
                cardBody
                    .onTapGesture {
                        if clamped == 0 { onTap() } else { bounceClose() }
                    }
                    .offset(x: clamped)
            }
            // Drag gesture on ZStack level — above the tap overlay so it always
            // receives touches first; tap overlay only fires for actual taps.
            // Must be .simultaneousGesture, not .gesture: inside the card grid's
            // List (see ArticleListView.articleGrid), plain .gesture() competes
            // exclusively with the List's own scroll pan and loses, which silently
            // killed the swipe entirely. .simultaneousGesture lets both track at
            // once — this applies to UIGestureRecognizerRepresentable the same as
            // native SwiftUI gestures, so it doesn't reopen the FB18199844 pull-to-
            // refresh bug RowSwipeGesture above exists to work around.
            .simultaneousGesture(
                RowSwipeGesture(
                    onChanged: { translation, startLocation in
                        handleDragChanged(translation: translation, startLocation: startLocation)
                    },
                    onEnded: { translation, velocity in
                        handleDragEnded(translation: translation, velocity: velocity)
                    }
                )
            )
            .sheet(isPresented: $showShareSheet) {
                if let url = URL(string: article.url) {
                    ShareSheet(url: url, title: article.displayTitle)
                }
            }
            .onChange(of: activeSwipeId) { oldId, newId in
                // Close swipe if another card becomes active — but never interrupt
                // our own in-flight drag.
                if newId != article.id && oldId == article.id && !dragActive {
                    closeSwipe()
                }
            }
    }

    // MARK: – Floating pill action button

    /// 44 pt circular icon button with a small caption label beneath.
    /// Matches the iOS HIG minimum tap target and uses the system tint
    /// colours from the original Ampel-Strip so muscle memory is preserved.
    @ViewBuilder
    private func pillButton(
        icon: String,
        tint: Color,
        label: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 3) {
            Button(role: role, action: action) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(tint)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
                    .shadow(color: .black.opacity(0.10), radius: 1, x: 0, y: 1)
            }
            .buttonStyle(.plain)

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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

    // MARK: – Swipe gesture

    /// Archive is the only full-swipe action; mirrors the pill visibility rules.
    private var canCommitArchive: Bool { article.isArchived || showArchiveAction }

    /// Resistance beyond the snap positions — the card keeps following the finger
    /// (damped) instead of stopping dead at a hard clamp. Also gives the leading
    /// share threshold (100 pt > shareW) visible feedback for its full travel.
    private func rubberBanded(_ raw: CGFloat) -> CGFloat {
        if raw > shareW   { return shareW   + (raw - shareW)   * rubberFactor }
        if raw < -actionW { return -actionW + (raw + actionW) * rubberFactor }
        return raw
    }

    private func handleDragChanged(translation: CGSize, startLocation: CGPoint) {
        if gestureConsumed { return }

        if !dragActive {
            // ── Directional lock: decide ONCE at activation, then track without
            // re-checking the angle — mid-swipe finger drift must not freeze the card.
            let horizontal = abs(translation.width) > abs(translation.height)
            if !horizontal {
                // Vertical scroll: leave any open swipe buttons as they are —
                // they should only close when another card gets swiped, not
                // just because the list scrolled. Ignore the rest of this
                // gesture (no dragBase re-capture mid-scroll).
                gestureConsumed = true
                return
            }
            // Right-swipe starting at the left edge belongs to the list flyout.
            if translation.width > 0, startLocation.x < 25 {
                gestureConsumed = true
                return
            }
            dragActive = true
            dragBase   = swipeOffset
            // Subtract the activation distance so the card tracks from the first
            // pixel instead of jumping by minimumDistance.
            activationDx      = translation.width
            pastOpenThreshold = false
            inCommitZone      = false
        }

        let raw = dragBase + (translation.width - activationDx)
        if activeSwipeId != article.id { activeSwipeId = article.id }
        swipeOffset = rubberBanded(raw)

        // ── Haptics: custom gestures lack the system feedback of .swipeActions,
        // so mark the snap points explicitly.
        if dragBase == 0 {
            let pastOpen = raw < -snapDist || raw > shareSnapDist
            if pastOpen != pastOpenThreshold {
                pastOpenThreshold = pastOpen
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
        let commit = canCommitArchive && raw < -commitDist
        if commit != inCommitZone {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { inCommitZone = commit }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func handleDragEnded(translation: CGSize, velocity: CGSize) {
        defer {
            dragActive        = false
            gestureConsumed   = false
            pastOpenThreshold = false
            // Fade the orange commit fill out alongside the card's close spring
            // instead of snapping it off on release.
            withAnimation(.easeOut(duration: 0.2)) { inCommitZone = false }
        }
        guard dragActive else { return }

        let raw = dragBase + (translation.width - activationDx)

        // ── Full-swipe commit: archive (Mail pattern)
        if canCommitArchive && raw < -commitDist {
            onToggleArchive()
            closeSwipe()
            return
        }

        // ── Velocity-aware snap: a quick flick opens/closes even when the
        // travelled distance alone would stay below the threshold.
        // UIPanGestureRecognizer only reports velocity, not SwiftUI's
        // predictedEndTranslation directly — approximate it by projecting a
        // short (~0.2s) continuation of the current velocity, which is enough
        // to distinguish "fast flick" from "slow deliberate drag" here.
        let predictedEndTranslationWidth = translation.width + velocity.width * 0.2
        let projected = dragBase + (predictedEndTranslationWidth - activationDx)
        // A slow, deliberate drag that already crossed the threshold can still
        // decelerate (or micro-bounce back) right as the finger lifts, which
        // pulls predictedEndTranslation back under the threshold even though
        // the card was clearly dragged far enough open. Anchor the decision to
        // whichever of the raw released position or the velocity projection
        // commits harder in the same direction, so that case still opens.
        let effective: CGFloat
        if raw < 0 && projected < 0 {
            effective = min(raw, projected)
        } else if raw > 0 && projected > 0 {
            effective = max(raw, projected)
        } else {
            // Signs disagree — the velocity at release pointed the opposite way
            // from where the finger actually ended up (a soft/loose swipe often
            // has a tiny recoil as it's released). Trust the real position, not
            // a projection built from that unreliable, near-zero velocity.
            effective = raw
        }
        let newOffset: CGFloat
        if dragBase < 0 {
            newOffset = effective > -actionW + closeDist ? 0 : -actionW
        } else if dragBase > 0 {
            newOffset = effective < shareW - closeDist   ? 0 : shareW
        } else {
            newOffset = effective < -snapDist     ? -actionW :
                        effective > shareSnapDist ?  shareW  : 0
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            swipeOffset = newOffset
        }
    }

    private func closeSwipe() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { swipeOffset = 0 }
    }

    /// Closes with a springy overshoot so an accidental tap feels like a bounce,
    /// not an immediate dismissal that might be confused with opening the article.
    private func bounceClose() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.42)) { swipeOffset = 0 }
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
                )
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
                    if article.isProcessing {
                        ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                    }
                    if article.requiresLoginDomain != nil {
                        Image(systemName: "lock.fill")
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
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(article.tags) { tag in
                                let c = tag.color.flatMap { Color(hexString: $0) } ?? Color(.systemGray4)
                                Text(tag.name)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(c.opacity(0.2))
                                    .foregroundStyle(c)
                                    .clipShape(Capsule())
                            }
                        }
                    }
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
            Divider()
            if let url = URL(string: article.url) {
                ShareLink(item: url, subject: Text(article.displayTitle)) {
                    Label(L("articleActions.menu.share"), systemImage: "square.and.arrow.up")
                }
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
        NoImageView()
    }
}
