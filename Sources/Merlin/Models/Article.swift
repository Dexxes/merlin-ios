import Foundation

/// Daten der Support-Infobox (Abo-/Spendenlink der Quelle) aus `GET /articles/{id}`. Fehlt (nil), wenn die
/// Domain weder Abo- noch Spenden-URL hinterlegt hat oder der Nutzer dort einen aktiven Abo-Login hat.
struct SupportBox: Codable, Equatable {
    var siteName: String
    var subscribeUrl: String?
    var donationsUrl: String?
    /// Akzentfarbe des Nutzers (`#RRGGBB`), wie sie der Server aus den Einstellungen kennt.
    var accentColor: String
    /// Icon der konkreten Artikelseite (apple-touch-icon/`rel=icon`, vom Server aus dem Seiten-HTML gelesen);
    /// nil bei älteren Servern oder wenn keins bekannt ist.
    var iconUrl: String?
}

struct Article: Identifiable, Codable, Equatable {
    let id: Int
    var url: String
    var title: String
    var content: String?
    var excerpt: String?
    var author: String?
    /// Link zum Autorenprofil bei der Quelle (`authorUrl`, Merlin-Server ab Migration 26). Nur bei genau
    /// einem Autor gesetzt; nil bei älteren Servern. Für die Anzeige `authorProfileURL` verwenden.
    var authorUrl: String?
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
    /// true, wenn der Extractor per Content-Filter-<paywall><marker> einen Bezahlartikel erkannt hat, für dessen
    /// Domain KEINE Login-Unterstützung existiert (siehe requiresLoginDomain oben - beide sind nie gleichzeitig
    /// gesetzt). Merlin kann den Artikel dann nicht automatisch freischalten; der Reader zeigt stattdessen einen
    /// Hinweis mit den Optionen "Abo abschliessen" (paywallSubscribeUrl) und "Archivieren".
    var isPaywalled: Bool
    /// Ziel-URL zum Abschliessen eines Abos für diese Domain, aus der Content-Filter-Config. Kann fehlen, auch
    /// wenn isPaywalled true ist (Domain ohne hinterlegte Abo-URL).
    var paywallSubscribeUrl: String?
    /// Domain, die in content-filters/$unsupported.xml steht (z. B. "pressreader.com"), oder nil im Normalfall.
    /// Gesetzt vom Server, wenn UnsupportedSiteException auftrat: die Domain liefert grundsätzlich keinen
    /// scrapbaren Artikeltext (reine JS-SPA/Bild-Viewer) - anders als bei requiresLoginDomain gibt es hier
    /// keinen Login, der das beheben könnte, der Reader zeigt nur einen erklärenden Hinweis statt Retry.
    var unsupportedSiteDomain: String?
    /// Nur in der Einzelabruf-Antwort (`getArticle`) gesetzt, nicht in Listen; wird bewusst nicht in den
    /// Offline-Cache geschrieben (der Login-Status des Nutzers kann sich ändern), siehe `encode(to:)`.
    var supportBox: SupportBox?
    /// Nextcloud-Datei-ID bei Einträgen für Dateien aus „Merlin Dateien“ (vom Handy geteilte Bilder, Videos,
    /// Audios, PDFs, sonstige Dateien; merlin-nextcloud ab 1.0.18), sonst nil. `url` zeigt dann in die
    /// Nextcloud-Dateien-App, der Inhalt lädt die Datei über signierte Links.
    var fileId: Int?
    /// MIME-Typ der Datei bei Datei-Einträgen.
    var fileMime: String?

    enum CodingKeys: String, CodingKey {
        case id, url, title, content, excerpt, author, authorUrl, siteName, imageUrl
        case isFavorite, isArchived, readingTime, publishedAt, createdAt, updatedAt, archivedAt
        case tags, isProcessing, category, scrollProgress, scrollUpdatedAt
        case requiresLoginDomain, requiresLoginPage
        case isPaywalled, paywallSubscribeUrl
        case unsupportedSiteDomain
        case supportBox
        case fileId, fileMime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        authorUrl = try? c.decodeIfPresent(String.self, forKey: .authorUrl)
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
        // decodeIfPresent statt decode: ältere Server-Antworten ohne dieses Feld bleiben dekodierbar.
        isPaywalled = (try? c.decodeIfPresent(Bool.self, forKey: .isPaywalled)) ?? false
        paywallSubscribeUrl = try c.decodeIfPresent(String.self, forKey: .paywallSubscribeUrl)
        unsupportedSiteDomain = try c.decodeIfPresent(String.self, forKey: .unsupportedSiteDomain)
        supportBox = try? c.decodeIfPresent(SupportBox.self, forKey: .supportBox)
        fileId = try? c.decodeIfPresent(Int.self, forKey: .fileId)
        fileMime = try? c.decodeIfPresent(String.self, forKey: .fileMime)

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
        try c.encodeIfPresent(authorUrl, forKey: .authorUrl)
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
        try c.encode(isPaywalled, forKey: .isPaywalled)
        try c.encodeIfPresent(paywallSubscribeUrl, forKey: .paywallSubscribeUrl)
        try c.encodeIfPresent(unsupportedSiteDomain, forKey: .unsupportedSiteDomain)
        try c.encodeIfPresent(fileId, forKey: .fileId)
        try c.encodeIfPresent(fileMime, forKey: .fileMime)

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

    /// Autorenprofil-Link für die Anzeige: nur absolute http(s)-URLs und nur, wenn auch ein Autorname
    /// da ist (wie `safeAuthorUrl` im Web-Reader).
    var authorProfileURL: URL? {
        guard let name = author?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let raw = authorUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// DuckDuckGo favicon service – works for virtually any domain.
    var faviconUrl: URL? {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")
    }

    /// true für PDF-Artikel: der Server speichert nur die Quell-URL (`category == "PDF"`), die PDF wird beim
    /// Öffnen von dort geladen (siehe `PDFArticleView`/`PDFCacheService`). Fallback auf die Endung `.pdf`
    /// für Artikel, die ein älterer Server ohne Kategorie angelegt hat.
    var isPDF: Bool {
        if category == "PDF" { return true }
        guard let path = URL(string: url)?.path else { return false }
        return path.lowercased().hasSuffix(".pdf")
    }

    /// Wo die PDF eines PDF-Artikels liegt: bei Datei-Einträgen der signierte Link aus dem Marker
    /// `div.merlin-pdf[data-pdf-src]` im Inhalt (`url` führt dort in die Nextcloud-Dateien-App und braucht
    /// einen Login; nil, solange der Inhalt noch nicht geladen ist), sonst die Quell-URL.
    var pdfSourceURL: URL? {
        guard fileId != nil else { return URL(string: url) }
        guard let content,
              let range = content.range(of: #"data-pdf-src="[^"]+""#, options: .regularExpression) else { return nil }
        let raw = content[range].dropFirst("data-pdf-src=\"".count).dropLast()
        return URL(string: raw.replacingOccurrences(of: "&amp;", with: "&"))
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
        lhs.isPaywalled == rhs.isPaywalled &&
        lhs.unsupportedSiteDomain == rhs.unsupportedSiteDomain &&
        lhs.tags.map(\.id).sorted() == rhs.tags.map(\.id).sorted()
    }
}
