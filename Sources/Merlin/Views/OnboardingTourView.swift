import SwiftUI

// MARK: - Anchor Preference Key
// Demo views report their global CGRect under a string key.
// The tour overlay reads these to position the spotlight cutout.

struct TourAnchorKey: PreferenceKey {
    typealias Value = [String: CGRect]
    static let defaultValue = Value()
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports this view's global frame under `key` so the tour can spotlight it.
    func tourAnchor(_ key: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: TourAnchorKey.self,
                                   value: [key: geo.frame(in: .global)])
        })
    }
}

// MARK: - Step model

private enum TourPhase: Equatable {
    case list        // actual app shows through dim
    case leftFlyout  // demo left flyout rendered
    case cardSwipe   // demo card with swipe actions rendered
    case reader      // demo article reader + right flyout rendered
    case highlights  // demo reader + highlighted text + color toolbar
}

private struct TourStep {
    let systemImage: String
    let title: String
    let body: String
    let phase: TourPhase
    /// Anchor key for spotlight cutout. "plusButton" uses computed geometry.
    let anchorKey: String?
}

private let tourSteps: [TourStep] = [
    TourStep(systemImage: "hand.wave",
             title: L("onboarding.step1.title"),
             body: L("onboarding.step1.body"),
             phase: .list, anchorKey: nil),

    TourStep(systemImage: "plus.circle",
             title: L("onboarding.step2.title"),
             body: L("onboarding.step2.body"),
             phase: .list, anchorKey: "plusButton"),

    TourStep(systemImage: "sidebar.left",
             title: L("onboarding.step3.title"),
             body: L("onboarding.step3.body"),
             phase: .leftFlyout, anchorKey: "leftFlyout"),

    TourStep(systemImage: "rectangle.grid.2x2",
             title: L("onboarding.step4.title"),
             body: L("onboarding.step4.body"),
             phase: .leftFlyout, anchorKey: "menuViewToggle"),

    TourStep(systemImage: "hand.point.left",
             title: L("onboarding.step5.title"),
             body: L("onboarding.step5.body"),
             phase: .cardSwipe, anchorKey: "cardSwipeArea"),

    TourStep(systemImage: "square.and.arrow.up",
             title: L("onboarding.step6.title"),
             body: L("onboarding.step6.body"),
             phase: .cardSwipe, anchorKey: "cardShareArea"),

    TourStep(systemImage: "sidebar.right",
             title: L("onboarding.step7.title"),
             body: L("onboarding.step7.body"),
             phase: .reader, anchorKey: "rightFlyout"),

    TourStep(systemImage: "textformat.size",
             title: L("onboarding.step8.title"),
             body: L("onboarding.step8.body"),
             phase: .reader, anchorKey: "menuAppearance"),

    TourStep(systemImage: "tag",
             title: L("onboarding.step9.title"),
             body: L("onboarding.step9.body"),
             phase: .reader, anchorKey: "menuTags"),

    TourStep(systemImage: "bell",
             title: L("onboarding.step10.title"),
             body: L("onboarding.step10.body"),
             phase: .reader, anchorKey: "menuReminders"),

    TourStep(systemImage: "exclamationmark.bubble",
             title: L("onboarding.step11.title"),
             body: L("onboarding.step11.body"),
             phase: .reader, anchorKey: "menuReport"),

    TourStep(systemImage: "highlighter",
             title: L("onboarding.step12.title"),
             body: L("onboarding.step12.body"),
             phase: .highlights, anchorKey: "highlightToolbar"),

    TourStep(systemImage: "arrow.uturn.backward",
             title: L("onboarding.step13.title"),
             body: L("onboarding.step13.body"),
             phase: .list, anchorKey: nil),
]

// MARK: - Spotlight cutout shape

private struct SpotlightMask: Shape {
    var rect: CGRect
    var radius: CGFloat = 16

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(rect.minX, rect.minY), .init(rect.width, rect.height)) }
        set {
            rect = CGRect(x: newValue.first.first,  y: newValue.first.second,
                          width: newValue.second.first, height: newValue.second.second)
        }
    }

    func path(in bounds: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: -10, dy: -10)
        // Clamp radius so a large value (e.g. 999) produces a perfect circle.
        let r = min(radius, min(insetRect.width, insetRect.height) / 2)
        var p = Path()
        p.addRect(bounds)
        p.addRoundedRect(
            in: insetRect,
            cornerRadii: .init(topLeading: r, bottomLeading: r,
                               bottomTrailing: r, topTrailing: r))
        return p
    }
}

// MARK: - Demo: Left Flyout

private struct DemoLeftFlyout: View {
    var animated: Bool = true
    @State private var slideOffset: CGFloat

    init(animated: Bool = true) {
        self.animated = animated
        self._slideOffset = State(initialValue: 0)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 54)
                flyoutRow(icon: "tray.2",           label: L("onboarding.demo.leftFlyout.unread"),  tint: .accentColor)
                flyoutRow(icon: "star",              label: L("onboarding.demo.leftFlyout.favorites"))
                flyoutRow(icon: "archivebox",        label: L("onboarding.demo.leftFlyout.archive"))
                menuDivider
                flyoutRow(icon: "tag",               label: L("onboarding.demo.leftFlyout.tags"))
                menuDivider
                flyoutRow(icon: "rectangle.grid.1x2",label: L("onboarding.demo.leftFlyout.cardView"))
                    .tourAnchor("menuViewToggle")
                menuDivider
                flyoutRow(icon: "bell",              label: L("onboarding.demo.leftFlyout.reminders"))
                flyoutRow(icon: "gearshape",         label: L("onboarding.demo.leftFlyout.settings"))
                Spacer()
            }
            .frame(width: 300)
            .background(Color(.systemBackground))
            .overlay(alignment: .trailing) { Color(.separator).frame(width: 0.5) }
            .tourAnchor("leftFlyout")
            .offset(x: slideOffset)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .ignoresSafeArea()
        .task {
            // Start visible (slideOffset = 0) so the anchor rect is correct immediately
            // and the dim layer never flashes full-black. Then loop: pause → slide out → slide back in.
            guard animated else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                    slideOffset = -300
                }
                try? await Task.sleep(for: .seconds(0.8))
                withAnimation(.spring(response: 0.52, dampingFraction: 0.84)) {
                    slideOffset = 0
                }
            }
        }
    }

    @ViewBuilder
    private func flyoutRow(icon: String, label: String, tint: Color? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(tint ?? .primary)
                .frame(width: 24, alignment: .center)
            Text(label).font(.body).foregroundStyle(tint ?? .primary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var menuDivider: some View {
        Divider().padding(.horizontal, 20).padding(.vertical, 3)
    }
}

// MARK: - Demo: Card with Swipe Actions

private struct DemoCardSwipe: View {
    var showShare: Bool = false

    private let actionWidth: CGFloat = 72
    private let shareWidth:  CGFloat = 72
    private let cardHeight:  CGFloat = 248

    @State private var animOffset: CGFloat = 0

    /// Real safe area top — read from UIKit because the outer GeometryReader
    /// runs with ignoresSafeArea() and would report 0 otherwise.
    private var safeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top ?? 44
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: safeTop + 62)

            if showShare {
                // Leading: share pill button, card animated right
                ZStack(alignment: .leading) {
                    demoPill(icon: "square.and.arrow.up", tint: .blue, label: L("articleActions.share"))
                        .frame(width: shareWidth, height: cardHeight)
                        .tourAnchor("cardShareArea")

                    cardBody
                        .padding(.trailing, 12)
                        .offset(x: animOffset)
                }
                .frame(height: cardHeight)
                .clipped()
            } else {
                // Trailing: favorite / archive / delete pill buttons, card shifted left.
                // animOffset is driven by the .task loop below.
                ZStack(alignment: .trailing) {
                    VStack(spacing: 8) {
                        demoPill(icon: "star.fill",       tint: Color(red: 1.0, green: 0.8, blue: 0.0), label: L("articleActions.favoriteAdd"))
                        demoPill(icon: "archivebox.fill", tint: .orange,                                 label: L("articleActions.archiveAdd"))
                        demoPill(icon: "trash.fill",      tint: .red,                                   label: L("common.delete"))
                    }
                    .frame(width: actionWidth, height: cardHeight)

                    cardBody
                        .offset(x: animOffset)
                }
                .frame(height: cardHeight)
                .clipped()
                .tourAnchor("cardSwipeArea")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        // Swipe demo animation — loops: slide in → pause → slide back → pause
        // Works for both trailing actions (showShare=false) and share (showShare=true).
        .task(id: showShare) {
            animOffset = 0
            let target: CGFloat = showShare ? shareWidth : -actionWidth
            try? await Task.sleep(for: .seconds(0.5))
            while !Task.isCancelled {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                    animOffset = target
                }
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                    animOffset = 0
                }
                try? await Task.sleep(for: .seconds(1.0))
            }
        }
    }

    @ViewBuilder
    private func demoPill(icon: String, tint: Color, label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(tint)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
                .shadow(color: .black.opacity(0.10), radius: 1, x: 0, y: 1)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            LinearGradient(
                colors: [Color(red: 0.18, green: 0.42, blue: 0.62),
                         Color(red: 0.42, green: 0.18, blue: 0.54)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            .aspectRatio(16 / 9, contentMode: .fit)

            VStack(alignment: .leading, spacing: 4) {
                Text(L("onboarding.demo.sampleArticle.title"))
                    .font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(L("onboarding.demo.sampleArticle.meta"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
    }
}

// MARK: - Demo: List Row with Swipe Actions

private struct DemoRowSwipe: View {
    var showShare: Bool = false

    /// Width of each trailing action button — 3 buttons shown side-by-side,
    /// matching the iOS .swipeActions rendering in ArticleRowView.
    private let btnW:      CGFloat = 68
    private let shareWidth: CGFloat = 72
    private let rowHeight:  CGFloat = 74   // matches actual ArticleRowView height

    private var trailingW: CGFloat { btnW * 3 }

    @State private var animOffset: CGFloat = 0

    private var safeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top ?? 44
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: safeTop + 62)

            if showShare {
                // Leading: blue circle-pill share button (matches ArticleRowView leading swipe)
                ZStack(alignment: .leading) {
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
                    .frame(width: shareWidth, height: rowHeight)
                    .tourAnchor("cardShareArea")

                    rowBody.offset(x: animOffset)
                }
                .frame(height: rowHeight)
                .clipped()
            } else {
                // Trailing: iOS-native swipe action style — 3 horizontal colored cells
                // matching .swipeActions(edge: .trailing) in ArticleRowView.
                ZStack(alignment: .trailing) {
                    HStack(spacing: 0) {
                        actionBtn(icon: "star",        label: L("articleActions.favoriteAdd"),  bg: Color(red: 1, green: 0.8, blue: 0))
                        actionBtn(icon: "archivebox",  label: L("articleActions.archiveAdd"),   bg: .orange)
                        actionBtn(icon: "trash",       label: L("common.delete"),  bg: .red)
                    }
                    .frame(width: trailingW, height: rowHeight)

                    rowBody.offset(x: animOffset)
                }
                .frame(height: rowHeight)
                .clipped()
                .tourAnchor("cardSwipeArea")
            }

            Divider()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        // Swipe demo animation — loops: slide in → pause → slide back → pause
        // Works for both trailing actions (showShare=false) and share (showShare=true).
        .task(id: showShare) {
            animOffset = 0
            let target: CGFloat = showShare ? shareWidth : -trailingW
            try? await Task.sleep(for: .seconds(0.5))
            while !Task.isCancelled {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                    animOffset = target
                }
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                    animOffset = 0
                }
                try? await Task.sleep(for: .seconds(1.0))
            }
        }
    }

    /// Single trailing action cell: colored background + icon + label,
    /// identical to what iOS renders for .swipeActions buttons.
    @ViewBuilder
    private func actionBtn(icon: String, label: String, bg: Color) -> some View {
        bg.overlay(
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
            }
        )
        .frame(width: btnW)
        .frame(maxHeight: .infinity)
    }

    private var rowBody: some View {
        HStack(spacing: 12) {
            // Thumbnail — 72×54 matching ArticleRowView
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(
                    colors: [Color(red: 0.18, green: 0.42, blue: 0.62),
                             Color(red: 0.42, green: 0.18, blue: 0.54)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 72, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text(L("onboarding.demo.sampleArticle.title"))
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("rbb|24")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text("8 min")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.leading, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }
}

// MARK: - Demo: Right Flyout (used inside DemoReaderView)

private struct DemoRightFlyout: View {
    var animated: Bool = true
    @State private var slideOffset: CGFloat

    init(animated: Bool = true) {
        self.animated = animated
        self._slideOffset = State(initialValue: 0)
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 50)

                flyoutRow(icon: "chevron.left",           label: L("onboarding.demo.readerMenu.close"))
                menuDivider
                flyoutRow(icon: "star",                   label: L("articleReader.sideMenu.addFavorite"))
                flyoutRow(icon: "speaker.wave.2",         label: L("articleReader.sideMenu.startReadAloud"))
                flyoutRow(icon: "textformat.size",        label: L("articleReader.sideMenu.appearance"))
                    .tourAnchor("menuAppearance")
                menuDivider
                flyoutRow(icon: "square.and.arrow.up",    label: L("articleReader.sideMenu.share"))
                flyoutRow(icon: "safari",                 label: L("articleReader.sideMenu.openInBrowser"))
                flyoutRow(icon: "link",                   label: L("articleReader.sideMenu.copyLink"))
                menuDivider
                flyoutRow(icon: "archivebox",             label: L("articleReader.sideMenu.archive"))
                flyoutRow(icon: "tag",                    label: L("articleReader.sideMenu.editTags"))
                    .tourAnchor("menuTags")
                flyoutRow(icon: "bell",                   label: L("articleReader.sideMenu.setReminder"))
                    .tourAnchor("menuReminders")
                menuDivider
                flyoutRow(icon: "exclamationmark.bubble", label: L("articleReader.sideMenu.reportArticle"))
                    .tourAnchor("menuReport")
                menuDivider
                flyoutRow(icon: "trash",                  label: L("common.delete"), tint: .red)

                Spacer()
            }
            .frame(width: 290)
            .background(Color(.systemBackground))
            .overlay(alignment: .leading) { Color(.separator).frame(width: 0.5) }
            .tourAnchor("rightFlyout")
            .offset(x: slideOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        // Start visible (slideOffset = 0) so anchor rects are correct immediately and
        // no dim flash occurs on the next step. Loop: pause → slide out → slide back in.
        .task {
            guard animated else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                    slideOffset = 290
                }
                try? await Task.sleep(for: .seconds(0.8))
                withAnimation(.spring(response: 0.52, dampingFraction: 0.84)) {
                    slideOffset = 0
                }
            }
        }
    }

    @ViewBuilder
    private func flyoutRow(icon: String, label: String, tint: Color? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint ?? .primary)
                .frame(width: 22, alignment: .center)
            Text(label).font(.subheadline).foregroundStyle(tint ?? .primary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var menuDivider: some View {
        Divider().padding(.horizontal, 18).padding(.vertical, 2)
    }
}

// MARK: - Demo: Reader (phases .reader and .highlights)

private struct DemoReaderView: View {
    let showHighlights: Bool
    var showFlyout: Bool = true
    var flyoutAnimated: Bool = false

    private let highlightColors: [Color] = [
        Color(red: 0.99, green: 0.91, blue: 0.54),
        Color(red: 0.73, green: 0.97, blue: 0.81),
        Color(red: 0.75, green: 0.86, blue: 0.99),
        Color(red: 0.98, green: 0.81, blue: 0.91),
        Color(red: 0.99, green: 0.85, blue: 0.67),
    ]

    var body: some View {
        ZStack(alignment: .trailing) {
            // Article content (non-scrollable for predictable spotlight positions)
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 52)

                // Hero image placeholder
                LinearGradient(
                    colors: [Color(red: 0.18, green: 0.38, blue: 0.58),
                             Color(red: 0.38, green: 0.18, blue: 0.52)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("onboarding.demo.sampleArticle.title"))
                        .font(.title2.bold())
                    Text(L("onboarding.demo.sampleArticle.byline"))
                        .font(.caption).foregroundStyle(.secondary)

                    Divider().padding(.vertical, 2)

                    if showHighlights {
                        highlightScene
                    } else {
                        Text(L("onboarding.demo.sampleArticle.body"))
                            .font(.body).lineSpacing(4)
                    }
                }
                .padding(20)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))

            // Right flyout visible in reader phase, hidden for highlights.
            // Omitted when showFlyout is false (flyout rendered above the dim instead).
            if showFlyout && !showHighlights {
                DemoRightFlyout(animated: flyoutAnimated)
            }
        }
        // Fake navigation bar
        .overlay(alignment: .top) {
            HStack {
                ZStack {
                    Circle().fill(Color(.secondarySystemBackground))
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .frame(width: 38, height: 38)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .padding(.leading, 16)
                Spacer()
            }
            .frame(height: 50)
            .padding(.top, 8)
        }
        .ignoresSafeArea()
    }

    private var highlightedSampleText: AttributedString {
        let full = L("onboarding.demo.sampleHighlight")
        var str = AttributedString(full)
        let phrase = "deep, intentional reading may be one of the most valuable skills we can cultivate"
        if let range = str.range(of: phrase) {
            str[range].backgroundColor = UIColor(red: 0.99, green: 0.91, blue: 0.54, alpha: 1)
        }
        return str
    }

    // Text with yellow highlight + floating color toolbar
    private var highlightScene: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(highlightedSampleText)
                .font(.body)
                .lineSpacing(4)

            // Color picker toolbar
            HStack(spacing: 8) {
                ForEach(highlightColors.indices, id: \.self) { i in
                    Circle()
                        .fill(highlightColors[i])
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 2))
                }
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1, height: 22)
                Text("✕")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(red: 1, green: 0.27, blue: 0.23))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color(white: 0.25)))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12)))
            .tourAnchor("highlightToolbar")
        }
    }
}

// MARK: - Main Tour View

struct OnboardingTourView: View {
    @Binding var isPresented: Bool

    @State private var stepIndex = 0
    @State private var anchors: [String: CGRect] = [:]
    @State private var plusButtonFrame: CGRect? = nil
    @State private var shakeAngle: Double = 0
    @AppStorage("merlinIsCardView") private var isCardView: Bool = true
    @AppStorage("merlin_developer_mode") private var developerMode: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    /// Dim opacity: lighter in dark mode so the spotlight cutout stays visible
    /// against an already-dark background.
    private var dimOpacity: Double { colorScheme == .dark ? 0.55 : 0.72 }

    private var step: TourStep { tourSteps[stepIndex] }
    private var isLast: Bool   { stepIndex == tourSteps.count - 1 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Layer 1 – demo content (behind dim)
                phaseBackground(geo: geo)
                    .id(stepIndex)

                // Layer 2 – dim with optional spotlight cutout
                dimLayer(geo: geo)

                // Layer 2c – flyout panel above dim (Navigation Menu step only).
                // Keeps the flyout unaffected by the dim while the background behind it is dimmed.
                if step.phase == .leftFlyout, step.anchorKey == "leftFlyout" {
                    DemoLeftFlyout(animated: true)
                        .allowsHitTesting(false)
                }

                // Layer 2d – right flyout panel above dim (Reader Menu step only).
                if step.phase == .reader, step.anchorKey == "rightFlyout" {
                    DemoRightFlyout(animated: true)
                        .allowsHitTesting(false)
                }

                // Layer 2b – debug: show scanned plusButton frame (developer mode only)
                if developerMode, step.anchorKey == "plusButton" {
                    // Red border on the chosen frame
                    if let f = plusButtonFrame {
                        Rectangle()
                            .strokeBorder(Color.red, lineWidth: 2)
                            .frame(width: f.width, height: f.height)
                            .position(x: f.midX, y: f.midY)
                        Text("BEST x:\(Int(f.midX)) y:\(Int(f.midY)) \(Int(f.width))×\(Int(f.height))")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.red)
                            .padding(4)
                            .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                            .position(x: f.midX, y: f.maxY + 14)
                    }
                    // List all views found in the nav bar strip
                    VStack(alignment: .leading, spacing: 3) {
                        if plusButtonFrame == nil {
                            Text("plusButtonFrame: nil").foregroundStyle(.red)
                        }
                        Text("Nav-bar views (\(debugNavViews.count)):").foregroundStyle(.yellow)
                        ForEach(Array(debugNavViews.enumerated()), id: \.offset) { _, v in
                            Text("\(v.type)  x:\(Int(v.frame.midX)) y:\(Int(v.frame.midY)) \(Int(v.frame.width))×\(Int(v.frame.height))")
                        }
                    }
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: geo.size.width - 40, alignment: .leading)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }

                // Layer 3a – shake icon, centered on screen (Shake to Undo step only)
                if step.systemImage == "arrow.uturn.backward" {
                    ZStack {
                        if developerMode {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.red, lineWidth: 2)
                                .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                                .frame(width: 160, height: 160)
                        }
                        Image(systemName: "iphone.gen2.motion")
                            .font(.system(size: 144, weight: .thin))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.35), radius: 20, y: 6)
                            .rotationEffect(.degrees(shakeAngle))
                            .animation(
                                .easeInOut(duration: 0.1)
                                .repeatForever(autoreverses: true),
                                value: shakeAngle
                            )
                    }
                    .overlay(alignment: .bottom) {
                        if developerMode {
                            Text("SF: iphone.gen2.motion")
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.red)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                                .offset(y: 22)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .ignoresSafeArea()
                    .zIndex(99)
                    .onAppear { shakeAngle = 14 }
                    .onDisappear { shakeAngle = 0 }
                }

                // Layer 3b – step card (always on top)
                VStack(spacing: 0) {
                    stepCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, geo.safeAreaInsets.bottom + 28)
                .zIndex(100)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .onPreferenceChange(TourAnchorKey.self) { anchors = $0 }
        .onAppear { refreshPlusButton() }
        .onChange(of: stepIndex) { _, _ in
            if step.anchorKey == "plusButton" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { refreshPlusButton() }
            }
        }
    }

    /// Walks the UIKit view tree to find the nav bar's trailing button frame.
    /// Toolbar items bypass SwiftUI preferences, so this is the only reliable method.
    @State private var debugNavViews: [(type: String, frame: CGRect)] = []

    private func refreshPlusButton() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows.first(where: { $0.isKeyWindow })
        else { return }

        let safeTop = window.safeAreaInsets.top
        var best: CGRect? = nil
        var found: [(String, CGRect)] = []

        func scan(_ view: UIView) {
            if !view.isHidden, view.alpha > 0 {
                let f = view.convert(view.bounds, to: window)
                // Collect every non-trivial leaf view in the nav bar strip
                if f.width > 5, f.height > 5,
                   f.midY > safeTop, f.midY < safeTop + 54,
                   f.midX > window.bounds.width * 0.5 {
                    found.append((String(describing: type(of: view)), f))
                    // Pick the rightmost interactive view as the button
                    if view.isUserInteractionEnabled, f.width < 100 {
                        if best == nil || f.midX > best!.midX { best = f }
                    }
                }
            }
            view.subviews.forEach { scan($0) }
        }
        scan(window)

        debugNavViews = found.map { (type: $0.0, frame: $0.1) }
        plusButtonFrame = best
    }

    // MARK: Phase background

    @ViewBuilder
    private func phaseBackground(geo: GeometryProxy) -> some View {
        switch step.phase {
        case .list:
            Color.clear  // actual app shows through

        case .leftFlyout:
            if step.anchorKey == "leftFlyout" {
                // Flyout is rendered above the dim in a separate layer; show only background here.
                Color(.systemGroupedBackground).ignoresSafeArea()
            } else {
                DemoLeftFlyout(animated: false)
            }

        case .cardSwipe:
            let share = step.anchorKey == "cardShareArea"
            if isCardView { DemoCardSwipe(showShare: share) } else { DemoRowSwipe(showShare: share) }

        case .reader:
            DemoReaderView(showHighlights: false,
                           showFlyout: step.anchorKey != "rightFlyout",
                           flyoutAnimated: false)

        case .highlights:
            DemoReaderView(showHighlights: true)
        }
    }

    // MARK: Dim layer

    @ViewBuilder
    private func dimLayer(geo: GeometryProxy) -> some View {
        let rect   = spotlightRect(geo: geo)
        let radius = spotlightRadius

        switch step.phase {
        case .reader, .highlights:
            if step.anchorKey == "rightFlyout" {
                // Full-screen dim — flyout panel is rendered above this in the ZStack.
                Color.black.opacity(dimOpacity).ignoresSafeArea()
            } else if let r = rect {
                ZStack {
                    SpotlightMask(rect: r, radius: radius)
                        .fill(Color.black.opacity(dimOpacity), style: FillStyle(eoFill: true))
                        .ignoresSafeArea()
                    spotlightRing(rect: r, radius: radius)
                }
            }

        default:
            if step.anchorKey == "leftFlyout" {
                // Full-screen dim — flyout panel is rendered above this in the ZStack.
                Color.black.opacity(dimOpacity).ignoresSafeArea()
            } else if let r = rect {
                ZStack {
                    SpotlightMask(rect: r, radius: radius)
                        .fill(Color.black.opacity(dimOpacity), style: FillStyle(eoFill: true))
                        .ignoresSafeArea()
                    spotlightRing(rect: r, radius: radius)
                }
            } else {
                Color.black.opacity(dimOpacity).ignoresSafeArea()
            }
        }
    }

    /// A luminous stroke ring drawn around the spotlight cutout.
    /// In dark mode this outlines the highlighted area that would otherwise
    /// blend into the dark dim; in light mode it provides a subtle polish.
    @ViewBuilder
    private func spotlightRing(rect: CGRect, radius: CGFloat) -> some View {
        let inset = rect.insetBy(dx: -10, dy: -10)
        let r     = min(radius, min(inset.width, inset.height) / 2)
        RoundedRectangle(cornerRadius: r)
            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.45 : 0.25), lineWidth: 1.5)
            .frame(width: inset.width, height: inset.height)
            .position(x: inset.midX, y: inset.midY)
            .ignoresSafeArea()
    }

    // MARK: Spotlight rect

    private func spotlightRect(geo: GeometryProxy) -> CGRect? {
        guard let key = step.anchorKey else { return nil }
        if key == "plusButton" { return plusButtonFrame }
        return anchors[key]
    }

    /// Spotlight corner radius for the current step.
    /// 999 → clamped to a perfect circle by SpotlightMask.
    private var spotlightRadius: CGFloat {
        step.anchorKey == "plusButton" ? 999 : 16
    }

    // MARK: Step card

    private var stepCard: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 6) {
                ForEach(0 ..< tourSteps.count, id: \.self) { i in
                    Capsule()
                        .fill(i == stepIndex ? Color.white : Color.white.opacity(0.28))
                        .frame(width: i == stepIndex ? 22 : 6, height: 6)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            Image(systemName: step.systemImage)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white)
                .frame(height: 46)
                .padding(.bottom, 12)

            Text(step.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            Text(step.body)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.bottom, 24)

            HStack(spacing: 10) {
                Button {
                    withAnimation { stepIndex -= 1 }
                } label: {
                    Text(L("common.back"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(stepIndex == 0 ? Color.black.opacity(0.3) : .black)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(stepIndex == 0 ? Color.white.opacity(0.4) : Color.white,
                                    in: RoundedRectangle(cornerRadius: 14))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(stepIndex == 0)

                Button {
                    if isLast { finish() }
                    else { withAnimation { stepIndex += 1 } }
                } label: {
                    Text(isLast ? L("onboarding.buttons.getStarted") : L("common.next"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: 26)
                .fill(Color(white: 0.11))
                .overlay(RoundedRectangle(cornerRadius: 26)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        )
    }

    // MARK: Finish

    private func finish() {
        UserDefaults.standard.set(true, forKey: "merlin_tour_done")
        withAnimation(.easeInOut(duration: 0.25)) { isPresented = false }
    }
}
