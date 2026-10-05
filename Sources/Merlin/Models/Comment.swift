import Foundation

/// Kommentar zu einem Artikel – vom Besitzer oder von einem Gast hinter dem
/// öffentlichen Share-Link (siehe merlin-nextcloud `Comment::jsonSerialize()`).
///
/// Threads sind eine Ebene tief: Wurzeln hängen an einer Markierung
/// (`highlightId`) oder am ganzen Artikel, alle Antworten liegen in
/// `replies` der Wurzel; `replyToId` nennt die Antwort, auf die geantwortet
/// wurde. Ein gelöschter Kommentar mit Antworten bleibt als Platzhalter
/// (`deleted == true`, leerer Name/Text) stehen.
struct Comment: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let articleId: Int
    let highlightId: Int?
    /// Text der Markierung beim Anlegen – bleibt erhalten, wenn die
    /// Markierung später entfernt wird.
    let quotedText: String?
    let parentId: Int?
    let replyToId: Int?
    /// "owner" oder "guest".
    let authorType: String
    let authorName: String
    let body: String
    let deleted: Bool
    let createdAt: String
    let updatedAt: String
    let edited: Bool
    /// Nur bei Thread-Wurzeln gefüllt.
    let replies: [Comment]?

    var isOwner: Bool { authorType == "owner" }

    var createdDate: Date? { Self.parseDate(createdAt) }

    static func parseDate(_ iso: String) -> Date? {
        ISO8601DateFormatter().date(from: iso)
    }
}

/// Antwort von `GET /articles/{id}/comments` und Inhalt jedes Push-Ereignisses:
/// alle Threads und Markierungen des Artikels plus Änderungsmarke.
struct CommentsPayload: Codable, Sendable {
    let signature: String
    let comments: [Comment]
    let highlights: [Highlight]
}

/// Ereignis aus dem Push-Kanal (`/articles/{id}/comments/stream`).
enum CommentStreamEvent: Sendable {
    /// Kommentare oder Markierungen haben sich geändert.
    case update(CommentsPayload)
    /// Der Server beendet den Kanal dauerhaft (z. B. kein Share-Link mehr) –
    /// erst nach einer Änderung am Link neu verbinden.
    case closed
}
