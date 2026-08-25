import Foundation

/// Status eines öffentlichen Share-Links. `enabled == false` heißt: für den
/// Artikel existiert (noch) kein Link – alle anderen Felder sind dann nil.
/// Ein Artikel hat höchstens einen Share-Link (siehe ShareController im
/// Backend: "Regenerieren" tauscht nur den Token aus statt einen zweiten
/// Datensatz anzulegen).
struct ArticleShare: Codable {
    let enabled: Bool
    let articleId: Int?
    let token: String?
    let hasPassword: Bool?
    let expiresAt: String?
    let createdAt: String?
    let updatedAt: String?
    let url: String?

    static let disabled = ArticleShare(
        enabled: false, articleId: nil, token: nil, hasPassword: nil,
        expiresAt: nil, createdAt: nil, updatedAt: nil, url: nil
    )
}
