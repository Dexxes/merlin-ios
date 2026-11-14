import SwiftUI
import UIKit

/// Freihand-Lesemodus: scrollt eine `UIScrollView` gleichmäßig nach unten.
///
/// Ein `CADisplayLink` schiebt `contentOffset` pro Frame um `speed × Δt`
/// weiter, so ist das Tempo auf 60-Hz- und 120-Hz-Displays gleich. Schritte
/// unter einem Pixel werden in `accumulator` gesammelt, sonst würde die
/// `UIScrollView` sie wegrunden und langsame Stufen blieben stehen.
///
/// Zustände:
/// - `isActive`: der Modus ist an (Reader zeigt die Lesemodus-Leiste).
/// - `isPaused`: angehalten, weiter erst per ▶ (`resume()`). Das passiert durch
///   den Pause-Button, automatisch bei Auswahl/Sheets/Hintergrund (`pause()`)
///   und am Artikelende (`reachedEnd`).
/// - Zieht der Nutzer selbst am Inhalt, hält der Motor nur kurz an und läuft
///   `touchResumeDelay` nach dem Loslassen (und Auslaufen) von der neuen
///   Stelle weiter, ohne dass `isPaused` gesetzt wird.
@MainActor
@Observable
final class AutoScrollController {

    // MARK: Geschwindigkeit

    /// Langsamste und schnellste Stufe in Punkten pro Sekunde.
    nonisolated static let minSpeed: Double = 10
    nonisolated static let maxSpeed: Double = 150
    /// Slider-Stellung für ~35 pt/s (siehe `speed(forSlider:)`).
    nonisolated static let defaultSlider: Double = 0.42
    /// Pause nach dem Loslassen, bevor es von selbst weitergeht.
    nonisolated static let touchResumeDelay: CFTimeInterval = 1.5

    /// Quadratisch statt linear: die langsamen, viel genutzten Stufen liegen
    /// auf einem größeren Teil des Sliders.
    nonisolated static func speed(forSlider value: Double) -> Double {
        let v = min(1, max(0, value))
        return minSpeed + (maxSpeed - minSpeed) * v * v
    }

    // MARK: Zustand

    private(set) var isActive = false
    private(set) var isPaused = false
    private(set) var reachedEnd = false

    /// Slider-Stellung 0…1; wirkt sofort, auch während des Scrollens.
    var slider: Double = PreferencesStore.shared.readerHandsFreeSpeed {
        didSet { PreferencesStore.shared.readerHandsFreeSpeed = slider }
    }

    /// Die Scroll-View, die bewegt wird (äußerer Reader-ScrollView bzw. PDFView).
    @ObservationIgnored weak var scrollView: UIScrollView?

    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    @ObservationIgnored private var accumulator: CGFloat = 0
    @ObservationIgnored private var userWasTouching = false
    @ObservationIgnored private var resumeAt: CFTimeInterval?

    // MARK: Steuerung

    /// Schaltet den Modus ein und startet sofort.
    func start() {
        isActive = true
        isPaused = false
        reachedEnd = false
        updateLink()
    }

    /// Schaltet den Modus aus (zurück zur normalen Bottom bar).
    func stop() {
        isActive = false
        isPaused = false
        reachedEnd = false
        updateLink()
    }

    /// Anhalten bis `resume()`; ohne Wirkung, wenn der Modus aus ist.
    func pause() {
        guard isActive, !isPaused else { return }
        isPaused = true
        updateLink()
    }

    /// Weiter von der aktuellen Stelle. Am Artikelende passiert nichts
    /// sichtbares: der Motor merkt im ersten Frame, dass er am Ende steht.
    func resume() {
        guard isActive else { return }
        isPaused = false
        reachedEnd = false
        updateLink()
    }

    func togglePause() {
        isPaused ? resume() : pause()
    }

    // MARK: DisplayLink

    private var isRunning: Bool { isActive && !isPaused }

    private func updateLink() {
        if isRunning {
            if displayLink == nil {
                let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
        lastTimestamp = nil
        accumulator = 0
        resumeAt = nil
        userWasTouching = false
        // Bildschirm bleibt an, solange der Motor läuft.
        UIApplication.shared.isIdleTimerDisabled = isRunning
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard let sv = scrollView, sv.window != nil else { return }

        // Nutzer zieht selbst (oder der Schwung läuft noch aus): kurz anhalten,
        // danach von der neuen Stelle aus weiter.
        if sv.isTracking || sv.isDragging || sv.isDecelerating || sv.isZooming {
            userWasTouching = true
            resumeAt = nil
            accumulator = 0
            return
        }
        if userWasTouching {
            userWasTouching = false
            resumeAt = now + Self.touchResumeDelay
        }
        if let r = resumeAt {
            guard now >= r else { return }
            resumeAt = nil
            accumulator = 0
            return
        }

        guard let last = lastTimestamp else { return }
        // Nach einem Hänger nicht mit einem großen Satz nachholen.
        let dt = min(max(0, now - last), 0.1)
        accumulator += CGFloat(Self.speed(forSlider: slider) * dt)

        // Maximum in jedem Frame neu lesen: Bilder/Kommentare lassen den Inhalt wachsen.
        let maxY = max(-sv.adjustedContentInset.top,
                       sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
        let current = sv.contentOffset.y
        if current >= maxY - 0.5 {
            reachedEnd = true
            isPaused = true
            updateLink()
            return
        }

        let scale = max(1, sv.traitCollection.displayScale)
        let step = floor(accumulator * scale) / scale
        guard step > 0 else { return }
        accumulator -= step
        let target = min(current + step, maxY)
        sv.contentOffset = CGPoint(x: sv.contentOffset.x, y: target)
    }

    /// Hält den Controller nur schwach: `CADisplayLink` hält sein Target stark.
    /// `@MainActor`, weil der Link auf dem Main-RunLoop hängt (`add(to: .main)`)
    /// und `tick` damit immer auf dem Main Thread aufgerufen wird.
    @MainActor
    private final class DisplayLinkProxy: NSObject {
        weak var owner: AutoScrollController?
        init(_ owner: AutoScrollController) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.tick(link)
        }
    }
}

// MARK: – Scroll-View finden

/// Unsichtbarer Helfer im Inhalt eines SwiftUI-`ScrollView`: läuft die
/// UIKit-Hierarchie hoch (wie `ScrollPositionRestorer`) und meldet die
/// `UIScrollView`, die den ScrollView trägt.
struct EnclosingScrollViewReader: UIViewRepresentable {
    let onFound: @MainActor (UIScrollView) -> Void

    final class Coordinator {
        weak var found: UIScrollView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Läuft bei jedem Neuzeichnen des Readers (beim Scrollen jeden Frame):
        // nur suchen, solange noch keine Scroll-View gemeldet wurde.
        let coordinator = context.coordinator
        guard coordinator.found == nil else { return }
        // Erst nach dem Einhängen in die Hierarchie gibt es eine Superview.
        DispatchQueue.main.async {
            guard coordinator.found == nil, let sv = uiView.enclosingScrollView else { return }
            coordinator.found = sv
            onFound(sv)
        }
    }
}

extension UIView {
    /// Nächste `UIScrollView` oberhalb dieser View.
    var enclosingScrollView: UIScrollView? {
        var view = superview
        while let v = view {
            if let scroll = v as? UIScrollView { return scroll }
            view = v.superview
        }
        return nil
    }
}
