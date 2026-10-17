import PDFKit
import SwiftUI
import UIKit

/// Shows the PDF of a PDF article (`Article.isPDF`) inside the reader.
///
/// The server stores only the source URL (or the file in „Merlin Dateien“). `PDFCacheService`
/// downloads the file when the article is opened (or serves the cached copy offline); each page is
/// then shown by its own non-scrolling `PDFView` in a `LazyVStack`. The pages deliberately live in
/// the reader's *outer* `ScrollView` instead of one `PDFView` with its own scrolling: that way reading
/// progress, position restore, the progress bar and the bottom-bar auto-hide keep working unchanged.
/// Trade-off: no pinch zoom.
///
/// Text can be selected natively; a small bar above the selection highlights it in the five colours
/// or starts a comment. A PDF highlight is stored as page + rectangles (`Highlight.pdfPage`/`pdfRects`,
/// normalised to the unrotated CropBox, origin top left – same as the web reader) and drawn as an
/// in-memory `PDFAnnotation`; the cached file itself is never changed.
struct PDFArticleView: View {
    let sourceURL: URL
    /// Width of the reader viewport; pages fill it minus a small margin.
    let availableWidth: CGFloat
    /// Markieren und Kommentieren. Ohne Artikel-ID nur Anzeige.
    var articleId: Int? = nil
    var comments: CommentStore? = nil
    var onOpenComments: ((Int, String) -> Void)? = nil
    var onCommentAnchor: ((CommentAnchor) -> Void)? = nil

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

    private var pageWidth: CGFloat { max(200, availableWidth - 32) }

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
                .frame(maxWidth: .infinity, minHeight: 300)

            case .failed:
                messageView(text: L("articleReader.pdf.failed"), showRetry: true)

            case .encrypted:
                messageView(text: L("articleReader.pdf.encrypted"), showRetry: false)

            case .ready(let document):
                let all = highlights
                LazyVStack(spacing: 12) {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        if let page = document.page(at: index) {
                            PDFPageView(
                                document: document,
                                page: page,
                                width: pageWidth,
                                highlights: all.filter { $0.pdfPage == index + 1 },
                                canMark: articleId != nil,
                                canComment: comments?.isAvailable == true && onCommentAnchor != nil,
                                onMark: { color, text, rects in create(color: color, text: text, page: index + 1, rects: rects) },
                                onComment: { text, rects in
                                    onCommentAnchor?(CommentAnchor(
                                        highlightedText: text, startXpath: "", startOffset: 0,
                                        endXpath: "", endOffset: 0, pdfPage: index + 1, pdfRects: rects))
                                },
                                onTapHighlight: { id in tapped = all.first { $0.id == id } })
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
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
        .frame(maxWidth: .infinity, minHeight: 300)
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

// MARK: – Single page

/// One PDF page in its own non-scrolling `PDFView`: native text selection, highlights as
/// in-memory annotations, a colour bar above the selection. Pages off screen are dropped by the
/// `LazyVStack`, together with their `PDFView`.
private struct PDFPageView: View {
    let document: PDFDocument
    let page: PDFPage
    let width: CGFloat
    let highlights: [Highlight]
    let canMark: Bool
    let canComment: Bool
    let onMark: (String, String, [[Double]]) -> Void
    let onComment: (String, [[Double]]) -> Void
    let onTapHighlight: (Int) -> Void

    private var aspect: CGFloat {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let w = rotated ? box.height : box.width
        let h = rotated ? box.width : box.height
        return h / max(w, 1)
    }

    var body: some View {
        PDFPageRepresentable(
            document: document, page: page, highlights: highlights,
            canMark: canMark, canComment: canComment,
            onMark: onMark, onComment: onComment, onTapHighlight: onTapHighlight)
            .frame(width: width, height: width * aspect)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}

extension Notification.Name {
    /// „Im Text zeigen“ für eine PDF-Markierung (`userInfo["id"]`), siehe `HighlightActionHandler.reveal`.
    static let merlinRevealPDFHighlight = Notification.Name("merlinRevealPDFHighlight")
}

private struct PDFPageRepresentable: UIViewRepresentable {
    let document: PDFDocument
    let page: PDFPage
    let highlights: [Highlight]
    let canMark: Bool
    let canComment: Bool
    let onMark: (String, String, [[Double]]) -> Void
    let onComment: (String, [[Double]]) -> Void
    let onTapHighlight: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .white
        let pdfView = PDFView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.displayMode = .singlePage
        pdfView.displaysPageBreaks = false
        pdfView.pageShadowsEnabled = false
        pdfView.displayBox = .cropBox
        pdfView.backgroundColor = .white
        pdfView.autoScales = true
        pdfView.document = document
        pdfView.go(to: page)
        container.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.attach(pdfView: pdfView, container: container, page: page)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.canMark = canMark
        coordinator.canComment = canComment
        coordinator.onMark = onMark
        coordinator.onComment = onComment
        coordinator.onTapHighlight = onTapHighlight
        coordinator.apply(highlights)
    }

    static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var canMark = false
        var canComment = false
        var onMark: ((String, String, [[Double]]) -> Void)?
        var onComment: ((String, [[Double]]) -> Void)?
        var onTapHighlight: ((Int) -> Void)?

        private weak var pdfView: PDFView?
        private weak var container: UIView?
        private var page: PDFPage?
        private var bar: UIView?
        /// Gezeichnete Annotationen je Markierungs-ID (zum Treffer-Test und Aufräumen).
        private var annotations: [Int: [PDFAnnotation]] = [:]
        private var drawnSignature = ""
        private var selectionObserver: NSObjectProtocol?
        private var revealObserver: NSObjectProtocol?

        /// Kennzeichen eigener Annotationen. Die Seite gehört dem gemeinsamen `PDFDocument`; ein neu
        /// erzeugter Seiten-View räumt darüber auch die eines verworfenen Vorgängers weg.
        private static let marker = "merlin-highlight"

        func attach(pdfView: PDFView, container: UIView, page: PDFPage) {
            self.pdfView = pdfView
            self.container = container
            self.page = page
            lockScrolling()
            for annotation in page.annotations where annotation.userName == Self.marker {
                page.removeAnnotation(annotation)
            }
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            tap.cancelsTouchesInView = false
            pdfView.addGestureRecognizer(tap)
            selectionObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged, object: pdfView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.selectionChanged() }
            }
            revealObserver = NotificationCenter.default.addObserver(
                forName: .merlinRevealPDFHighlight, object: nil, queue: .main
            ) { [weak self] note in
                let id = note.userInfo?["id"] as? Int
                MainActor.assumeIsolated { if let id { self?.reveal(id) } }
            }
        }

        /// Der äußere Reader-ScrollView scrollt; der PDFView selbst weder scrollen noch zoomen.
        /// Auch aus `apply` aufgerufen, falls PDFKit seinen ScrollView erst beim Layout anlegt.
        private func lockScrolling() {
            guard let scroll = pdfView?.subviews.compactMap({ $0 as? UIScrollView }).first,
                  scroll.isScrollEnabled else { return }
            scroll.isScrollEnabled = false
            scroll.bounces = false
            scroll.pinchGestureRecognizer?.isEnabled = false
        }

        func detach() {
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
            if let revealObserver { NotificationCenter.default.removeObserver(revealObserver) }
            if let page {
                for list in annotations.values { list.forEach { page.removeAnnotation($0) } }
            }
            annotations = [:]
        }

        // MARK: Drawing

        func apply(_ highlights: [Highlight]) {
            lockScrolling()
            guard let page else { return }
            let signature = highlights.map { "\($0.id):\($0.color):\($0.authorColor ?? "")" }.joined(separator: ",")
            guard signature != drawnSignature else { return }
            drawnSignature = signature
            for list in annotations.values { list.forEach { page.removeAnnotation($0) } }
            annotations = [:]
            for highlight in highlights {
                guard let rects = highlight.pdfRects else { continue }
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
                    return annotation
                }
            }
        }

        // MARK: Tap on a highlight

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let pdfView, let page, pdfView.currentSelection?.string?.isEmpty != false else { return }
            let point = pdfView.convert(gesture.location(in: pdfView), to: page)
            for (id, list) in annotations where list.contains(where: { $0.bounds.insetBy(dx: -2, dy: -2).contains(point) }) {
                onTapHighlight?(id)
                return
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: Selection bar

        private func selectionChanged() {
            bar?.removeFromSuperview()
            bar = nil
            guard canMark, let pdfView, let container, let page,
                  let selection = pdfView.currentSelection,
                  let text = PDFHighlightGeometry.text(of: selection, on: page), !text.isEmpty
            else { return }
            let bounds = pdfView.convert(selection.bounds(for: page), from: page)
            let bar = makeBar()
            container.addSubview(bar)
            let size = bar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let x = min(max(8, bounds.midX - size.width / 2), max(8, container.bounds.width - size.width - 8))
            // Über der Auswahl, sonst darunter (Platz für das System-Menü „Kopieren“ bleibt).
            var y = bounds.minY - size.height - 10
            if y < 4 { y = min(bounds.maxY + 10, container.bounds.height - size.height - 4) }
            bar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            self.bar = bar
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

        /// Text und Rechtecke der aktuellen Auswahl; danach Auswahl und Leiste weg.
        private func takeSelection() -> (String, [[Double]])? {
            guard let pdfView, let page, let selection = pdfView.currentSelection,
                  let text = PDFHighlightGeometry.text(of: selection, on: page), !text.isEmpty
            else { return nil }
            let rects = PDFHighlightGeometry.normalizedRects(of: selection, on: page)
            pdfView.clearSelection()
            bar?.removeFromSuperview()
            bar = nil
            return rects.isEmpty ? nil : (text, rects)
        }

        private func mark(color: String) {
            guard let taken = takeSelection() else { return }
            onMark?(color, taken.0, taken.1)
        }

        private func comment() {
            guard let taken = takeSelection() else { return }
            onComment?(taken.0, taken.1)
        }

        // MARK: Reveal

        /// Scrollt den äußeren Reader-ScrollView zur Markierung (nur wenn ihre Seite gerade geladen ist).
        private func reveal(_ id: Int) {
            guard let list = annotations[id], let first = list.first, let pdfView, let page else { return }
            let rect = pdfView.convert(first.bounds, from: page)
            var view: UIView? = container?.superview
            while let v = view {
                if let scroll = v as? UIScrollView {
                    let point = pdfView.convert(CGPoint(x: 0, y: rect.minY), to: scroll)
                    let maxOffset = max(0, scroll.contentSize.height - scroll.bounds.height)
                    let target = min(max(0, point.y - scroll.bounds.height / 3), maxOffset)
                    scroll.setContentOffset(CGPoint(x: 0, y: target), animated: true)
                    return
                }
                view = v.superview
            }
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
