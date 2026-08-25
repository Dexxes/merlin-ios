import Foundation

struct Article: Identifiable, Codable, Equatable {
    let id: Int
    var url: String
    var title: String
    var content: String?
    var excerpt: String?
    var author: String?
    var siteName: String?
    var imageUrl: String?
    var isFavorite: Bool
    /// ISO8601-Zeitpunkt der Favorisierung, aus demselben Wire-Feld `isFavorite`
    /// dekodiert (Server sendet dort entweder `false` oder ein Datum – kein
    /// separates Feld). Treibt die chronologische Sortierung der Favoriten-Liste.
    var favoritedAt: String?
    var isArchived: Bool
    var readingTime: Int
    var publishedAt: String?
    var createdAt: String
    var updatedAt: String
    var archivedAt: String?
    var tags: [Tag]
    var isProcessing: Bool
    var category: String?
    /// Geräteübergreifende Leseposition als Fraktion 0…1 (NICHT als Pixel-Offset:
    /// Pixel variieren mit Erscheinungsbild/Gerät, die Fraktion ist portabel).
    /// Optional, damit ältere Server-Antworten ohne dieses Feld dekodierbar bleiben.
    var scrollProgress: Double?
    /// Epoch-Millis des letzten Schreibens – treibt Last-Write-Wins gegen den lokalen Wert.
    var scrollUpdatedAt: Int?
    /// Domain einer Paywall, an der die Extraktion scheiterte (z. B. "tagesspiegel.de"), oder
    /// nil im Normalfall. Gesetzt vom Server, wenn PaywallLoginRequiredException auftrat und
    /// keine gültigen Zugangsdaten für diese Domain hinterlegt waren (siehe SiteCredentialsView).
    var requiresLoginDomain: String?
    /// Login-Seite der Paywall-Domain (z. B. für einen Info-Link), nur gesetzt wenn requiresLoginDomain gesetzt ist.
    var requiresLoginPage: String?

    enum CodingKeys: String, CodingKey {
        case id, url, title, content, excerpt, author, siteName, imageUrl
        case isFavorite, isArchived, readingTime, publishedAt, createdAt, updatedAt, archivedAt
        case tags, isProcessing, category, scrollProgress, scrollUpdatedAt
        case requiresLoginDomain, requiresLoginPage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        siteName = try c.decodeIfPresent(String.self, forKey: .siteName)
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        isArchived = try c.decode(Bool.self, forKey: .isArchived)
        readingTime = try c.decode(Int.self, forKey: .readingTime)
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        archivedAt = try c.decodeIfPresent(String.self, forKey: .archivedAt)
        tags = try c.decode([Tag].self, forKey: .tags)
        isProcessing = try c.decode(Bool.self, forKey: .isProcessing)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        scrollProgress = try c.decodeIfPresent(Double.self, forKey: .scrollProgress)
        scrollUpdatedAt = try c.decodeIfPresent(Int.self, forKey: .scrollUpdatedAt)
        requiresLoginDomain = try c.decodeIfPresent(String.self, forKey: .requiresLoginDomain)
        requiresLoginPage = try c.decodeIfPresent(String.self, forKey: .requiresLoginPage)

        // isFavorite kommt vom Server entweder als `false` (nicht favorisiert)
        // oder als ISO8601-String (Favorisierungszeitpunkt) – kein Bool-Only-Feld.
        if let dateString = try? c.decode(String.self, forKey: .isFavorite) {
            favoritedAt = dateString
            isFavorite = true
        } else {
            favoritedAt = nil
            isFavorite = (try? c.decode(Bool.self, forKey: .isFavorite)) ?? false
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(excerpt, forKey: .excerpt)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encodeIfPresent(siteName, forKey: .siteName)
        try c.encodeIfPresent(imageUrl, forKey: .imageUrl)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encode(readingTime, forKey: .readingTime)
        try c.encodeIfPresent(publishedAt, forKey: .publishedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try c.encode(tags, forKey: .tags)
        try c.encode(isProcessing, forKey: .isProcessing)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(scrollProgress, forKey: .scrollProgress)
        try c.encodeIfPresent(scrollUpdatedAt, forKey: .scrollUpdatedAt)
        try c.encodeIfPresent(requiresLoginDomain, forKey: .requiresLoginDomain)
        try c.encodeIfPresent(requiresLoginPage, forKey: .requiresLoginPage)

        // Spiegelbildlich zum Decoder: EIN Wire-Feld, false oder Datum. Wird
        // auch für den lokalen Disk-Cache verwendet, damit Decode/Encode
        // symmetrisch bleiben (keine zwei unterschiedlichen JSON-Formate).
        if let favoritedAt {
            try c.encode(favoritedAt, forKey: .isFavorite)
        } else {
            try c.encode(false, forKey: .isFavorite)
        }
    }

    /// Setzt/entfernt den Favoriten-Status inkl. Zeitstempel in einem Schritt,
    /// damit `isFavorite` und `favoritedAt` nie auseinanderlaufen (siehe
    /// `toggleArchive`-Pendant `isArchived`/`archivedAt` in ArticlesViewModel).
    mutating func setFavorite(_ favorite: Bool, at date: Date = Date()) {
        isFavorite = favorite
        favoritedAt = favorite ? ISO8601DateFormatter().string(from: date) : nil
    }

    var displayTitle: String {
        title.isEmpty ? url : title
    }

    var displaySiteName: String {
        siteName ?? URL(string: url)?.host ?? url
    }

    /// DuckDuckGo favicon service – works for virtually any domain.
    var faviconUrl: URL? {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")
    }

    /// Two articles are equal when they represent the same DB row AND none of
    /// the visible fields have changed since the last fetch.
    ///
    /// SwiftUI uses `Equatable.==` to decide whether to skip re-rendering a
    /// row inside `List` / `ForEach`.  Comparing only `id` here caused the
    /// spinner to stay visible forever: after extraction the server sets
    /// `isProcessing = false` and bumps `updatedAt`, but SwiftUI considered
    /// the article "unchanged" (same id) and never called the row's `body`
    /// again.  Including `updatedAt` and `isProcessing` covers most mutations.
    ///
    /// Tags are compared separately because some server implementations do not
    /// bump `updatedAt` on tag assignment.  Without this check a freshly tagged
    /// article would not re-render in the list immediately after saving.
    static func == (lhs: Article, rhs: Article) -> Bool {
        lhs.id           == rhs.id           &&
        lhs.isProcessing == rhs.isProcessing &&
        lhs.updatedAt    == rhs.updatedAt    &&
        lhs.requiresLoginDomain == rhs.requiresLoginDomain &&
        lhs.tags.map(\.id).sorted() == rhs.tags.map(\.id).sorted()
    }
}
