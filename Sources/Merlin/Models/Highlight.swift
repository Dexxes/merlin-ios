import Foundation

struct Highlight: Codable, Identifiable {
    let id: Int
    let articleId: Int
    let highlightedText: String
    let startXpath: String
    let startOffset: Int
    let endXpath: String
    let endOffset: Int
    let color: String
    let createdAt: String
    /// "owner" oder "guest" (Gäste markieren hinter dem Share-Link). Fehlt bei
    /// älteren Servern und im Offline-Cache von früher – dann Besitzer.
    var authorType: String? = nil
    var authorName: String? = nil
    /// Farbe des Verfassers (#rrggbb): Besitzer orange, Gäste je eigene. Färbt
    /// die Unterstreichung kommentierter Stellen und den Zähler daran. Nur in
    /// den Kommentar-Daten von merlin-nextcloud.
    var authorColor: String? = nil
    /// Markierungen in PDFs: Seite (ab 1) und Rechtecke `[x, y, w, h]`,
    /// normiert auf 0..1 bezogen auf die unrotierte CropBox, Ursprung oben
    /// links (wie im Web). Die XPaths sind dann nur ein Platzhalter.
    var pdfPage: Int? = nil
    var pdfRects: [[Double]]? = nil

    var isGuest: Bool { authorType == "guest" }
    var isPDF: Bool { pdfPage != nil }
}

extension Highlight {
    /// Dieselbe Markierung mit neuer Stelle (länger/kürzer gezogen) und ggf.
    /// neuer Farbe – für Cache und Anzeige, bis der Server sie bestätigt.
    func updated(with change: HighlightUpdate) -> Highlight {
        Highlight(
            id: id, articleId: articleId, highlightedText: change.highlightedText,
            startXpath: change.startXpath, startOffset: change.startOffset,
            endXpath: change.endXpath, endOffset: change.endOffset,
            color: change.color ?? color, createdAt: createdAt,
            authorType: authorType, authorName: authorName, authorColor: authorColor,
            pdfPage: change.pdfPage ?? pdfPage, pdfRects: change.pdfRects ?? pdfRects)
    }
}

struct HighlightCreate: Codable {
    let highlightedText: String
    let startXpath: String
    let startOffset: Int
    let endXpath: String
    let endOffset: Int
    let color: String
    /// Nur in PDFs (siehe `Highlight.pdfPage`); fehlt sonst im JSON.
    var pdfPage: Int? = nil
    var pdfRects: [[Double]]? = nil
}

/// Änderung einer bestehenden Markierung (`PUT /highlights/{id}`, nur
/// merlin-nextcloud): neue Stelle, optional neue Farbe. Die id bleibt, damit
/// hängen die Kommentare weiter daran.
struct HighlightUpdate: Codable, Equatable {
    let highlightedText: String
    let startXpath: String
    let startOffset: Int
    let endXpath: String
    let endOffset: Int
    /// Fehlt im JSON, wenn die Farbe bleibt.
    var color: String? = nil
    /// Nur in PDFs (siehe `Highlight.pdfPage`).
    var pdfPage: Int? = nil
    var pdfRects: [[Double]]? = nil
}
