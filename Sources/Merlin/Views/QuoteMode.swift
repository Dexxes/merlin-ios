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
    /// Reader-Schriftfarbe (Zeile mit Autor und Quelle).
    var textColor: UIColor = .black
    /// Autor des Artikels, falls bekannt.
    var author: String?
    /// Quelle als Domain ohne „www.“, z. B. „spiegel.de“.
    var source: String?
    /// Schriftgröße des Readers (Startwert für neu gesetzten Text).
    var fontSize: CGFloat = 17

    /// Domain aus der Artikel-URL, ohne „www.“.
    static func source(from url: String) -> String? {
        guard var host = URL(string: url)?.host(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
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
    /// Freigestellter Text aus dem Artikel (nur die Schrift, Hintergrund
    /// durchsichtig). Mit Schrift „Original“ ist das das angezeigte Bild.
    private(set) var capturedImage: UIImage?
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
    /// Zeile unter dem Zitat: Autor bzw. Quelle zeigen (Schalter in der
    /// Ansicht, auf dem Gerät gemerkt). Gilt auch für das Bild.
    var showAuthor = PreferencesStore.shared.readerQuoteShowAuthor {
        didSet {
            PreferencesStore.shared.readerQuoteShowAuthor = showAuthor
            shareImage = nil
        }
    }
    var showSource = PreferencesStore.shared.readerQuoteShowSource {
        didSet {
            PreferencesStore.shared.readerQuoteShowSource = showSource
            shareImage = nil
        }
    }

    /// „— Autor · spiegel.de“, je nach Schaltern; nil = keine Zeile.
    var caption: String? {
        let parts = [showAuthor ? style.author : nil, showSource ? style.source : nil].compactMap { $0 }
        return parts.isEmpty ? nil : "— " + parts.joined(separator: " · ")
    }

    // MARK: Schrift, Größe, Farbe, Lage

    /// Schrift des Zitats. „Original“ zeigt den Text wie im Artikel (Snapshot);
    /// alle anderen setzen ihn neu, in Größe und Farbe nach Wahl (gemerkt).
    var textFont: QuoteFont = QuoteFont(rawValue: PreferencesStore.shared.readerQuoteFont) ?? .original {
        didSet { PreferencesStore.shared.readerQuoteFont = textFont.rawValue; shareImage = nil }
    }
    /// Schriftgröße in pt; 0 = Größe des Readers.
    var textSize: Double = PreferencesStore.shared.readerQuoteFontSize {
        didSet { PreferencesStore.shared.readerQuoteFontSize = textSize; shareImage = nil }
    }
    var textColor: QuoteTextColor = QuoteTextColor(rawValue: PreferencesStore.shared.readerQuoteTextColor) ?? .auto {
        didSet { PreferencesStore.shared.readerQuoteTextColor = textColor.rawValue; shareImage = nil }
    }
    /// Heller bzw. dunkler Schein in Reader-Farbe hinter der Schrift (gemerkt).
    var textGlow: Bool = PreferencesStore.shared.readerQuoteGlow {
        didSet { PreferencesStore.shared.readerQuoteGlow = textGlow; shareImage = nil }
    }
    /// Stärke des Weichzeichners im Glas, in pt (Regler unter „Design“, gemerkt).
    var glassBlur: Double = PreferencesStore.shared.readerQuoteBlur {
        didSet { PreferencesStore.shared.readerQuoteBlur = glassBlur; shareImage = nil }
    }
    nonisolated static let blurRange: ClosedRange<Double> = 0...40
    /// Vom Nutzer verschoben (Ziehen am Text); gilt nur für dieses Zitat.
    var textOffset: CGSize = .zero
    /// Per Pinch gezoomt; gilt nur für dieses Zitat und ändert die
    /// eingestellte Schriftgröße nicht.
    var textScale: CGFloat = 1 {
        didSet { shareImage = nil }
    }
    /// Erlaubter Bereich für `textScale`.
    nonisolated static let scaleRange: ClosedRange<CGFloat> = 0.4...4

    /// Schriftgröße, die gerade gilt.
    var effectiveTextSize: Double { textSize > 0 ? textSize : Double(style.fontSize) }

    /// Farbe von Zitat (außer „Original“) und Zeile mit Autor/Quelle.
    var textUIColor: UIColor { textColor.uiColor(auto: style.textColor) }

    /// Angezeigter Text: der Snapshot oder der neu gesetzte Text.
    var quoteImage: UIImage? {
        guard let capturedImage else { return nil }
        guard textFont != .original, !text.isEmpty else { return capturedImage }
        let canvasWidth = background?.size.width ?? webView?.window?.bounds.width ?? capturedImage.size.width
        let side = max(insets.left, insets.right, 16)
        let width = min(max(120, canvasWidth - 2 * side - 8), 620)
        let size = effectiveTextSize
        // Gezoomt: in höherer Auflösung setzen, damit die Schrift scharf bleibt.
        let display = webView?.window?.traitCollection.displayScale ?? 3
        let zoom = (min(max(textScale, 1), Self.scaleRange.upperBound) * 2).rounded(.up) / 2
        let key = "\(textFont.rawValue)|\(size)|\(textColor.rawValue)|\(width)|\(style.isDark)|\(zoom)|\(text.hashValue)"
        if let cached = renderedCache, cached.key == key { return cached.image }
        let image = QuoteImageRenderer.renderText(text, font: textFont.uiFont(size: CGFloat(size)),
                                                  color: textUIColor, maxWidth: width,
                                                  scale: display * zoom)
        renderedCache = (key, image)
        return image
    }

    /// Lage des Zitats auf dem Bildschirm, wie das Overlay es zeigt; das Bild
    /// zum Speichern/Teilen übernimmt sie.
    func setLayoutFrame(_ frame: CGRect) {
        guard frame != layoutFrame else { return }
        layoutFrame = frame
        shareImage = nil
    }

    @ObservationIgnored private var renderedCache: (key: String, image: UIImage)?
    @ObservationIgnored private var layoutFrame: CGRect?

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
        if capturedImage != nil, !PreferencesStore.shared.readerQuoteHintShown {
            PreferencesStore.shared.readerQuoteHintShown = true
            showHint = true
        }
        return capturedImage != nil
    }

    /// Tipp aufs Glas: zurück zur normalen Artikelansicht (mit Animation).
    func close() {
        guard isActive, !isClosing else { return }
        if capturedImage == nil { finish() } else { isClosing = true }
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
        capturedImage = nil
        textOffset = .zero
        textScale = 1
        layoutFrame = nil
        background = nil
        glassCache = nil
        shareImage = nil
        text = ""
        if wasActive {
            webView?.evaluateJavaScript("window.merlinExitQuoteMode&&window.merlinExitQuoteMode()")
        }
    }

    /// Bildschirmgröße geändert (Drehen): der Artikel bricht neu um, also
    /// Text und Hintergrund neu abgreifen.
    func recapture() {
        guard isActive, !isClosing, capturedImage != nil else { return }
        isRecapturing = true
        textOffset = .zero
        textScale = 1
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
        // Doppelte Auflösung, damit „Original“ auch gezoomt scharf bleibt
        // (bei sehr langen Auswahlen nicht, wegen des Speichers).
        let displayScale = webView.window?.traitCollection.displayScale ?? 3
        let pixels = geometry.bounds.width * geometry.bounds.height * displayScale * displayScale
        if pixels * 4 <= 16_000_000 {
            config.snapshotWidth = NSNumber(value: Double(geometry.bounds.width * 2))
        }
        guard let snapshot = try? await webView.takeSnapshot(configuration: config) else {
            return finish()
        }
        guard id == captureID, isActive else { return }
        // Sichtbarer Teil des Artikels, extra abfotografiert: `drawHierarchy`
        // nimmt den Inhalt eines WKWebView nicht immer mit.
        var page: (image: UIImage, frame: CGRect)?
        if let window = webView.window {
            let visible = webView.convert(window.bounds, from: window).intersection(webView.bounds)
            if !visible.isNull, !visible.isEmpty {
                let pageConfig = WKSnapshotConfiguration()
                pageConfig.rect = visible
                if let image = try? await webView.takeSnapshot(configuration: pageConfig) {
                    page = (image, webView.convert(visible, to: nil))
                }
            }
        }
        guard id == captureID, isActive else { return }
        let window = webView.window
        background = Self.snapshot(of: window, page: page)
        glassCache = nil
        insets = window?.safeAreaInsets ?? .zero
        sourceFrame = webView.convert(geometry.bounds, to: nil)
        text = geometry.text
        shareImage = nil
        capturedImage = QuoteImageRenderer.cutOut(snapshot, geometry: geometry)
        isRecapturing = false
    }

    private static func snapshot(of window: UIWindow?, page: (image: UIImage, frame: CGRect)?) -> UIImage? {
        guard let window, window.bounds.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            page?.image.draw(in: page?.frame ?? .zero)
        }
    }

    // MARK: Bild zum Speichern und Teilen

    /// Abzug des Fensters, genau wie auf dem Bildschirm (Glas und
    /// gezeichneter Hintergrund inklusive). Das Overlay blendet vorher die
    /// Knöpfe aus. Die Statusleiste ist in der Ansicht ohnehin verborgen.
    func screenImage() -> UIImage? {
        guard let window = webView?.window, window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        format.opaque = true
        format.preferredRange = .standard
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return drawn ? image : nil
    }

    /// So wie die Ansicht, nur ohne Knöpfe: verschwommener Artikel, getönt,
    /// der Text in der Mitte. Wird beim ersten Bedarf gebaut und gemerkt.
    func makeShareImage() -> UIImage? {
        if let shareImage { return shareImage }
        guard let quoteImage else { return nil }
        let canvas = background?.size ?? webView?.window?.bounds.size ?? .zero
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let scale = background?.scale ?? webView?.window?.traitCollection.displayScale ?? 2
        let image = QuoteImageRenderer.compose(background: glassImage(), quote: quoteImage, frame: layoutFrame,
                                               caption: caption, captionColor: textUIColor, glow: textGlow,
                                               canvas: canvas, scale: scale, style: style)
        shareImage = image
        return image
    }

    // MARK: Hintergründe

    /// Hintergrund hinter dem Glas; horizontal wischen wechselt ihn.
    /// `.article` ist der Artikel selbst, die übrigen sind gezeichnet.
    var backdrop: QuoteBackdrop = QuoteBackdrop(rawValue: PreferencesStore.shared.readerQuoteBackdrop) ?? .article {
        didSet {
            PreferencesStore.shared.readerQuoteBackdrop = backdrop.rawValue
            shareImage = nil
        }
    }

    @ObservationIgnored private var glassCache: (key: String, image: UIImage)?

    /// Das Glas: Hintergrund (Artikel oder gezeichnet) weichgezeichnet, ohne
    /// Tönung, also farblos. nil, solange noch nichts abgegriffen ist.
    func glassImage() -> UIImage? {
        let source = backdrop == .article ? background : backdropImage(backdrop)
        guard let source else { return nil }
        let radius = glassBlur.rounded()
        let key = "\(backdrop.rawValue)|\(radius)|\(source.size.width)x\(source.size.height)"
        if let glassCache, glassCache.key == key { return glassCache.image }
        let image = radius > 0 ? (QuoteImageRenderer.blur(source, radius: CGFloat(radius)) ?? source) : source
        glassCache = (key, image)
        return image
    }

    @ObservationIgnored private var backdropCache: [QuoteBackdrop: UIImage] = [:]
    @ObservationIgnored private var backdropCacheSize: CGSize = .zero

    /// Gezeichneter Hintergrund in Bildschirmgröße (nil für `.article`).
    /// Auflösung 1×: er liegt ohnehin verschwommen unter dem Glas.
    func backdropImage(_ backdrop: QuoteBackdrop) -> UIImage? {
        guard backdrop != .article else { return nil }
        let size = background?.size ?? webView?.window?.bounds.size ?? .zero
        if size != backdropCacheSize {
            backdropCache = [:]
            backdropCacheSize = size
        }
        if let cached = backdropCache[backdrop] { return cached }
        let image = backdrop.render(size: size)
        backdropCache[backdrop] = image
        return image
    }

    /// Nächster bzw. vorheriger Hintergrund (rundum).
    func stepBackdrop(by delta: Int) {
        let all = QuoteBackdrop.allCases
        guard let index = all.firstIndex(of: backdrop) else { return }
        backdrop = all[(index + delta + all.count) % all.count]
    }

    /// Bild im Voraus bauen, damit beide Knöpfe sofort reagieren.
    func prepareShareImage() {
        guard shareImage == nil, quoteImage != nil else { return }
        _ = makeShareImage()
    }
}

// MARK: – Schrift und Farbe des Zitats

/// Schriften für das Zitat. `.original` ist der Snapshot aus dem Artikel.
enum QuoteFont: Int, CaseIterable {
    case original, system, serif, rounded, georgia, typewriter, handwriting, script

    var title: String {
        switch self {
        case .original:    return L("articleReader.quote.font.original")
        case .system:      return L("articleReader.quote.font.system")
        case .serif:       return L("articleReader.quote.font.serif")
        case .rounded:     return L("articleReader.quote.font.rounded")
        case .georgia:     return "Georgia"
        case .typewriter:  return L("articleReader.quote.font.typewriter")
        case .handwriting: return L("articleReader.quote.font.handwriting")
        case .script:      return L("articleReader.quote.font.script")
        }
    }

    func uiFont(size: CGFloat) -> UIFont {
        switch self {
        case .original, .system: return .systemFont(ofSize: size)
        case .serif:       return Self.designed(.serif, size: size)
        case .rounded:     return Self.designed(.rounded, size: size)
        case .georgia:     return UIFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        case .typewriter:  return UIFont(name: "AmericanTypewriter", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .handwriting: return UIFont(name: "Noteworthy-Light", size: size) ?? .systemFont(ofSize: size)
        // Schreibschrift läuft klein, darum etwas größer.
        case .script:      return UIFont(name: "SnellRoundhand", size: size * 1.25) ?? .systemFont(ofSize: size)
        }
    }

    private static func designed(_ design: UIFontDescriptor.SystemDesign, size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size)
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// Schriftfarben für das Zitat. `.auto` ist die Schriftfarbe des Readers.
enum QuoteTextColor: Int, CaseIterable {
    case auto, white, black, red, amber, green, blue, violet

    func uiColor(auto: UIColor) -> UIColor {
        switch self {
        case .auto:   return auto
        case .white:  return .white
        case .black:  return UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        case .red:    return UIColor(red: 0.88, green: 0.11, blue: 0.28, alpha: 1)
        case .amber:  return UIColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1)
        case .green:  return UIColor(red: 0.06, green: 0.6, blue: 0.4, alpha: 1)
        case .blue:   return UIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1)
        case .violet: return UIColor(red: 0.49, green: 0.23, blue: 0.93, alpha: 1)
        }
    }

    var title: String {
        switch self {
        case .auto:   return L("articleReader.quote.color.auto")
        case .white:  return L("articleReader.quote.color.white")
        case .black:  return L("articleReader.quote.color.black")
        case .red:    return L("articleReader.quote.color.red")
        case .amber:  return L("articleReader.quote.color.amber")
        case .green:  return L("articleReader.quote.color.green")
        case .blue:   return L("articleReader.quote.color.blue")
        case .violet: return L("articleReader.quote.color.violet")
        }
    }
}

// MARK: – Hintergründe hinter dem Glas

/// Wählbare Hintergründe der Zitat-Ansicht. Alle werden mit Core Graphics
/// gezeichnet (keine Bild-Dateien) und liegen unter dem Glas, also
/// verschwommen; Formen sind darum groß und kräftig. Zufall mit festem
/// Startwert, damit ein Hintergrund immer gleich aussieht.
enum QuoteBackdrop: Int, CaseIterable {
    case article, bubbles, sunset, ocean, hearts, rainbow, aurora, candy

    var title: String {
        switch self {
        case .article: return L("articleReader.quote.backdrop.article")
        case .bubbles: return L("articleReader.quote.backdrop.bubbles")
        case .sunset:  return L("articleReader.quote.backdrop.sunset")
        case .ocean:   return L("articleReader.quote.backdrop.ocean")
        case .hearts:  return L("articleReader.quote.backdrop.hearts")
        case .rainbow: return L("articleReader.quote.backdrop.rainbow")
        case .aurora:  return L("articleReader.quote.backdrop.aurora")
        case .candy:   return L("articleReader.quote.backdrop.candy")
        }
    }

    @MainActor
    func render(size: CGSize) -> UIImage? {
        guard self != .article, size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)
            var rng = SeededRandom(seed: UInt64(rawValue) &* 7919 &+ 17)
            let w = size.width, h = size.height
            switch self {
            case .article:
                break
            case .bubbles:
                Self.linear(cg, [0x312E81, 0x581C87, 0x0F172A],
                            from: CGPoint(x: 0, y: 0), to: CGPoint(x: w, y: h))
                let palette: [UInt32] = [0xF472B6, 0x22D3EE, 0xFACC15, 0xA3E635, 0xFB923C, 0xA78BFA, 0x34D399]
                for _ in 0..<26 {
                    let r = CGFloat.random(in: 28...110, using: &rng)
                    let c = CGPoint(x: CGFloat.random(in: 0...w, using: &rng),
                                    y: CGFloat.random(in: 0...h, using: &rng))
                    let color = palette[Int.random(in: 0..<palette.count, using: &rng)]
                    let circle = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                    cg.setFillColor(Self.rgb(color, alpha: 0.8).cgColor)
                    cg.fillEllipse(in: circle)
                    // Glanzlicht oben links, damit es nach Blase aussieht.
                    cg.setFillColor(UIColor.white.withAlphaComponent(0.35).cgColor)
                    cg.fillEllipse(in: CGRect(x: c.x - r * 0.55, y: c.y - r * 0.6,
                                              width: r * 0.5, height: r * 0.35))
                }
            case .sunset:
                Self.linear(cg, [0x3B0764, 0xBE185D, 0xF97316, 0xFDE68A],
                            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: h))
                Self.blob(cg, center: CGPoint(x: w * 0.5, y: h * 0.72), radius: w * 0.55, color: 0xFFF7AE, alpha: 0.9)
                Self.blob(cg, center: CGPoint(x: w * 0.1, y: h * 0.25), radius: w * 0.5, color: 0xF472B6, alpha: 0.5)
            case .ocean:
                Self.linear(cg, [0x67E8F9, 0x0EA5E9, 0x1D4ED8, 0x1E1B4B],
                            from: CGPoint(x: w, y: 0), to: CGPoint(x: 0, y: h))
                Self.blob(cg, center: CGPoint(x: w * 0.8, y: h * 0.2), radius: w * 0.6, color: 0xA7F3D0, alpha: 0.55)
                Self.blob(cg, center: CGPoint(x: w * 0.15, y: h * 0.8), radius: w * 0.55, color: 0x6366F1, alpha: 0.6)
            case .hearts:
                Self.linear(cg, [0xFFE4E6, 0xFBCFE8, 0xF9A8D4],
                            from: CGPoint(x: 0, y: 0), to: CGPoint(x: w, y: h))
                let palette: [UInt32] = [0xE11D48, 0xF43F5E, 0xDB2777, 0xEC4899, 0xBE123C, 0xFB7185]
                for _ in 0..<20 {
                    let s = CGFloat.random(in: 50...140, using: &rng)
                    let c = CGPoint(x: CGFloat.random(in: 0...w, using: &rng),
                                    y: CGFloat.random(in: 0...h, using: &rng))
                    let angle = CGFloat.random(in: -0.45...0.45, using: &rng)
                    let color = palette[Int.random(in: 0..<palette.count, using: &rng)]
                    cg.saveGState()
                    cg.translateBy(x: c.x, y: c.y)
                    cg.rotate(by: angle)
                    cg.addPath(Self.heart(in: CGRect(x: -s / 2, y: -s / 2, width: s, height: s * 0.9)).cgPath)
                    cg.setFillColor(Self.rgb(color, alpha: 0.85).cgColor)
                    cg.fillPath()
                    cg.restoreGState()
                }
            case .rainbow:
                Self.linear(cg, [0x7DD3FC, 0xBAE6FD, 0xF0F9FF],
                            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: h))
                let colors: [UInt32] = [0xEF4444, 0xF97316, 0xFACC15, 0x22C55E, 0x3B82F6, 0x6366F1, 0xA855F7]
                let center = CGPoint(x: w / 2, y: h * 0.78)
                let band = max(w, h) * 0.055
                let outer = max(w, h) * 0.62
                cg.setLineWidth(band + 1)
                for (i, color) in colors.enumerated() {
                    let r = outer - CGFloat(i) * band
                    cg.setStrokeColor(Self.rgb(color).cgColor)
                    cg.addArc(center: center, radius: r, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
                    cg.strokePath()
                }
                // Wolken an den Enden.
                for x in [w * 0.5 - outer + 3.5 * band, w * 0.5 + outer - 3.5 * band] {
                    for (dx, dy, r) in [(-0.9, 0.2, 0.9), (0.0, 0.0, 1.2), (0.9, 0.25, 0.85)] as [(CGFloat, CGFloat, CGFloat)] {
                        let rr = r * band * 2.2
                        cg.setFillColor(UIColor.white.cgColor)
                        cg.fillEllipse(in: CGRect(x: x + dx * band * 2.2 - rr, y: center.y + dy * band * 2.2 - rr,
                                                  width: 2 * rr, height: 2 * rr))
                    }
                }
            case .aurora:
                cg.setFillColor(Self.rgb(0x0B1026).cgColor)
                cg.fill(rect)
                Self.blob(cg, center: CGPoint(x: w * 0.2, y: h * 0.25), radius: w * 0.75, color: 0x22C55E, alpha: 0.75)
                Self.blob(cg, center: CGPoint(x: w * 0.85, y: h * 0.4), radius: w * 0.7, color: 0x14B8A6, alpha: 0.7)
                Self.blob(cg, center: CGPoint(x: w * 0.4, y: h * 0.7), radius: w * 0.8, color: 0x8B5CF6, alpha: 0.75)
                Self.blob(cg, center: CGPoint(x: w * 0.9, y: h * 0.9), radius: w * 0.6, color: 0xEC4899, alpha: 0.6)
            case .candy:
                cg.setFillColor(UIColor.white.cgColor)
                cg.fill(rect)
                Self.blob(cg, center: CGPoint(x: w * 0.15, y: h * 0.15), radius: w * 0.8, color: 0xF9A8D4, alpha: 0.95)
                Self.blob(cg, center: CGPoint(x: w * 0.9, y: h * 0.3), radius: w * 0.75, color: 0x93C5FD, alpha: 0.95)
                Self.blob(cg, center: CGPoint(x: w * 0.25, y: h * 0.75), radius: w * 0.8, color: 0xFDE68A, alpha: 0.95)
                Self.blob(cg, center: CGPoint(x: w * 0.85, y: h * 0.85), radius: w * 0.7, color: 0x86EFAC, alpha: 0.95)
            }
        }
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    private static func linear(_ cg: CGContext, _ colors: [UInt32], from start: CGPoint, to end: CGPoint) {
        let cgColors = colors.map { rgb($0).cgColor } as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: nil)
        else { return }
        cg.drawLinearGradient(gradient, start: start, end: end,
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// Weicher Farbfleck: radialer Verlauf von `color` nach durchsichtig.
    private static func blob(_ cg: CGContext, center: CGPoint, radius: CGFloat, color: UInt32, alpha: CGFloat) {
        let cgColors = [rgb(color, alpha: alpha).cgColor, rgb(color, alpha: 0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: [0, 1])
        else { return }
        cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                              endCenter: center, endRadius: radius, options: [])
    }

    /// Herz in `r` (Spitze unten).
    private static func heart(in r: CGRect) -> UIBezierPath {
        let x = r.minX, y = r.minY, w = r.width, h = r.height
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x + w / 2, y: y + h))
        path.addCurve(to: CGPoint(x: x, y: y + h * 0.3),
                      controlPoint1: CGPoint(x: x + w * 0.1, y: y + h * 0.75),
                      controlPoint2: CGPoint(x: x, y: y + h * 0.5))
        path.addArc(withCenter: CGPoint(x: x + w * 0.25, y: y + h * 0.3), radius: w * 0.25,
                    startAngle: .pi, endAngle: 0, clockwise: true)
        path.addArc(withCenter: CGPoint(x: x + w * 0.75, y: y + h * 0.3), radius: w * 0.25,
                    startAngle: .pi, endAngle: 0, clockwise: true)
        path.addCurve(to: CGPoint(x: x + w / 2, y: y + h),
                      controlPoint1: CGPoint(x: x + w, y: y + h * 0.5),
                      controlPoint2: CGPoint(x: x + w * 0.9, y: y + h * 0.75))
        path.close()
        return path
    }
}

/// SplitMix64: kleiner Zufallsgenerator mit festem Startwert.
private struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
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
        // Größer abfotografiert (siehe `capture`): Auflösung behalten.
        format.scale = snapshot.scale * max(1, snapshot.size.width / max(1, size.width))
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
    static func compose(background: UIImage?, quote: UIImage, frame quoteFrame: CGRect?,
                        caption: String?, captionColor: UIColor, glow: Bool, canvas: CGSize,
                        scale: CGFloat, style: QuoteStyle) -> UIImage {
        let rect = CGRect(origin: .zero, size: canvas)
        // `background` ist das fertige Glas (siehe `glassImage`).
        let blurred = style.opaque ? nil : background
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            style.tint.setFill()
            ctx.fill(rect)
            if let blurred {
                blurred.draw(in: rect)
            }
            let area = rect.insetBy(dx: 24, dy: 48)
            // Wie auf dem Bildschirm (auch verschoben); sonst mittig.
            let frame = quoteFrame ?? layout(quote.size, hasCaption: caption != nil, in: area)
            let cg = ctx.cgContext
            if glow {
                // Wie `.shadow(radius: 3)` im Overlay: Schein in Reader-Farbe.
                cg.setShadow(offset: .zero, blur: 6, color: style.tint.withAlphaComponent(0.9).cgColor)
            }
            quote.draw(in: frame)
            if let caption {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: captionFont,
                    .foregroundColor: captionColor.withAlphaComponent(0.75),
                ]
                let width = max(0, rect.maxX - 16 - frame.minX)
                NSAttributedString(string: caption, attributes: attributes).draw(
                    with: CGRect(x: frame.minX, y: frame.maxY + captionGap, width: width, height: captionHeight),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            }
            cg.setShadow(offset: .zero, blur: 0, color: nil)
        }
    }

    /// Setzt den markierten Text neu (andere Schrift, Größe, Farbe): ein Bild
    /// mit durchsichtigem Hintergrund, höchstens `maxWidth` breit.
    @MainActor
    static func renderText(_ text: String, font: UIFont, color: UIColor,
                           maxWidth: CGFloat, scale: CGFloat) -> UIImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = font.pointSize * 0.25
        paragraph.paragraphSpacing = font.pointSize * 0.6
        let string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = string.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                         options: options, context: nil)
        let pad: CGFloat = 4
        let size = CGSize(width: ceil(bounds.width) + 2 * pad, height: ceil(bounds.height) + 2 * pad)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            string.draw(with: CGRect(x: pad, y: pad, width: size.width - 2 * pad, height: size.height - 2 * pad),
                        options: options, context: nil)
        }
    }

    @MainActor private static let ciContext = CIContext()

    /// Abstand und Höhe der Zeile mit Autor/Quelle unter dem Zitat.
    static let captionGap: CGFloat = 10
    static let captionHeight: CGFloat = 22
    @MainActor static var captionFont: UIFont {
        UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .medium)
    }

    /// Lage des Zitats in `area`; mit Zeile darunter wird beides zusammen zentriert.
    static func layout(_ size: CGSize, hasCaption: Bool, in area: CGRect) -> CGRect {
        guard hasCaption else { return fitted(size, in: area) }
        let reserve = captionGap + captionHeight
        let inner = CGRect(x: area.minX, y: area.minY, width: area.width, height: max(0, area.height - reserve))
        // Mitte von `inner` liegt um die halbe Reserve höher: Zitat und Zeile
        // sind damit zusammen mittig in `area`.
        return fitted(size, in: inner)
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

    /// Weichgezeichnet, in 1× (reicht für Unschärfe und ist schnell genug für
    /// den Regler). `radius` in pt.
    @MainActor
    static func blur(_ image: UIImage, radius: CGFloat) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let factor = 1 / max(1, image.scale)
        let input = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let gaussian = CIFilter.gaussianBlur()
        gaussian.inputImage = input.clampedToExtent()
        gaussian.radius = Float(radius)
        let color = CIFilter.colorControls()
        color.inputImage = gaussian.outputImage
        // Alle Werte setzen: ohne Standardwerte wird das Bild sonst flach grau.
        color.brightness = 0
        color.contrast = 1
        color.saturation = 1.15
        guard let output = color.outputImage?.cropped(to: input.extent),
              let result = ciContext.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: result, scale: 1, orientation: .up)
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
    let textColor: Color
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
                    QuoteGlassOverlay(controller: controller, bgColor: bgColor, textColor: textColor,
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
    let textColor: Color
    let accent: Color
    let onAccent: Color

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Glas da, Text in der Mitte. Animiert beim Öffnen und Schließen.
    @State private var lifted = false
    @State private var saveState: SaveState = .idle
    @State private var showDeniedAlert = false
    @State private var showSaveFailed = false
    /// Zug am Text, solange der Finger liegt (danach in `controller.textOffset`).
    @State private var dragOffset: CGSize = .zero
    /// Finger zieht gerade am Text.
    @State private var dragging = false
    /// Feld für Schrift, Größe und Farbe offen.
    @State private var showStylePanel = false
    /// Zoom, solange zwei Finger liegen (danach in `controller.textScale`).
    @State private var pinchScale: CGFloat = 1
    /// Gerade (oder eben noch) gezoomt: kein Hintergrund-Wischen auslösen.
    @State private var pinching = false
    /// Größter Zoom, bei dem das Zitat noch in den Bildschirm passt.
    @State private var scaleLimit: CGFloat = QuoteModeController.scaleRange.upperBound
    /// Knöpfe kurz ausgeblendet, während das Bild abgezogen wird.
    @State private var exporting = false
    /// Bildschirmgröße des Overlays (Hoch- oder Querformat).
    @State private var canvasSize: CGSize = .zero
    /// Hinweis „Für 16:9 Handy drehen“ bzw. „Für 9:16 …“, kurz nach dem Öffnen.
    @State private var showRotateHint = false

    private enum SaveState { case idle, saving, saved }

    private static let buttonHeight: CGFloat = 46
    private static let toggleHeight: CGFloat = 34
    private static let toggleSpacing: CGFloat = 12
    private static let dotsHeight: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                glass(size: geo.size)
                    .opacity(lifted ? 1 : 0)
                // Beim Drehen bleibt das Glas (deckend, solange neu abgegriffen
                // wird); nur Text und Knöpfe warten auf das neue Bild.
                quoteText(canvas: geo.size, origin: origin)
                    .opacity(controller.isRecapturing ? 0 : 1)
                topBar
                    .opacity(lifted && !exporting && !controller.isRecapturing ? 1 : 0)
                closeButton
                    .opacity(lifted && !exporting && !controller.isRecapturing ? 1 : 0)
                buttons
                    .opacity(lifted && !exporting && !controller.isRecapturing ? 1 : 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: geo.size, initial: true) { _, size in
                // Gedreht: der Hinweis hat sich erledigt.
                if (size.width > size.height) != (canvasSize.width > canvasSize.height) {
                    showRotateHint = false
                }
                canvasSize = size
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        // Horizontal wischen: anderer Hintergrund hinter dem Glas.
        .gesture(DragGesture(minimumDistance: 24).onEnded { value in
            let dx = value.translation.width, dy = value.translation.height
            guard backdropsAvailable, !pinching, abs(dx) > 50, abs(dx) > abs(dy) else { return }
            stepBackdrop(dx < 0 ? 1 : -1)
        })
        // Zwei Finger: Zitat zoomen (nur die Darstellung, nicht die Schriftgröße).
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                pinching = true
                pinchScale = value.magnification
            }
            .onEnded { value in
                let range = QuoteModeController.scaleRange
                let scale = min(max(controller.textScale * value.magnification, range.lowerBound),
                                min(range.upperBound, scaleLimit))
                controller.textScale = scale
                pinchScale = 1
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    pinching = false
                }
            })
        .onTapGesture {
            // Erst das Schrift-Feld schließen, dann die Ansicht.
            if showStylePanel {
                withAnimation(.easeInOut(duration: 0.2)) { showStylePanel = false }
            } else {
                controller.close()
            }
        }
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
                    try? await Task.sleep(for: .milliseconds(300))
                }
                // Bei jedem Öffnen: Hinweis aufs andere Format, ein paar Sekunden lang.
                guard !controller.isClosing, controller.isActive else { return }
                withAnimation(.easeOut(duration: 0.3)) { showRotateHint = true }
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.easeOut(duration: 0.4)) { showRotateHint = false }
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

    /// Hintergründe nur, wenn das Glas durchscheint.
    private var backdropsAvailable: Bool {
        !(reduceTransparency || controller.style.opaque)
    }

    private func stepBackdrop(_ delta: Int) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeInOut(duration: 0.35)) { controller.stepBackdrop(by: delta) }
    }

    /// Oben unter der Dynamic Island: Punkte für die Hintergründe, darunter
    /// beim ersten Mal der Hinweis.
    private var topBar: some View {
        VStack(spacing: 8) {
            if backdropsAvailable {
                backdropDots
            }
            hint
            rotateHint
        }
        .padding(.top, max(controller.insets.top, 12) + 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    /// X oben rechts: zurück zum Artikel (wie ein Tipp aufs Glas).
    private var closeButton: some View {
        Button {
            controller.close()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(textColor)
                .frame(width: 36, height: 36)
                .modifier(QuoteGlassCircle())
                // Größere Tippfläche als der sichtbare Knopf.
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("articleReader.quote.close"))
        .padding(.top, max(controller.insets.top, 12) - 1)
        .padding(.trailing, max(controller.insets.right, 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    /// Punkte für die Hintergründe; VoiceOver wechselt per Wischen hoch/runter.
    private var backdropDots: some View {
        HStack(spacing: 7) {
            ForEach(QuoteBackdrop.allCases, id: \.self) { item in
                Circle()
                    .fill(textColor.opacity(item == controller.backdrop ? 0.9 : 0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(height: Self.dotsHeight)
        .padding(.horizontal, 12)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement()
        .accessibilityLabel(L("articleReader.quote.backdropPicker"))
        .accessibilityValue(controller.backdrop.title)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: stepBackdrop(1)
            case .decrement: stepBackdrop(-1)
            @unknown default: break
            }
        }
    }

    /// Das Glas: der Hintergrund (Artikel oder gezeichnet) farblos
    /// weichgezeichnet, Stärke nach Regler. Material nur als Notlösung,
    /// solange es kein Bild gibt.
    @ViewBuilder
    private func glass(size: CGSize) -> some View {
        if reduceTransparency || controller.style.opaque || controller.isRecapturing {
            // Während des Drehens und Neu-Abgreifens: einfarbig statt eines
            // Bildes im alten Format (und nie der Artikel dahinter).
            bgColor
        } else if let image = controller.glassImage(),
                  (image.size.width > image.size.height) == (size.width > size.height) {
            Image(uiImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)
                .id(controller.backdrop)
                .transition(.opacity)
        } else {
            // Noch kein (passendes) Bild: Reader-Farbe, damit der Artikel nicht durchscheint.
            bgColor
        }
    }

    @ViewBuilder
    private func quoteText(canvas: CGSize, origin: CGPoint) -> some View {
        if let image = controller.quoteImage {
            let fitted = targetFrame(for: image.size, canvas: canvas)
            let limit = Self.maxScale(for: fitted.size, canvas: canvas)
            let target = Self.scaled(fitted, by: min(controller.textScale * pinchScale, limit))
            // Verschoben: erst die gemerkte Lage, beim Ziehen dazu der Finger.
            let settled = Self.clamped(target.offsetBy(dx: controller.textOffset.width,
                                                       dy: controller.textOffset.height), in: canvas)
            let moving = Self.clamped(settled.offsetBy(dx: dragOffset.width, dy: dragOffset.height), in: canvas)
            let source = controller.sourceFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            // Bewegung reduzieren: nicht gleiten, nur ein- und ausblenden.
            let frame = (lifted || reduceMotion) ? settled : source
            // Beim Ziehen nur verschieben (Offset), nicht neu anordnen: das
            // läuft flüssig mit dem Finger.
            let shift = (lifted || reduceMotion)
                ? CGSize(width: moving.minX - settled.minX, height: moving.minY - settled.minY) : .zero
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: frame.width, height: frame.height)
                .shadow(color: bgColor.opacity(lifted && controller.textGlow ? 0.9 : 0), radius: 3)
                .contentShape(Rectangle())
                // Globale Koordinaten: in lokalen wandert der Bezug mit dem
                // Text mit, und die Bewegung ruckelt.
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // Beim Zoomen mit zwei Fingern nicht verschieben.
                        var instant = Transaction()
                        instant.disablesAnimations = true
                        withTransaction(instant) { dragOffset = pinching ? .zero : value.translation }
                        if !dragging, !pinching {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { dragging = true }
                        }
                    }
                    .onEnded { value in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragging = false }
                        guard !pinching else { dragOffset = .zero; return }
                        let end = Self.clamped(settled.offsetBy(dx: value.translation.width,
                                                                dy: value.translation.height), in: canvas)
                        var instant = Transaction()
                        instant.disablesAnimations = true
                        withTransaction(instant) {
                            controller.textOffset = CGSize(width: end.minX - target.minX, height: end.minY - target.minY)
                            dragOffset = .zero
                        }
                    })
                // Leicht angehoben, solange der Finger zieht.
                .scaleEffect(dragging ? 1.03 : 1)
                .offset(shift)
                .position(x: frame.midX, y: frame.midY)
                .opacity(reduceMotion && !lifted ? 0 : 1)
                .accessibilityLabel(controller.text)
                .accessibilityAddTraits(.isStaticText)
                .onChange(of: settled, initial: true) { _, rect in controller.setLayoutFrame(rect) }
                .onChange(of: limit, initial: true) { _, value in scaleLimit = value }
            if let caption = controller.caption {
                // Autor/Quelle: linksbündig unter dem Zitat, wie im Bild.
                let width = max(0, canvas.width - frame.minX - 16)
                Text(caption)
                    .font(Font(QuoteImageRenderer.captionFont as CTFont))
                    .foregroundStyle(Color(controller.textUIColor).opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: width, height: QuoteImageRenderer.captionHeight, alignment: .leading)
                    .shadow(color: bgColor.opacity(controller.textGlow ? 0.9 : 0), radius: 3)
                    .offset(shift)
                    .position(x: frame.minX + width / 2,
                              y: frame.maxY + QuoteImageRenderer.captionGap + QuoteImageRenderer.captionHeight / 2)
                    .opacity(lifted ? 1 : 0)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    /// `rect` um seine Mitte vergrößert bzw. verkleinert.
    private static func scaled(_ rect: CGRect, by scale: CGFloat) -> CGRect {
        guard scale != 1 else { return rect }
        let w = rect.width * scale, h = rect.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// Größter Zoom, bei dem ein Zitat der Größe `size` noch ganz zu sehen ist.
    private static func maxScale(for size: CGSize, canvas: CGSize) -> CGFloat {
        let range = QuoteModeController.scaleRange
        guard size.width > 0, size.height > 0 else { return range.upperBound }
        let fit = min((canvas.width - 16) / size.width, (canvas.height - 16) / size.height)
        return min(range.upperBound, max(1, fit))
    }

    /// Hält das Zitat mit etwas Rand im Bildschirm.
    private static func clamped(_ rect: CGRect, in canvas: CGSize) -> CGRect {
        let margin: CGFloat = 8
        var r = rect
        r.origin.x = min(max(margin, r.minX), max(margin, canvas.width - margin - r.width))
        r.origin.y = min(max(margin, r.minY), max(margin, canvas.height - margin - r.height))
        return r
    }

    private var sideInset: CGFloat {
        max(controller.insets.left, controller.insets.right, 16)
    }

    /// Schalter für Autor bzw. Quelle, sofern der Artikel sie kennt.
    private var hasCaptionToggles: Bool {
        controller.style.author != nil || controller.style.source != nil
    }

    /// Mitte der Fläche zwischen oberem Rand und den Knöpfen; nur verkleinert,
    /// wenn der Text sonst nicht hineinpasst.
    private func targetFrame(for size: CGSize, canvas: CGSize) -> CGRect {
        let insets = controller.insets
        let dots = backdropsAvailable ? Self.dotsHeight + 8 : 0
        let top = max(insets.top, 12) + 6 + dots + 16
        let toggles = Self.toggleHeight + Self.toggleSpacing
        let bottom = max(insets.bottom, 16) + 12 + Self.buttonHeight + toggles + 24
        let side = sideInset
        let area = CGRect(x: side, y: top,
                          width: canvas.width - 2 * side,
                          height: canvas.height - top - bottom)
        return QuoteImageRenderer.layout(size, hasCaption: controller.caption != nil, in: area)
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
                .transition(.opacity)
        }
    }

    /// „Für 16:9 Handy drehen“ im Hochformat, „Für 9:16 …“ im Querformat.
    @ViewBuilder
    private var rotateHint: some View {
        if showRotateHint {
            let landscape = canvasSize.width > canvasSize.height
            Label(L(landscape ? "articleReader.quote.rotateTo916" : "articleReader.quote.rotateTo169"),
                  systemImage: landscape ? "iphone" : "iphone.landscape")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .transition(.opacity)
        }
    }

    private var buttons: some View {
        VStack(spacing: Self.toggleSpacing) {
            if showStylePanel {
                stylePanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                QuoteChip(title: L("articleReader.quote.style"), systemImage: "paintbrush",
                          isOn: showStylePanel, height: Self.toggleHeight, textColor: textColor) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showStylePanel.toggle() }
                }
                if hasCaptionToggles {
                    if controller.style.author != nil {
                        QuoteCheckbox(title: L("articleReader.quote.showAuthor"),
                                      isOn: controller.showAuthor, height: Self.toggleHeight,
                                      textColor: textColor) {
                            withAnimation(.easeInOut(duration: 0.25)) { controller.showAuthor.toggle() }
                        }
                    }
                    if controller.style.source != nil {
                        QuoteCheckbox(title: L("articleReader.quote.showSource"),
                                      isOn: controller.showSource, height: Self.toggleHeight,
                                      textColor: textColor) {
                            withAnimation(.easeInOut(duration: 0.25)) { controller.showSource.toggle() }
                        }
                    }
                }
            }
            actionButtons
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, max(controller.insets.bottom, 16) + 12)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: Schrift, Größe, Farbe

    private var sizeBinding: Binding<Double> {
        Binding(get: { controller.effectiveTextSize },
                set: { value in
                    // „Original“ hat keine eigene Größe: auf neu gesetzten Text wechseln.
                    if controller.textFont == .original { controller.textFont = .system }
                    controller.textSize = value.rounded()
                })
    }

    private var stylePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(QuoteFont.allCases, id: \.self) { font in
                        fontButton(font)
                    }
                }
                .padding(.horizontal, 2)
            }
            HStack(spacing: 10) {
                Image(systemName: "textformat.size.smaller")
                Slider(value: sizeBinding, in: 12...48, step: 1)
                    .tint(accent)
                    .accessibilityLabel(L("articleReader.quote.size"))
                    .accessibilityValue("\(Int(controller.effectiveTextSize)) pt")
                Image(systemName: "textformat.size.larger")
            }
            .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(QuoteTextColor.allCases, id: \.self) { color in
                    colorButton(color)
                }
            }
            if backdropsAvailable {
                HStack(spacing: 10) {
                    Image(systemName: "drop")
                    Slider(value: Binding(get: { controller.glassBlur },
                                          set: { controller.glassBlur = $0.rounded() }),
                           in: QuoteModeController.blurRange, step: 1)
                        .tint(accent)
                        .accessibilityLabel(L("articleReader.quote.blur"))
                        .accessibilityValue("\(Int(controller.glassBlur))")
                    Image(systemName: "drop.fill")
                }
                .foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(get: { controller.textGlow },
                                 set: { on in withAnimation(.easeInOut(duration: 0.2)) { controller.textGlow = on } })) {
                Label(L("articleReader.quote.glow"), systemImage: "sun.max")
                    .font(.footnote.weight(.medium))
            }
            .tint(accent)
        }
        .padding(14)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Tipps ins Feld schließen weder Feld noch Ansicht.
        .contentShape(Rectangle())
        .onTapGesture {}
        .padding(.horizontal, sideInset)
    }

    private func fontButton(_ font: QuoteFont) -> some View {
        let selected = controller.textFont == font
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { controller.textFont = font }
        } label: {
            Text(font.title)
                .font(font == .original ? .footnote.weight(.semibold) : Font(font.uiFont(size: 15) as CTFont))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Capsule().fill(selected ? accent.opacity(0.35) : Color.primary.opacity(0.07)))
                .overlay(Capsule().stroke(selected ? accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func colorButton(_ color: QuoteTextColor) -> some View {
        let selected = controller.textColor == color
        return Button {
            if controller.textFont == .original { controller.textFont = .system }
            controller.textColor = color
        } label: {
            Circle()
                .fill(Color(color.uiColor(auto: controller.style.textColor)))
                .frame(width: 26, height: 26)
                .overlay {
                    if color == .auto {
                        Text("A")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(bgColor)
                    }
                }
                .overlay(Circle().stroke(selected ? accent : Color.primary.opacity(0.25),
                                         lineWidth: selected ? 3 : 1)
                    .padding(selected ? -3 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            QuoteActionButton(title: saveState == .saved ? L("articleReader.quote.saved") : L("articleReader.quote.save"),
                              systemImage: saveState == .saved ? "checkmark" : "square.and.arrow.down",
                              height: Self.buttonHeight, accent: accent, onAccent: onAccent) {
                save()
            }
            QuoteActionButton(title: L("articleReader.quote.share"),
                              systemImage: "square.and.arrow.up",
                              height: Self.buttonHeight, accent: accent, onAccent: onAccent) {
                Task { @MainActor in
                    if let image = await exportImage() { QuoteImageActions.share(image) }
                }
            }
        }
    }

    /// Bild zum Speichern und Teilen: ein Abzug des Bildschirms ohne Knöpfe,
    /// also genau das, was man sieht. Das Glas ist ein deckendes Bild, der
    /// WebView darunter muss also nicht mit. Klappt der Abzug nicht, wird
    /// das Bild neu zusammengesetzt.
    private func exportImage() async -> UIImage? {
        guard !exporting else { return nil }
        do {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { exporting = true }
            // Einen Bildaufbau abwarten, damit die Knöpfe sicher weg sind.
            try? await Task.sleep(for: .milliseconds(80))
            let image = controller.screenImage()
            withTransaction(instant) { exporting = false }
            if let image { return image }
        }
        return controller.makeShareImage()
    }

    private func save() {
        guard saveState == .idle else { return }
        saveState = .saving
        Task { @MainActor in
            guard let image = await exportImage() else {
                saveState = .idle
                return
            }
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

/// Knopf „Aa“ für das Schrift-Feld, im selben Stil wie die Kästchen.
private struct QuoteChip: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let height: CGFloat
    let textColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(textColor)
                .padding(.horizontal, 14)
                .frame(height: height)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(textColor.opacity(isOn ? 0.6 : 0), lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// Kleiner Kästchen-Schalter („Autor“, „Quelle“) über den Knöpfen.
private struct QuoteCheckbox: View {
    let title: String
    let isOn: Bool
    let height: CGFloat
    let textColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: isOn ? "checkmark.square.fill" : "square")
                .font(.footnote.weight(.medium))
                .foregroundStyle(textColor)
                .padding(.horizontal, 14)
                .frame(height: height)
                .background(.thinMaterial, in: Capsule())
                .contentShape(Capsule())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
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

/// Glas-Knopf „Zitat-Tafel“ an der Markierungsleiste: öffnet die Ansicht
/// für die aktuelle Auswahl.
struct QuoteOpenButton: View {
    let textColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(L("articleReader.quote.open"), systemImage: "text.quote")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(textColor)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .modifier(QuoteGlassCapsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Liquid Glass ab iOS 26, sonst Material.
/// Runder Glas-Knopf (X oben rechts): Liquid Glass ab iOS 26, sonst Material.
private struct QuoteGlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
    }
}

private struct QuoteGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
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
