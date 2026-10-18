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
    case cardSwipe   // demo list row swiped right to reveal share
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
    /// Zeigt in der Karte die Auswahl der Akzentfarbe (letzter Schritt).
    var showsAccentPicker: Bool = false
    /// Nur in der Listenansicht zeigen (Wischgesten gibt es nur dort).
    var isListViewOnly: Bool = false
}

/// Text des Löschfrist-Schritts hängt von den Fristen des Servers ab
/// (`RetentionStore.summaryText`), deshalb werden die Schritte pro Anzeige gebaut.
/// Teilen per Wischen gibt es nur in der Listenansicht, Karten haben keine Wischgesten.
private func makeTourSteps(retentionBody: String, isCardView: Bool) -> [TourStep] { [
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

    TourStep(systemImage: "square.and.arrow.up",
             title: L("onboarding.step6.title"),
             body: L("onboarding.step6.body"),
             phase: .cardSwipe, anchorKey: "cardShareArea", isListViewOnly: true),

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

    TourStep(systemImage: "clock.arrow.circlepath",
             title: L("onboarding.retention.title"),
             body: retentionBody,
             phase: .list, anchorKey: nil),

    TourStep(systemImage: "arrow.uturn.backward",
             title: L("onboarding.step13.title"),
             body: L("onboarding.step13.body"),
             phase: .list, anchorKey: nil),

    TourStep(systemImage: "paintpalette",
             title: L("onboarding.accentColor.title"),
             body: L("onboarding.accentColor.body"),
             phase: .list, anchorKey: nil,
             showsAccentPicker: true),
].filter { !(isCardView && $0.isListViewOnly) } }

/// Vorschläge für die Akzentfarbe im letzten Tour-Schritt; der Standard
/// (`#FF3B30`) steht vorn. Jede andere Farbe gibt es über den ColorPicker.
private let accentColorPresets = ["#FF3B30", "#FF9500", "#34C759", "#007AFF", "#AF52DE", "#FF2D55"]

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
                Picker(L("navigationMenu.mediaTypePicker"), selection: .constant(0)) {
                    Text(L("navigationMenu.tab.text")).tag(0)
                    Text(L("navigationMenu.tab.video")).tag(1)
                    Text(L("navigationMenu.tab.audio")).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .allowsHitTesting(false)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 6)
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

// MARK: - Demo: List Row with Share Swipe

private struct DemoRowSwipe: View {
    private let shareWidth: CGFloat = 72
    private let rowHeight:  CGFloat = 74   // matches actual ArticleRowView height

    @State private var animOffset: CGFloat = 0

    private var safeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top ?? 44
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: safeTop + 62)

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

            Divider()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        // Swipe demo animation — loops: slide in → pause → slide back → pause
        .task {
            animOffset = 0
            try? await Task.sleep(for: .seconds(0.5))
            while !Task.isCancelled {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                    animOffset = shareWidth
                }
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                    animOffset = 0
                }
                try? await Task.sleep(for: .seconds(1.0))
            }
        }
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

                flyoutRow(icon: "chevron.left",           label: L("common.back"))
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

    /// Dieselbe Akzentfarbe wie im Reader: Kopffläche und Tonstufen.
    @AppStorage("merlin_accent_progress_color") private var accentColorHex: String = "#FF3B30"

    /// Spiegelt `HighlightToolbarView.colors` im Reader.
    private let highlightColors = ["#fde68a", "#bbf7d0", "#bfdbfe", "#fbcfe8", "#fed7aa"]

    /// Tonstufen Akzent → Hintergrund wie `ArticleReaderView.accentSteps`.
    private let accentSteps: [(height: CGFloat, amount: Double)] =
        [(14, 0.75), (12, 0.55), (10, 0.35), (8, 0.15)]

    private var safeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top ?? 44
    }

    private var accent: Color { Color(hexString: accentColorHex) ?? .red }

    /// Lesbare Vordergrundfarbe auf der Akzentfläche (wie `onAccentHex` im Reader).
    private var onAccent: Color {
        let s = accentColorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count >= 6, let v = UInt32(s.prefix(6), radix: 16) else { return .white }
        func lin(_ c: UInt32) -> Double {
            let x = Double(c) / 255
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * lin(v >> 16 & 0xff) + 0.7152 * lin(v >> 8 & 0xff) + 0.0722 * lin(v & 0xff)
        return l > 0.35 ? Color(red: 0.11, green: 0.11, blue: 0.12) : .white
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Article content (non-scrollable for predictable spotlight positions)
            Group {
                if showHighlights {
                    highlightScene
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        articleHeader
                        Text(L("onboarding.demo.sampleArticle.body"))
                            .font(.body).lineSpacing(4)
                            .padding(.horizontal, 20)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemBackground))

            // Right flyout visible in reader phase, hidden for highlights.
            // Omitted when showFlyout is false (flyout rendered above the dim instead).
            if showFlyout && !showHighlights {
                DemoRightFlyout(animated: flyoutAnimated)
            }
        }
        .ignoresSafeArea()
    }

    // Plakat-Header wie `ArticleReaderView.articleHeader`: Akzentfläche mit
    // Topline, Titel, Teaser und Metazeile, darunter das Titelbild randlos auf
    // der Fläche und die Tonstufen zum Text.
    private var articleHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("rbb|24")
                    Spacer(minLength: 0)
                    Text(L("onboarding.demo.sampleArticle.tag")).lineLimit(1)
                }
                .font(.system(size: 11, weight: .bold))
                .tracking(2.0)
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) { onAccent.frame(height: 2) }

                Text(L("onboarding.demo.sampleArticle.title"))
                    .font(.system(size: 32, weight: .heavy))
                    .tracking(-1)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L("onboarding.demo.sampleArticle.teaser"))
                    .font(.system(size: 16, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)

                Text(L("onboarding.demo.sampleArticle.byline"))
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.0)
                    .lineLimit(1)
                    .padding(.top, 8)
                    .overlay(alignment: .top) { onAccent.frame(height: 2) }
            }
            .foregroundStyle(onAccent)
            .padding(.horizontal, 20)
            .padding(.top, safeTop + 28)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent)

            // Hero image placeholder
            LinearGradient(
                colors: [Color(red: 0.18, green: 0.38, blue: 0.58),
                         Color(red: 0.38, green: 0.18, blue: 0.52)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .padding(.bottom, 14)
            .background(accent)

            ForEach(accentSteps.indices, id: \.self) { i in
                Rectangle()
                    .fill(accent.mix(with: Color(.systemBackground),
                                     by: 1 - accentSteps[i].amount, in: .perceptual))
                    .frame(height: accentSteps[i].height)
            }
            Color.clear.frame(height: 16)
        }
    }

    private var highlightedSampleText: AttributedString {
        var str = AttributedString(L("onboarding.demo.sampleHighlight"))
        if let range = str.range(of: L("onboarding.demo.sampleHighlight.phrase")) {
            str[range].backgroundColor = UIColor(Color(hexString: highlightColors[0]) ?? .yellow)
        }
        return str
    }

    // Mitten im Artikel gescrollt: Text mit gelber Markierung, darüber die
    // Leiste am oberen Bildschirmrand wie `HighlightToolbarView` (die Auswahl
    // liegt in der unteren Hälfte, deshalb dockt sie oben an).
    private var highlightScene: some View {
        VStack(alignment: .leading, spacing: 0) {
            highlightToolbar
                .tourAnchor("highlightToolbar")

            VStack(alignment: .leading, spacing: 16) {
                Text(L("onboarding.demo.sampleArticle.body"))
                    .lineLimit(4)
                    .foregroundStyle(.secondary)
                Text(highlightedSampleText)
            }
            .font(.body)
            .lineSpacing(4)
            .padding(.horizontal, 20)
            .padding(.top, 28)

            Spacer(minLength: 0)
        }
    }

    private var highlightToolbar: some View {
        let diameter: CGFloat = 40
        return VStack(spacing: 10) {
            Text(L("articleReader.highlightToolbar.title"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                ForEach(highlightColors, id: \.self) { hex in
                    Circle()
                        .fill(Color(hexString: hex) ?? .yellow)
                        .frame(width: diameter, height: diameter)
                        .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 2.5))
                }
                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 1, height: diameter * 0.625)
                toolbarButton(icon: "text.bubble", tint: .primary, diameter: diameter)
                toolbarButton(icon: "xmark", tint: .red, diameter: diameter)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, safeTop + 14)
        .padding(.bottom, 18)
        .background(
            Color(.systemBackground)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        )
    }

    private func toolbarButton(icon: String, tint: Color, diameter: CGFloat) -> some View {
        Circle()
            .fill(Color(.systemGray5))
            .frame(width: diameter, height: diameter)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
            )
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
    /// Dieselbe Einstellung wie „Akzentfarbe“ im Erscheinungsbild des Lesemenüs.
    @AppStorage("merlin_accent_progress_color") private var accentColorHex: String = "#FF3B30"
    @State private var initialAccentColorHex: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    /// Dim opacity: lighter in dark mode so the spotlight cutout stays visible
    /// against an already-dark background.
    private var dimOpacity: Double { colorScheme == .dark ? 0.55 : 0.72 }

    private var tourSteps: [TourStep] { makeTourSteps(retentionBody: RetentionStore.shared.summaryText,
                                                    isCardView: isCardView) }
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
            DemoRowSwipe()

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
                .foregroundStyle(step.showsAccentPicker ? (Color(hexString: accentColorHex) ?? .white) : .white)
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

            if step.showsAccentPicker {
                accentColorChooser
                    .padding(.bottom, 24)
            }

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

    // MARK: Accent color

    private var accentColorChooser: some View {
        HStack(spacing: 10) {
            ForEach(accentColorPresets, id: \.self) { hex in
                let selected = accentColorHex.uppercased() == hex
                Button {
                    setAccentColor(hex)
                } label: {
                    Circle()
                        .fill(Color(hexString: hex) ?? .red)
                        .frame(width: 32, height: 32)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: selected ? 3 : 0))
                        .overlay(Circle().strokeBorder(Color(white: 0.11), lineWidth: selected ? 1.5 : 0)
                            .padding(3))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }

            ColorPicker(L("onboarding.accentColor.custom"), selection: Binding(
                get: { Color(hexString: accentColorHex) ?? .red },
                set: { setAccentColor($0.hexString) }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 32, height: 32)
        }
    }

    private func setAccentColor(_ hex: String) {
        if initialAccentColorHex == nil { initialAccentColorHex = accentColorHex }
        accentColorHex = hex
        PreferencesStore.shared.accentProgressColorHex = hex
    }

    /// Schickt eine in der Tour geänderte Akzentfarbe einmalig an den Server
    /// (wie das Erscheinungsbild im Lesemenü), statt bei jeder Bewegung im ColorPicker.
    private func pushAccentColorIfChanged() {
        guard let initial = initialAccentColorHex, initial != accentColorHex else { return }
        Task {
            do {
                try await MerlinAPI.shared.updateSettings(PreferencesStore.shared.toServerDict())
            } catch {
                if case MerlinAPIError.networkError = error {
                    SettingsSyncQueue.shared.markDirty()
                }
            }
        }
    }

    // MARK: Finish

    private func finish() {
        pushAccentColorIfChanged()
        UserDefaults.standard.set(true, forKey: "merlin_tour_done")
        // Die Tour enthält den Löschfrist-Schritt: ein offener Hinweis ist damit erledigt.
        Task { await RetentionStore.shared.acknowledgeNotice() }
        withAnimation(.easeInOut(duration: 0.25)) { isPresented = false }
    }
}
