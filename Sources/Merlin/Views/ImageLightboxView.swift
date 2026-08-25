import SwiftUI

// MARK: – State passed from ArticleReaderView

struct LightboxState: Identifiable {
    let id = UUID()
    let initialIndex: Int
    let imageURLs: [String]
}

// MARK: – Full-screen image viewer

struct ImageLightboxView: View {

    let state: LightboxState
    let onDismiss: () -> Void

    private static let multiplier = 500
    private var totalPages: Int { state.imageURLs.count * Self.multiplier * 2 }

    @State private var currentPage:  Int
    @State private var dragOffset:   CGFloat = 0
    /// Tracks the zoom scale of the currently visible page so the dismiss
    /// gesture can be blocked while the image is zoomed in.
    @State private var currentScale: CGFloat = 1.0

    init(state: LightboxState, onDismiss: @escaping () -> Void) {
        self.state     = state
        self.onDismiss = onDismiss
        _currentPage   = State(initialValue: state.initialIndex
                                           + state.imageURLs.count * Self.multiplier)
    }

    private var visibleIndex: Int { currentPage % state.imageURLs.count }
    private var isZoomed:     Bool { currentScale > 1.05 }

    private var backdropOpacity: Double {
        isZoomed ? 1.0 : max(0.15, 1.0 - Double(abs(dragOffset)) / 320)
    }

    var body: some View {
        ZStack {
            // ── Backdrop ─────────────────────────────────────────────────────
            Color.black
                .ignoresSafeArea()
                .opacity(backdropOpacity)

            // ── Horizontal image pager ────────────────────────────────────────
            TabView(selection: $currentPage) {
                ForEach(0 ..< totalPages, id: \.self) { page in
                    ZoomableImageView(
                        urlString: state.imageURLs[page % state.imageURLs.count],
                        onScaleChange: { scale in
                            // Only track scale for the visible page
                            if page == currentPage { currentScale = scale }
                        }
                    )
                    // Disable the TabView's backing UIScrollView while zoomed
                    // so horizontal swipes pan the image instead of changing pages.
                    .background(TabViewScrollEnabler(isEnabled: !isZoomed))
                    .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dragOffset)
            .scaleEffect(isZoomed ? 1.0 : max(0.88, 1.0 - abs(dragOffset) / 1_200))
            .animation(.interactiveSpring(), value: dragOffset)
            // Reset tracked scale whenever the user swipes to a new page
            .onChange(of: currentPage) { currentScale = 1.0 }

            // ── X button ─────────────────────────────────────────────────────
            VStack {
                HStack {
                    Spacer()
                    Button { dismissAnimated(upward: false) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.white.opacity(0.25))
                            .shadow(color: .black.opacity(0.4), radius: 4)
                    }
                    .padding(.top, 56)
                    .padding(.trailing, 20)
                }
                Spacer()
            }

            // ── Page counter ─────────────────────────────────────────────────
            if state.imageURLs.count > 1 {
                VStack {
                    Spacer()
                    Text("\(visibleIndex + 1) / \(state.imageURLs.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.bottom, 28)
                }
            }
        }
        // Vertical drag → dismiss; blocked while image is zoomed
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in
                    guard !isZoomed else { return }
                    guard abs(v.translation.height) > abs(v.translation.width) else { return }
                    dragOffset = v.translation.height
                }
                .onEnded { v in
                    guard !isZoomed else { return }
                    guard abs(v.translation.height) > abs(v.translation.width) else {
                        withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                        return
                    }
                    let far  = abs(v.translation.height) > 90
                    let fast = abs(v.predictedEndTranslation.height) > 260
                    if far || fast {
                        dismissAnimated(upward: v.translation.height < 0)
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }

    // MARK: – Dismiss

    private func dismissAnimated(upward: Bool) {
        let target: CGFloat = upward ? -700 : 700
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            dragOffset = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            onDismiss()
        }
    }
}

// MARK: – Zoomable image cell

private struct ZoomableImageView: View {

    let urlString: String
    var onScaleChange: (CGFloat) -> Void = { _ in }

    /// Scale committed after each gesture ends.
    @State private var committedScale: CGFloat = 1.0
    /// Live magnification during an active pinch — bypasses the normal
    /// SwiftUI state pipeline for frame-rate-accurate updates.
    @GestureState private var pinchDelta: CGFloat = 1.0

    /// Live drag translation during an active pan.
    @GestureState private var panDelta: CGSize = .zero
    /// Pan offset committed after each drag ends.
    @State private var committedOffset: CGSize = .zero

    private let maxScale: CGFloat = 5.0

    /// Effective scale applied to the image every frame.
    private var liveScale: CGFloat {
        let s = max(1.0, min(maxScale, committedScale * pinchDelta))
        // Report live scale so the parent can lock/unlock TabView paging in real time.
        if s != committedScale { DispatchQueue.main.async { onScaleChange(s) } }
        return s
    }
    /// Effective offset applied to the image every frame.
    private var liveOffset: CGSize {
        guard liveScale > 1.05 else { return .zero }
        return CGSize(
            width:  committedOffset.width  + panDelta.width,
            height: committedOffset.height + panDelta.height
        )
    }

    var body: some View {
        if let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .success(let img):
                    img
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(liveScale)
                        .offset(liveOffset)
                        // Pinch to zoom — @GestureState drives liveScale directly,
                        // no intermediate @State update per frame.
                        .gesture(
                            MagnificationGesture()
                                .updating($pinchDelta) { value, state, _ in
                                    state = value
                                }
                                .onEnded { value in
                                    let next = max(1.0, min(maxScale, committedScale * value))
                                    if next < 1.05 {
                                        withAnimation(.spring(response: 0.3)) { resetZoom() }
                                    } else {
                                        committedScale = next
                                        onScaleChange(next)
                                    }
                                }
                        )
                        // Drag to pan (only when zoomed)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 5)
                                .updating($panDelta) { value, state, _ in
                                    guard committedScale > 1.05 else { return }
                                    state = value.translation
                                }
                                .onEnded { value in
                                    guard committedScale > 1.05 else { return }
                                    committedOffset = CGSize(
                                        width:  committedOffset.width  + value.translation.width,
                                        height: committedOffset.height + value.translation.height
                                    )
                                }
                        )
                        // Double-tap: toggle between 2.5× and reset
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                if committedScale > 1.05 {
                                    resetZoom()
                                } else {
                                    committedScale = 2.5
                                    onScaleChange(2.5)
                                }
                            }
                        }

                case .failure:
                    Image(systemName: "photo.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                @unknown default:
                    EmptyView()
                }
            }
        }
    }

    private func resetZoom() {
        committedScale  = 1.0
        committedOffset = .zero
        onScaleChange(1.0)
    }
}

// MARK: – TabView paging lock

/// Placed as .background() on each TabView page.
/// Traverses up the UIView hierarchy to find the UIScrollView that backs
/// UIPageViewController and toggles isScrollEnabled — blocking horizontal
/// page swipes while an image is zoomed in.
private struct TabViewScrollEnabler: UIViewRepresentable {
    let isEnabled: Bool

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            var v: UIView? = uiView.superview
            while let current = v {
                if let sv = current as? UIScrollView {
                    sv.isScrollEnabled = isEnabled
                    return
                }
                v = current.superview
            }
        }
    }
}
