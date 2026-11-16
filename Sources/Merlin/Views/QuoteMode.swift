import SwiftUI
import UIKit
import WebKit
import Photos
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: – Zitat-Ansicht
//
// Bleibt eine Textauswahl im Reader fünf Sekunden stehen, legt sich milchiges
// Glas über den ganzen Bildschirm. Der markierte Text gleitet aus seiner Stelle
// im Artikel in die Mitte und liegt dort auf dem Glas, darunter „Bild speichern“
// und „Teilen“. Leisten, Markierungsleiste, iOS-Menü und Statusleiste sind weg.
// Ein Tipp irgendwo anders schließt die Ansicht.
//
// Ablauf:
// 1. `arm` startet nach jeder zur Ruhe gekommenen Auswahl den 5-s-Timer neu,
//    `disarm` hält ihn an (Auswahl weg, Scrollen, Finger auf dem Text, Leiste).
// 2. `enter`: das JS (`merlinEnterQuoteMode`) merkt sich die Auswahl und hebt
//    sie auf – damit verschwinden iOS-Menü, Griffe und Auswahl-Ton – und macht
//    den body-Hintergrund durchsichtig.
// 3. `capture`: Zeilen-Rechtecke holen (`merlinQuoteRects`), das umschließende
//    Rechteck des WebViews abfotografieren und auf die Zeilen zuschneiden. Das
//    Ergebnis ist nur die Schrift, mit Alpha. Dazu ein Bild des Fensters ohne
//    Glas als Hintergrund für das spätere Bild zum Speichern/Teilen.
// 4. `QuoteGlassOverlay` zeigt Glas und Text; `close` spielt die Animation
//    rückwärts, `finish` räumt auf und gibt dem JS Bescheid.

/// Farben für Glas und Bild, aus dem Reader-Theme.
struct QuoteStyle {
    /// Reader-Hintergrundfarbe (Tönung des Glases).
    var tint: UIColor = .white
    var isDark = false
    /// „Transparenz reduzieren“: deckende Fläche statt Glas.
    var opaque = false
}

/// Zeilen der Auswahl in WebView-Koordinaten (der WebView scrollt nie selbst).
struct QuoteGeometry {
    let text: String
    let lines: [CGRect]
    let bounds: CGRect

    init?(json: String, clip: CGRect) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["lines"] as? [[Double]] else { return nil }
        // Etwas Luft für Unterlängen, Akzente und kursiven Überhang.
        let lines = raw.compactMap { v -> CGRect? in
            guard v.count == 4 else { return nil }
            let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
                .insetBy(dx: -3, dy: -2)
                .intersection(clip)
            return r.isNull || r.isEmpty ? nil : r
        }
        guard let first = lines.first else { return nil }
        self.lines = lines
        self.bounds = lines.dropFirst().reduce(first) { $0.union($1) }.integral.intersection(clip)
        self.text = object["text"] as? String ?? ""
    }
}

@MainActor
@Observable
final class QuoteModeController {

    /// Wartezeit, bis eine stehende Auswahl die Ansicht öffnet.
    nonisolated static let delay: Duration = .seconds(5)

    /// Ansicht offen, vom Abgreifen bis zum Ende der Schließ-Animation.
    /// Solange sind Leisten, Markierungsleiste und Statusleiste ausgeblendet.
    private(set) var isActive = false
    /// Freigestellter Text (nur die Schrift, Hintergrund durchsichtig).
    private(set) var quoteImage: UIImage?
    /// Lage des Textes im Artikel beim Abgreifen, in Fenster-Koordinaten.
    private(set) var sourceFrame: CGRect = .zero
    /// Markierter Text (VoiceOver).
    private(set) var text = ""
    /// Sichere Fläche des Fensters (Notch, Home-Indikator).
    private(set) var insets = UIEdgeInsets.zero
    /// Nach dem Drehen wird neu abgegriffen; das Overlay ist solange verborgen.
    private(set) var isRecapturing = false
    /// Schließen angefordert: das Overlay spielt die Animation und ruft `finish()`.
    private(set) var isClosing = false
    /// Hinweis „Tippen zum Schließen“ (nur beim allerersten Mal).
    var showHint = false

    @ObservationIgnored private(set) var style = QuoteStyle()
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var background: UIImage?
    @ObservationIgnored private var shareImage: UIImage?
    @ObservationIgnored private var captureID = 0

    // MARK: Timer

    /// Startet den Timer (neu). `fire` läuft nach `delay`, sofern bis dahin
    /// kein `disarm` kam.
    func arm(_ fire: @escaping @MainActor @Sendable () -> Void) {
        timer?.cancel()
        timer = Task { @MainActor in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            fire()
        }
    }

    func disarm() {
        timer?.cancel()
        timer = nil
    }

    // MARK: Öffnen und Schließen

    /// Öffnet die Ansicht für die aktuelle Auswahl im WebView. `false`, wenn
    /// es keine Auswahl (mehr) gibt.
    @discardableResult
    func enter(webView: WKWebView, style: QuoteStyle) async -> Bool {
        disarm()
        guard !isActive else { return false }
        let entered = (try? await webView.evaluateJavaScript(
            "window.merlinEnterQuoteMode?window.merlinEnterQuoteMode():false")) as? Bool ?? false
        guard entered, !isActive else { return false }
        self.webView = webView
        self.style = style
        isActive = true
        isClosing = false
        await capture()
        if quoteImage != nil, !PreferencesStore.shared.readerQuoteHintShown {
            PreferencesStore.shared.readerQuoteHintShown = true
            showHint = true
        }
        return quoteImage != nil
    }

    /// Tipp aufs Glas: zurück zur normalen Artikelansicht (mit Animation).
    func close() {
        guard isActive, !isClosing else { return }
        if quoteImage == nil { finish() } else { isClosing = true }
    }

    /// Sofort schließen und aufräumen (Ende der Animation, App im Hintergrund,
    /// Artikel verlassen). Die Auswahl bleibt weg.
    func finish() {
        disarm()
        captureID += 1
        let wasActive = isActive
        isActive = false
        isClosing = false
        isRecapturing = false
        showHint = false
        quoteImage = nil
        background = nil
        shareImage = nil
        text = ""
        if wasActive {
            webView?.evaluateJavaScript("window.merlinExitQuoteMode&&window.merlinExitQuoteMode()")
        }
    }

    /// Bildschirmgröße geändert (Drehen): der Artikel bricht neu um, also
    /// Text und Hintergrund neu abgreifen.
    func recapture() {
        guard isActive, !isClosing, quoteImage != nil else { return }
        isRecapturing = true
        Task { @MainActor [weak self] in
            // Drehung und Neu-Umbruch abwarten.
            try? await Task.sleep(for: .milliseconds(350))
            await self?.capture()
        }
    }

    // MARK: Abgreifen

    private func capture() async {
        captureID += 1
        let id = captureID
        // iOS-Menü, Auswahl-Ton und ausgeblendete Leisten sind dann sicher weg.
        try? await Task.sleep(for: .milliseconds(250))
        guard id == captureID, isActive, let webView else { return }
        let json = (try? await webView.evaluateJavaScript(
            "window.merlinQuoteRects?window.merlinQuoteRects():''")) as? String ?? ""
        guard id == captureID, isActive else { return }
        guard let geometry = QuoteGeometry(json: json, clip: webView.bounds), !geometry.bounds.isEmpty else {
            return finish()
        }
        let config = WKSnapshotConfiguration()
        config.rect = geometry.bounds
        config.afterScreenUpdates = true
        guard let snapshot = try? await webView.takeSnapshot(configuration: config) else {
            return finish()
        }
        guard id == captureID, isActive else { return }
        let window = webView.window
        background = Self.snapshot(of: window)
        insets = window?.safeAreaInsets ?? .zero
        sourceFrame = webView.convert(geometry.bounds, to: nil)
        text = geometry.text
        shareImage = nil
        quoteImage = QuoteImageRenderer.cutOut(snapshot, geometry: geometry)
        isRecapturing = false
    }

    private static func snapshot(of window: UIWindow?) -> UIImage? {
        guard let window, window.bounds.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    // MARK: Bild zum Speichern und Teilen

    /// So wie die Ansicht, nur ohne Knöpfe: verschwommener Artikel, getönt,
    /// der Text in der Mitte. Wird beim ersten Bedarf gebaut und gemerkt.
    func makeShareImage() -> UIImage? {
        if let shareImage { return shareImage }
        guard let quoteImage else { return nil }
        let canvas = background?.size ?? webView?.window?.bounds.size ?? .zero
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let scale = background?.scale ?? webView?.window?.traitCollection.displayScale ?? 2
        let image = QuoteImageRenderer.compose(background: background, quote: quoteImage,
                                               canvas: canvas, scale: scale, style: style)
        shareImage = image
        return image
    }

    /// Bild im Voraus bauen, damit beide Knöpfe sofort reagieren.
    func prepareShareImage() {
        guard shareImage == nil, quoteImage != nil else { return }
        _ = makeShareImage()
    }
}

// MARK: – Bilder

enum QuoteImageRenderer {

    /// Schneidet aus dem Snapshot alles außerhalb der Zeilen weg (der Rest
    /// der ersten und letzten Zeile).
    @MainActor
    static func cutOut(_ snapshot: UIImage, geometry: QuoteGeometry) -> UIImage {
        let origin = geometry.bounds.origin
        let size = geometry.bounds.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = snapshot.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let path = UIBezierPath()
            for line in geometry.lines {
                path.append(UIBezierPath(rect: line.offsetBy(dx: -origin.x, dy: -origin.y)))
            }
            path.addClip()
            snapshot.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Bild in Bildschirmgröße: Hintergrund verschwommen und getönt (bzw.
    /// deckend bei „Transparenz reduzieren“), der Text zentriert darauf.
    @MainActor
    static func compose(background: UIImage?, quote: UIImage, canvas: CGSize,
                        scale: CGFloat, style: QuoteStyle) -> UIImage {
        let rect = CGRect(origin: .zero, size: canvas)
        let blurred = style.opaque ? nil : background.flatMap { blur($0, radius: 14) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            style.tint.setFill()
            ctx.fill(rect)
            if let blurred {
                blurred.draw(in: rect)
                // Entspricht ungefähr Material plus Tönung im Overlay.
                style.tint.withAlphaComponent(style.isDark ? 0.22 : 0.25).setFill()
                ctx.fill(rect)
            }
            quote.draw(in: fitted(quote.size, in: rect.insetBy(dx: 24, dy: 48)))
        }
    }

    /// Größe `size` mittig in `area`, nur verkleinert, nie vergrößert.
    static func fitted(_ size: CGSize, in area: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else {
            return CGRect(x: area.midX, y: area.midY, width: 0, height: 0)
        }
        let s = min(1, area.width / size.width, area.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    private static func blur(_ image: UIImage, radius: CGFloat) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let gaussian = CIFilter.gaussianBlur()
        gaussian.inputImage = input.clampedToExtent()
        gaussian.radius = Float(radius * image.scale)
        let color = CIFilter.colorControls()
        color.inputImage = gaussian.outputImage
        color.saturation = 1.3
        guard let output = color.outputImage?.cropped(to: input.extent),
              let result = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: result, scale: image.scale, orientation: .up)
    }
}

// MARK: – Speichern und Teilen

@MainActor
enum QuoteImageActions {
    enum SaveResult { case saved, denied, failed }

    /// Legt das Bild in der Fotomediathek ab (Berechtigung „nur hinzufügen“).
    static func save(_ image: UIImage) async -> SaveResult {
        guard let data = image.pngData() else { return .failed }
        // Die Photos-Callbacks laufen auf fremden Queues: ausdrücklich @Sendable,
        // damit sie nicht als MainActor-Closures gelten (Laufzeit-Prüfung in Swift 6).
        let status = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { @Sendable status in
                cont.resume(returning: status)
            }
        }
        guard status == .authorized || status == .limited else { return .denied }
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges({ @Sendable in
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { @Sendable success, _ in
                cont.resume(returning: success)
            })
        }
        return ok ? .saved : .failed
    }

    /// Teilen-Menü mit dem Bild.
    static func share(_ image: UIImage) {
        guard let presenter = topViewController() else { return }
        let sheet = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 80,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

// MARK: – Overlay

/// Legt Overlay, Statusleiste und Lebenszyklus der Zitat-Ansicht um den Reader.
/// Als eigener Modifier, damit `ArticleReaderView.body` klein genug bleibt.
struct QuoteModeLayer: ViewModifier {
    let controller: QuoteModeController
    let bgColor: Color
    let accent: Color
    let onAccent: Color
    let isDark: Bool
    let scenePhase: ScenePhase
    let articleId: Int
    let viewportSize: CGSize

    func body(content: Content) -> some View {
        content
            .overlay {
                if controller.quoteImage != nil {
                    QuoteGlassOverlay(controller: controller, bgColor: bgColor,
                                      accent: accent, onAccent: onAccent)
                        .environment(\.colorScheme, isDark ? .dark : .light)
                }
            }
            .statusBarHidden(controller.isActive)
            .persistentSystemOverlays(controller.isActive ? .hidden : .automatic)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { controller.finish() }
            }
            .onChange(of: articleId) { _, _ in controller.finish() }
            .onChange(of: viewportSize) { _, _ in controller.recapture() }
            .onDisappear { controller.finish() }
    }
}

private struct QuoteGlassOverlay: View {
    let controller: QuoteModeController
    let bgColor: Color
    let accent: Color
    let onAccent: Color

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Glas da, Text in der Mitte. Animiert beim Öffnen und Schließen.
    @State private var lifted = false
    @State private var saveState: SaveState = .idle
    @State private var showDeniedAlert = false
    @State private var showSaveFailed = false

    private enum SaveState { case idle, saving, saved }

    private static let buttonHeight: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                glass
                    .opacity(lifted ? 1 : 0)
                quoteText(canvas: geo.size, origin: origin)
                hint
                buttons
                    .opacity(lifted ? 1 : 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { controller.close() }
        .opacity(controller.isRecapturing ? 0 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { controller.close() }
        .accessibilityAction(named: Text(L("articleReader.quote.close"))) { controller.close() }
        .onAppear {
            withAnimation(Self.liftAnimation(reduceMotion)) { lifted = true }
            Task { @MainActor in
                // Erst nach der Einblend-Animation, damit sie nicht ruckelt.
                try? await Task.sleep(for: .milliseconds(600))
                controller.prepareShareImage()
                if controller.showHint {
                    try? await Task.sleep(for: .milliseconds(900))
                    withAnimation(.easeOut(duration: 0.3)) { controller.showHint = false }
                }
            }
        }
        .onChange(of: controller.isClosing) { _, closing in
            guard closing else { return }
            withAnimation(Self.liftAnimation(reduceMotion)) {
                lifted = false
            } completion: {
                controller.finish()
            }
        }
        .alert(L("articleReader.quote.photosDenied.title"), isPresented: $showDeniedAlert) {
            Button(L("articleReader.quote.photosDenied.settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("articleReader.quote.photosDenied.message"))
        }
        .alert(L("articleReader.quote.saveFailed"), isPresented: $showSaveFailed) {
            Button(L("common.ok"), role: .cancel) {}
        }
    }

    private static func liftAnimation(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.86)
    }

    // MARK: Teile

    @ViewBuilder
    private var glass: some View {
        if reduceTransparency || controller.style.opaque {
            bgColor
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(bgColor.opacity(0.08))
        }
    }

    @ViewBuilder
    private func quoteText(canvas: CGSize, origin: CGPoint) -> some View {
        if let image = controller.quoteImage {
            let target = targetFrame(for: image.size, canvas: canvas)
            let source = controller.sourceFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            // Bewegung reduzieren: nicht gleiten, nur ein- und ausblenden.
            let frame = (lifted || reduceMotion) ? target : source
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: frame.width, height: frame.height)
                .shadow(color: bgColor.opacity(lifted ? 0.9 : 0), radius: 3)
                .position(x: frame.midX, y: frame.midY)
                .opacity(reduceMotion && !lifted ? 0 : 1)
                .accessibilityLabel(controller.text)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    /// Mitte der Fläche zwischen oberem Rand und den Knöpfen; nur verkleinert,
    /// wenn der Text sonst nicht hineinpasst.
    private func targetFrame(for size: CGSize, canvas: CGSize) -> CGRect {
        let insets = controller.insets
        let top = max(insets.top, 20) + 16
        let bottom = max(insets.bottom, 16) + 12 + Self.buttonHeight + 24
        let side = max(insets.left, insets.right, 16)
        let area = CGRect(x: side, y: top,
                          width: canvas.width - 2 * side,
                          height: canvas.height - top - bottom)
        return QuoteImageRenderer.fitted(size, in: area)
    }

    @ViewBuilder
    private var hint: some View {
        if controller.showHint {
            Text(L("articleReader.quote.hint"))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, max(controller.insets.top, 20) + 8)
                .frame(maxWidth: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            QuoteActionButton(title: saveState == .saved ? L("articleReader.quote.saved") : L("articleReader.quote.save"),
                              systemImage: saveState == .saved ? "checkmark" : "square.and.arrow.down",
                              height: Self.buttonHeight, accent: accent, onAccent: onAccent) {
                save()
            }
            QuoteActionButton(title: L("articleReader.quote.share"),
                              systemImage: "square.and.arrow.up",
                              height: Self.buttonHeight, accent: accent, onAccent: onAccent) {
                if let image = controller.makeShareImage() { QuoteImageActions.share(image) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, max(controller.insets.bottom, 16) + 12)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func save() {
        guard saveState == .idle, let image = controller.makeShareImage() else { return }
        saveState = .saving
        Task { @MainActor in
            switch await QuoteImageActions.save(image) {
            case .saved:
                withAnimation(.easeInOut(duration: 0.2)) { saveState = .saved }
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.easeInOut(duration: 0.2)) { saveState = .idle }
            case .denied:
                saveState = .idle
                showDeniedAlert = true
            case .failed:
                saveState = .idle
                showSaveFailed = true
            }
        }
    }
}

private struct QuoteActionButton: View {
    let title: String
    let systemImage: String
    let height: CGFloat
    let accent: Color
    let onAccent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(onAccent)
                .padding(.horizontal, 20)
                .frame(height: height)
                .contentShape(Capsule())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .modifier(QuoteButtonBackground(accent: accent))
    }
}

private struct QuoteButtonBackground: ViewModifier {
    let accent: Color

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(accent.opacity(0.6)).interactive(), in: Capsule())
        } else {
            content.background(accent, in: Capsule())
        }
    }
}
