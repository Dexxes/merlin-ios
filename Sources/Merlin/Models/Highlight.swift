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

    var isGuest: Bool { authorType == "guest" }
}

struct HighlightCreate: Codable {
    let highlightedText: String
    let startXpath: String
    let startOffset: Int
    let endXpath: String
    let endOffset: Int
    let color: String
}
