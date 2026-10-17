import PDFKit
import SwiftUI
import UIKit

/// Shows the PDF of a PDF article (`Article.isPDF`) inside the reader.
///
/// The server stores only the source URL (or the file in „Merlin Dateien“). `PDFCacheService`
/// downloads the file when the article is opened (or serves the cached copy offline); the whole
/// document is then shown in one `PDFView` (continuous, vertical) that scrolls and pinch-zooms on
/// its own. It replaces the reader's outer `ScrollView` for PDFs, so the reading position is the
/// **page**: reported as `page / (pageCount - 1)` through `onPageChange` and restored from
/// `initialProgress` by jumping to that page. Zoom level and position within a page are not stored.
///
/// Text can be selected natively; a small bar above the selection highlights it in the five colours
/// or starts a comment. A PDF highlight is stored as page + rectangles (`Highlight.pdfPage`/`pdfRects`,
/// normalised to the unrotated CropBox, origin top left – same as the web reader) and drawn as an
/// in-memory `PDFAnnotation`; the cached file itself is never changed.
struct PDFArticleView: View {
    let sourceURL: URL
    /// Markieren und Kommentieren. Ohne Artikel-ID nur Anzeige.
    var articleId: Int? = nil
    var comments: CommentStore? = nil
    var onOpenComments: ((Int, String) -> Void)? = nil
    var onCommentAnchor: ((CommentAnchor) -> Void)? = nil
    /// Gespeicherte Leseposition (0..1); daraus wird die Seite beim Öffnen.
    var initialProgress: CGFloat = 0
    /// Neue Seite als Leseposition `Seite / (Seitenzahl - 1)`.
    var onPageChange: ((CGFloat) -> Void)? = nil
    /// Die gespeicherte Seite ist angesprungen (Quick-Close-Guard im Reader).
    var onRestored: (() -> Void)? = nil
    /// Scrollen im PDF: Abstand vom Anfang und ob nach unten (Leisten ein-/ausblenden).
    var onScroll: ((CGFloat, Bool) -> Void)? = nil

    private enum Phase {
        case loading
        case failed
        case encrypted
        case ready(PDFDocument)
    }

    @State private var phase: Phase = .loading
    /// Bumped by "Try again" to re-run `.task(id:)`.
    @State private var attempt = 0
    /// Eigene PDF-Markierungen aus API bzw. Offline-Cache, dazu gerade angelegte
    /// (offline noch mit negativer ID). Der Kommentar-Kanal liefert zusätzlich
    /// die von Gästen und anderen Geräten.
    @State private var local: [Highlight] = []
    /// Gerade gelöscht – ausblenden, bis der Kommentar-Kanal nachzieht.
    @State private var removedIds: Set<Int> = []
    /// Angetippte Markierung (Menü „Kommentare / Entfernen“).
    @State private var tapped: Highlight?
    /// Rückfrage vor dem Entfernen einer Markierung mit Kommentaren.
    @State private var confirmDelete: Highlight?

    /// Alle sichtbaren PDF-Markierungen: Kommentar-Kanal und lokale vereint (lokal gewinnt nicht –
    /// der Kanal trägt auch `authorColor`).
    private var highlights: [Highlight] {
        var byId: [Int: Highlight] = [:]
        var order: [Int] = []
        for h in local + (comments?.highlights ?? []) where h.isPDF && !removedIds.contains(h.id) {
            if byId[h.id] == nil { order.append(h.id) }
            byId[h.id] = h
        }
        return order.compactMap { byId[$0] }
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 16) {
                    ProgressView()
                    Text(L("articleReader.pdf.loading"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed:
                messageView(text: L("articleReader.pdf.failed"), showRetry: true)

            case .encrypted:
                messageView(text: L("articleReader.pdf.encrypted"), showRetry: false)

            case .ready(let document):
                let all = highlights
                PDFDocumentRepresentable(
                    document: document,
                    highlights: all,
                    initialProgress: initialProgress,
                    canMark: articleId != nil,
                    canComment: comments?.isAvailable == true && onCommentAnchor != nil,
                    onMark: { color, text, page, rects in create(color: color, text: text, page: page, rects: rects) },
                    onComment: { text, page, rects in
                        onCommentAnchor?(CommentAnchor(
                            highlightedText: text, startXpath: "", startOffset: 0,
                            endXpath: "", endOffset: 0, pdfPage: page, pdfRects: rects))
                    },
                    onTapHighlight: { id in tapped = all.first { $0.id == id } },
                    onPageChange: onPageChange,
                    onRestored: onRestored,
                    onScroll: onScroll)
            }
        }
        .task(id: "\(sourceURL.absoluteString)#\(attempt)") {
            await load()
        }
        .task(id: articleId) {
            await loadHighlights()
        }
        .confirmationDialog(
            tapped.map { "„\($0.highlightedText.prefix(80))“" } ?? "",
            isPresented: .init(get: { tapped != nil }, set: { if !$0 { tapped = nil } }),
            titleVisibility: .visible,
            presenting: tapped
        ) { highlight in
            if comments?.isAvailable == true, highlight.id > 0, onOpenComments != nil {
                let count = comments?.count(forHighlight: highlight.id) ?? 0
                Button(count > 0
                       ? String(format: L("articleReader.comments.countLabel"), count)
                       : L("articleReader.comments.comment")) {
                    onOpenComments?(highlight.id, highlight.highlightedText)
                }
            }
            if articleId != nil {
                Button(L("articleReader.comments.removeHighlight"), role: .destructive) {
                    if (comments?.count(forHighlight: highlight.id) ?? 0) > 0 {
                        confirmDelete = highlight
                    } else {
                        delete(highlight)
                    }
                }
            }
            Button(L("common.cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L("articleReader.comments.deleteHighlightTitle"),
            isPresented: .init(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible,
            presenting: confirmDelete
        ) { highlight in
            Button(L("articleReader.comments.removeHighlight"), role: .destructive) { delete(highlight) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(L("articleReader.comments.deleteHighlightMessage"))
        }
    }

    private func messageView(text: String, showRetry: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if showRetry {
                Button(L("articleReader.pdf.retry")) {
                    phase = .loading
                    attempt += 1
                }
                .buttonStyle(.bordered)
            }
            Link(L("articleReader.pdf.openBrowser"), destination: sourceURL)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func load() async {
        do {
            let file = try await PDFCacheService.shared.fetch(sourceURL)
            guard let document = PDFDocument(url: file) else {
                // Unreadable file: drop it so "Try again" downloads a fresh copy.
                await PDFCacheService.shared.remove(sourceURL)
                phase = .failed
                return
            }
            phase = document.isLocked ? .encrypted : .ready(document)
        } catch is CancellationError {
            // View went away (e.g. next article) – nothing to show.
        } catch {
            phase = .failed
        }
    }

    // MARK: – Highlights

    /// Eigene Markierungen vom Server, offline aus dem Cache (wie `ArticleWebView`).
    @MainActor
    private func loadHighlights() async {
        guard let articleId else { return }
        if let fetched = try? await MerlinAPI.shared.getHighlights(articleId) {
            await HighlightCacheService.shared.replaceAll(fetched, for: articleId)
            local = fetched.filter(\.isPDF)
        } else {
            local = await HighlightCacheService.shared.highlights(for: articleId).filter(\.isPDF)
        }
    }

    /// Markierung anlegen: sofort zeigen (vorläufig mit negativer ID), dann speichern. Offline geht
    /// sie in die `OfflineHighlightQueue` und bleibt bis zum nächsten Öffnen vorläufig stehen.
    private func create(color: String, text: String, page: Int, rects: [[Double]]) {
        guard let articleId else { return }
        let tempNumber = Int(Date().timeIntervalSince1970 * 1000)
        let temp = Highlight(
            id: -tempNumber, articleId: articleId, highlightedText: text,
            startXpath: "", startOffset: 0, endXpath: "", endOffset: 0,
            color: color, createdAt: ISO8601DateFormatter().string(from: Date()),
            pdfPage: page, pdfRects: rects)
        local.append(temp)
        let payload = HighlightCreate(
            highlightedText: text, startXpath: "", startOffset: 0,
            endXpath: "", endOffset: 0, color: color, pdfPage: page, pdfRects: rects)
        Task { @MainActor in
            do {
                let saved = try await MerlinAPI.shared.createHighlight(articleId, payload: payload)
                await HighlightCacheService.shared.upsert(saved)
                local.removeAll { $0.id == temp.id }
                local.append(saved)
                await comments?.refresh()
            } catch {
                if case MerlinAPIError.networkError = error {
                    OfflineHighlightQueue.shared.enqueueCreate(
                        articleId: articleId, tempId: "tmp_\(tempNumber)", payload: payload)
                } else {
                    // Server lehnt ab (z. B. älterer Server ohne PDF-Markierungen): wieder weg.
                    local.removeAll { $0.id == temp.id }
                }
            }
        }
    }

    private func delete(_ highlight: Highlight) {
        guard let articleId else { return }
        local.removeAll { $0.id == highlight.id }
        removedIds.insert(highlight.id)
        guard highlight.id > 0 else {
            // Nie beim Server angekommen: nur die wartende Anlage streichen.
            OfflineHighlightQueue.shared.cancelPendingCreate(tempId: "tmp_\(-highlight.id)", articleId: articleId)
            return
        }
        Task { @MainActor in
            do {
                try await MerlinAPI.shared.deleteHighlight(highlight.id)
                await HighlightCacheService.shared.remove(id: highlight.id, articleId: articleId)
                await comments?.refresh()
            } catch {
                if case MerlinAPIError.networkError = error {
                    await HighlightCacheService.shared.remove(id: highlight.id, articleId: articleId)
                    OfflineHighlightQueue.shared.enqueueDelete(articleId: articleId, highlightId: highlight.id)
                } else {
                    removedIds.remove(highlight.id)
                }
            }
        }
    }
}

extension Notification.Name {
    /// „Im Text zeigen“ für eine PDF-Markierung (`userInfo["id"]`), siehe `HighlightActionHandler.reveal`.
    static let merlinRevealPDFHighlight = Notification.Name("merlinRevealPDFHighlight")
}

// MARK: – Document view

/// `PDFView`, das jedes Layout meldet (Breite → Zoomgrenzen neu setzen, erste Wiederherstellung).
private final class ReaderPDFView: PDFView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// The whole document in one scrolling, pinch-zoomable `PDFView`: native text selection,
/// highlights as in-memory annotations, a colour bar above the selection.
private struct PDFDocumentRepresentable: UIViewRepresentable {
    let document: PDFDocument
    let highlights: [Highlight]
    let initialProgress: CGFloat
    let canMark: Bool
    let canComment: Bool
    /// Farbe, Text, Seite (ab 1), Rechtecke.
    let onMark: (String, String, Int, [[Double]]) -> Void
    /// Text, Seite (ab 1), Rechtecke.
    let onComment: (String, Int, [[Double]]) -> Void
    let onTapHighlight: (Int) -> Void
    let onPageChange: ((CGFloat) -> Void)?
    let onRestored: (() -> Void)?
    let onScroll: ((CGFloat, Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ReaderPDFView {
        let pdfView = ReaderPDFView()
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        pdfView.displayBox = .cropBox
        pdfView.backgroundColor = .clear
        pdfView.autoScales = true
        pdfView.document = document
        context.coordinator.attach(pdfView: pdfView, document: document, initialProgress: initialProgress)
        return pdfView
    }

    func updateUIView(_ pdfView: ReaderPDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.canMark = canMark
        coordinator.canComment = canComment
        coordinator.onMark = onMark
        coordinator.onComment = onComment
        coordinator.onTapHighlight = onTapHighlight
        coordinator.onPageChange = onPageChange
        coordinator.onRestored = onRestored
        coordinator.onScroll = onScroll
        coordinator.apply(highlights)
    }

    static func dismantleUIView(_ pdfView: ReaderPDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var canMark = false
        var canComment = false
        var onMark: ((String, String, Int, [[Double]]) -> Void)?
        var onComment: ((String, Int, [[Double]]) -> Void)?
        var onTapHighlight: ((Int) -> Void)?
        var onPageChange: ((CGFloat) -> Void)?
        var onRestored: (() -> Void)?
        var onScroll: ((CGFloat, Bool) -> Void)?

        private weak var pdfView: ReaderPDFView?
        private var document: PDFDocument?
        private var initialProgress: CGFloat = 0
        private var restored = false
        /// Breite, für die die Zoomgrenzen zuletzt gesetzt wurden.
        private var fittedWidth: CGFloat = 0
        private var lastPageIndex: Int?
        private var lastOffset: CGFloat = 0
        private var bar: UIView?
        /// Gezeichnete Annotationen je Markierungs-ID, mit ihrer Seite (Treffer-Test und Aufräumen).
        private var annotations: [Int: [(PDFPage, PDFAnnotation)]] = [:]
        private var drawnSignature = ""
        private var observers: [NSObjectProtocol] = []
        private var offsetObservation: NSKeyValueObservation?

        /// Kennzeichen eigener Annotationen. Die Seiten gehören dem `PDFDocument`; ein neu
        /// erzeugter View räumt darüber auch die eines verworfenen Vorgängers weg.
        private static let marker = "merlin-highlight"
        /// Weiter als auf das Fünffache der Seitenbreite wird nicht gezoomt.
        private static let maxZoom: CGFloat = 5

        func attach(pdfView: ReaderPDFView, document: PDFDocument, initialProgress: CGFloat) {
            self.pdfView = pdfView
            self.document = document
            self.initialProgress = initialProgress
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                for annotation in page.annotations where annotation.userName == Self.marker {
                    page.removeAnnotation(annotation)
                }
            }
            pdfView.onLayout = { [weak self] in self?.layoutChanged() }
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            tap.cancelsTouchesInView = false
            pdfView.addGestureRecognizer(tap)
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.selectionChanged() }
                },
                center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pageChanged() }
                },
                center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.positionBar() }
                },
                center.addObserver(forName: .merlinRevealPDFHighlight, object: nil, queue: .main) { [weak self] note in
                    let id = note.userInfo?["id"] as? Int
                    MainActor.assumeIsolated { if let id { self?.reveal(id) } }
                },
            ]
        }

        func detach() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            offsetObservation?.invalidate()
            offsetObservation = nil
            pdfView?.onLayout = nil
            removeAnnotations()
        }

        // MARK: Layout, zoom, restore

        private func layoutChanged() {
            guard let pdfView, let document, document.pageCount > 0 else { return }
            observeScrollingIfNeeded()
            let width = pdfView.bounds.width
            if width > 0, abs(width - fittedWidth) > 0.5 {
                // Seitenbreite ist die kleinste Stufe. War die Seite eingepasst (oder ist es das erste
                // Layout), bleibt sie es nach dem Drehen; ein eigener Zoom bleibt erhalten.
                let wasFitted = fittedWidth == 0 || pdfView.scaleFactor <= pdfView.minScaleFactor + 0.001
                pdfView.autoScales = false
                let fit = pdfView.scaleFactorForSizeToFit
                if fit > 0 {
                    fittedWidth = width
                    pdfView.minScaleFactor = fit
                    pdfView.maxScaleFactor = fit * Self.maxZoom
                    if wasFitted || pdfView.scaleFactor < fit { pdfView.scaleFactor = fit }
                }
            }
            guard !restored, fittedWidth > 0 else { return }
            restored = true
            let count = document.pageCount
            let index = count > 1 ? Int((min(max(initialProgress, 0), 1) * CGFloat(count - 1)).rounded()) : 0
            // Nicht mitten im Layout springen.
            Task { @MainActor [weak self] in
                guard let self, let pdfView = self.pdfView, let document = self.document else { return }
                if index > 0, let page = document.page(at: index) {
                    pdfView.go(to: page)
                }
                self.lastPageIndex = index
                self.onRestored?()
            }
        }

        /// PDFKit legt seinen inneren ScrollView selbst an; dessen Versatz meldet die Scrollrichtung
        /// (Leisten ein-/ausblenden) und hält die Farbleiste an der Auswahl.
        private func observeScrollingIfNeeded() {
            guard offsetObservation == nil, let pdfView, let scroll = Self.scrollView(in: pdfView) else { return }
            offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                MainActor.assumeIsolated {
                    self?.scrolled(to: scroll.contentOffset.y + scroll.adjustedContentInset.top)
                }
            }
        }

        private static func scrollView(in view: UIView) -> UIScrollView? {
            for sub in view.subviews {
                if let scroll = sub as? UIScrollView { return scroll }
                if let scroll = scrollView(in: sub) { return scroll }
            }
            return nil
        }

        private func scrolled(to offset: CGFloat) {
            let delta = offset - lastOffset
            if abs(delta) > 4 {
                onScroll?(max(0, offset), delta > 0)
                lastOffset = offset
            } else if offset <= 0, lastOffset > 0 {
                onScroll?(0, false)
                lastOffset = offset
            }
            positionBar()
        }

        /// Leseposition ist die Seite: erst nach der Wiederherstellung melden, damit der Sprung
        /// selbst sie nicht mit Seite 1 überschreibt.
        private func pageChanged() {
            guard restored, let pdfView, let document, let page = pdfView.currentPage else { return }
            let index = document.index(for: page)
            guard index != lastPageIndex else { return }
            lastPageIndex = index
            let count = document.pageCount
            onPageChange?(count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0)
        }

        // MARK: Drawing

        func apply(_ highlights: [Highlight]) {
            guard let document else { return }
            let signature = highlights
                .map { "\($0.id):\($0.color):\($0.authorColor ?? ""):\($0.pdfPage ?? 0)" }
                .joined(separator: ",")
            guard signature != drawnSignature else { return }
            drawnSignature = signature
            removeAnnotations()
            for highlight in highlights {
                guard let rects = highlight.pdfRects, let number = highlight.pdfPage,
                      let page = document.page(at: number - 1) else { continue }
                let isComment = highlight.color == "comment"
                let color: UIColor
                if isComment {
                    color = UIColor(Color(hexString: highlight.authorColor ?? "") ?? Color(hexString: "#c2410c")!)
                } else {
                    color = UIColor(Color(hexString: PDFHighlightGeometry.hex(for: highlight.color)) ?? .yellow)
                }
                annotations[highlight.id] = rects.compactMap { rect in
                    guard let bounds = PDFHighlightGeometry.pageRect(rect, on: page) else { return nil }
                    let annotation = PDFAnnotation(bounds: bounds, forType: isComment ? .underline : .highlight, withProperties: nil)
                    annotation.color = isComment ? color : color.withAlphaComponent(0.8)
                    annotation.userName = Self.marker
                    page.addAnnotation(annotation)
                    return (page, annotation)
                }
            }
        }

        private func removeAnnotations() {
            for list in annotations.values {
                for (page, annotation) in list { page.removeAnnotation(annotation) }
            }
            annotations = [:]
        }

        // MARK: Tap on a highlight

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let pdfView else { return }
            let location = gesture.location(in: pdfView)
            // Die Farbleiste behandelt ihre Knöpfe selbst.
            if let bar, bar.frame.contains(location) { return }
            if let current = selectionPage() {
                // Tippen neben die Auswahl hebt sie auf (PDFKit tut das nicht von selbst);
                // in die Auswahl bleibt sie für das System-Menü stehen.
                let bounds = pdfView.convert(current.0.bounds(for: current.1), from: current.1)
                if !bounds.insetBy(dx: -8, dy: -8).contains(location) {
                    pdfView.clearSelection()
                    selectionChanged()
                }
                return
            }
            guard let page = pdfView.page(for: location, nearest: false) else { return }
            let point = pdfView.convert(location, to: page)
            for (id, list) in annotations
            where list.contains(where: { $0.0 == page && $0.1.bounds.insetBy(dx: -2, dy: -2).contains(point) }) {
                onTapHighlight?(id)
                return
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: Selection bar

        /// Die Seite, auf der die Auswahl beginnt; markiert wird nur dort (wie im Web).
        private func selectionPage() -> (PDFSelection, PDFPage, String)? {
            guard let pdfView, let selection = pdfView.currentSelection,
                  let page = selection.pages.first,
                  let text = PDFHighlightGeometry.text(of: selection, on: page), !text.isEmpty
            else { return nil }
            return (selection, page, text)
        }

        private func selectionChanged() {
            bar?.removeFromSuperview()
            bar = nil
            guard canMark, let pdfView, selectionPage() != nil else { return }
            let bar = makeBar()
            pdfView.addSubview(bar)
            self.bar = bar
            positionBar()
        }

        /// Über der Auswahl, sonst darunter (Platz für das System-Menü „Kopieren“ bleibt); folgt
        /// Scrollen und Zoomen.
        private func positionBar() {
            guard let bar, let pdfView, let current = selectionPage() else { return }
            let bounds = pdfView.convert(current.0.bounds(for: current.1), from: current.1)
            let size = bar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let area = pdfView.bounds.inset(by: pdfView.safeAreaInsets)
            let x = min(max(area.minX + 8, bounds.midX - size.width / 2), max(area.minX + 8, area.maxX - size.width - 8))
            var y = bounds.minY - size.height - 10
            if y < area.minY + 4 { y = bounds.maxY + 10 }
            y = min(max(area.minY + 4, y), area.maxY - size.height - 4)
            bar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        }

        private func makeBar() -> UIView {
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 10
            stack.alignment = .center
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
            for (id, name) in PDFHighlightGeometry.colorNames() {
                let button = UIButton(type: .custom)
                button.backgroundColor = UIColor(Color(hexString: PDFHighlightGeometry.hex(for: id)) ?? .yellow)
                button.layer.cornerRadius = 14
                button.layer.borderWidth = 1
                button.layer.borderColor = UIColor.black.withAlphaComponent(0.15).cgColor
                button.accessibilityLabel = name
                button.widthAnchor.constraint(equalToConstant: 28).isActive = true
                button.heightAnchor.constraint(equalToConstant: 28).isActive = true
                button.addAction(UIAction { [weak self] _ in self?.mark(color: id) }, for: .touchUpInside)
                stack.addArrangedSubview(button)
            }
            if canComment {
                let button = UIButton(type: .system)
                button.setImage(UIImage(systemName: "text.bubble"), for: .normal)
                button.tintColor = .label
                button.accessibilityLabel = L("articleReader.comments.comment")
                button.addAction(UIAction { [weak self] _ in self?.comment() }, for: .touchUpInside)
                stack.addArrangedSubview(button)
            }
            let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
            background.layer.cornerRadius = 20
            background.clipsToBounds = true
            background.contentView.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: background.contentView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: background.contentView.trailingAnchor),
                stack.topAnchor.constraint(equalTo: background.contentView.topAnchor),
                stack.bottomAnchor.constraint(equalTo: background.contentView.bottomAnchor),
            ])
            return background
        }

        /// Text, Seite und Rechtecke der aktuellen Auswahl; danach Auswahl und Leiste weg.
        private func takeSelection() -> (String, Int, [[Double]])? {
            guard let pdfView, let document, let current = selectionPage() else { return nil }
            let (selection, page, text) = current
            let rects = PDFHighlightGeometry.normalizedRects(of: selection, on: page)
            pdfView.clearSelection()
            bar?.removeFromSuperview()
            bar = nil
            return rects.isEmpty ? nil : (text, document.index(for: page) + 1, rects)
        }

        private func mark(color: String) {
            guard let taken = takeSelection() else { return }
            onMark?(color, taken.0, taken.1, taken.2)
        }

        private func comment() {
            guard let taken = takeSelection() else { return }
            onComment?(taken.0, taken.1, taken.2)
        }

        // MARK: Reveal

        /// Springt zur Markierung, auf jeder Seite (die Seitenmeldung setzt dabei die Leseposition).
        private func reveal(_ id: Int) {
            guard let pdfView, let first = annotations[id]?.first else { return }
            let (page, annotation) = first
            pdfView.go(to: annotation.bounds.insetBy(dx: 0, dy: -80), on: page)
        }
    }
}

// MARK: – Geometry

/// Umrechnung zwischen PDFKit-Seitenkoordinaten und den gespeicherten Rechtecken
/// `[x, y, w, h]` (0..1, unrotierte CropBox, Ursprung oben links – wie `pdf-highlights.js`).
enum PDFHighlightGeometry {
    /// Wie die COLORS-Tabelle in merlinHighlightJS und im Web.
    static func hex(for color: String) -> String {
        switch color {
        case "green": return "#bbf7d0"
        case "blue": return "#bfdbfe"
        case "pink": return "#fbcfe8"
        case "orange": return "#fed7aa"
        default: return "#fde68a"
        }
    }

    static func colorNames() -> [(String, String)] {
        [
            ("yellow", L("articleReader.pdf.highlight.yellow")),
            ("green", L("articleReader.pdf.highlight.green")),
            ("blue", L("articleReader.pdf.highlight.blue")),
            ("pink", L("articleReader.pdf.highlight.pink")),
            ("orange", L("articleReader.pdf.highlight.orange")),
        ]
    }

    static func pageRect(_ rect: [Double], on page: PDFPage) -> CGRect? {
        guard rect.count == 4 else { return nil }
        let crop = page.bounds(for: .cropBox)
        let (x, y, w, h) = (CGFloat(rect[0]), CGFloat(rect[1]), CGFloat(rect[2]), CGFloat(rect[3]))
        guard w > 0, h > 0 else { return nil }
        return CGRect(x: crop.minX + x * crop.width,
                      y: crop.maxY - (y + h) * crop.height,
                      width: w * crop.width,
                      height: h * crop.height)
    }

    /// Eine Zeile der Auswahl je Rechteck (höchstens 200, wie der Server erlaubt).
    static func normalizedRects(of selection: PDFSelection, on page: PDFPage) -> [[Double]] {
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 0, crop.height > 0 else { return [] }
        func clamp(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
        func round5(_ v: CGFloat) -> Double { (Double(v) * 100_000).rounded() / 100_000 }
        let rects: [[Double]] = selection.selectionsByLine().compactMap { line in
            guard line.pages.contains(page) else { return nil }
            let b = line.bounds(for: page)
            let x1 = clamp((b.minX - crop.minX) / crop.width), x2 = clamp((b.maxX - crop.minX) / crop.width)
            let y1 = clamp((crop.maxY - b.maxY) / crop.height), y2 = clamp((crop.maxY - b.minY) / crop.height)
            guard x2 > x1, y2 > y1 else { return nil }
            return [round5(x1), round5(y1), round5(x2 - x1), round5(y2 - y1)]
        }
        return Array(rects.prefix(200))
    }

    /// Text der Auswahl auf dieser Seite, Zeilen mit Leerzeichen verbunden.
    static func text(of selection: PDFSelection, on page: PDFPage) -> String? {
        let lines = selection.selectionsByLine().filter { $0.pages.contains(page) }.compactMap(\.string)
        let text = lines.joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}
