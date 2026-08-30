import Foundation

enum MerlinAPIError: LocalizedError {
    case notConfigured
    case unauthorized
    case notFound
    case serverError(Int)
    /// `body` = Anfang der tatsächlichen Server-Antwort. Ohne diesen Auszug ist
    /// `DecodingError.localizedDescription` ("… nicht das korrekte Format …")
    /// nicht diagnostizierbar: es unterscheidet nicht zwischen "JSON, aber
    /// falscher Typ" und "gar kein JSON" (HTML-Fehlerseite, Login-Redirect).
    case decodingError(Error, body: String)
    case networkError(Error)
    /// Login-Versuch gegen eine externe Paywall-Seite (nicht gegen Merlin selbst) schlug fehl,
    /// z. B. falsches Zeitungs-Passwort. `message` ist die vom Server lokalisierte Meldung aus
    /// `{message, reason?}` (siehe SiteCredentialController::update in beiden Backends) –
    /// bewusst NICHT über `.unauthorized` gemappt, da dessen Meldung ("Check username and app
    /// password") sich auf die Merlin-Zugangsdaten selbst bezieht und hier irreführend wäre.
    case siteCredentialLoginFailed(message: String, reason: String?)
    case unknown

    var errorDescription: String? {
        switch self {
        case .notConfigured:       return "Nextcloud credentials not configured. Please open Settings."
        case .unauthorized:        return "Authentication failed. Check username and app password."
        case .notFound:            return "Resource not found."
        case .serverError(let c):  return "Server error (HTTP \(c))."
        case .decodingError(let e, let body):
            return "Could not parse server response: \(Self.describe(e))\nAntwort: \(body)"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .siteCredentialLoginFailed(let message, _): return message
        case .unknown:             return "An unknown error occurred."
        }
    }

    /// `DecodingError.localizedDescription` verschluckt Key-Pfad und erwarteten Typ.
    /// Der `debugDescription` aus dem Context nennt beides — genau das, was man
    /// zum Eingrenzen braucht.
    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }

        let (context, prefix): (DecodingError.Context, String) = switch decoding {
        case .typeMismatch(let type, let ctx):  (ctx, "Typ passt nicht (erwartet \(type))")
        case .valueNotFound(let type, let ctx): (ctx, "Wert fehlt (erwartet \(type))")
        case .keyNotFound(let key, let ctx):    (ctx, "Schlüssel fehlt: \(key.stringValue)")
        case .dataCorrupted(let ctx):           (ctx, "Daten unlesbar")
        @unknown default:                       fatalError("Unexpected DecodingError case")
        }

        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty
            ? "\(prefix) — \(context.debugDescription)"
            : "\(prefix) bei '\(path)' — \(context.debugDescription)"
    }
}

// MARK: – Counts response

// Pages/Videos sind die obersten Kategorien, Unread/Favorites/Archived
// darunter je Kategorie gezählt - siehe getCounts() in
// merlin-standalone-server/src/Db/ArticleRepository.php.
struct CategoryCounts: Codable {
    var total: Int
    var unread: Int
    var favorites: Int
    var archived: Int

    init(total: Int = 0, unread: Int = 0, favorites: Int = 0, archived: Int = 0) {
        self.total     = total
        self.unread    = unread
        self.favorites = favorites
        self.archived  = archived
    }
}

struct ArticleCounts: Codable {
    var pages: CategoryCounts
    var videos: CategoryCounts

    init(pages: CategoryCounts = CategoryCounts(), videos: CategoryCounts = CategoryCounts()) {
        self.pages  = pages
        self.videos = videos
    }
}

// MARK: – Settings value

/// Ein einzelner Settings-Wert aus `GET /api/settings`.
///
/// Der Endpunkt liefert pro Schlüssel unterschiedliche JSON-Typen (String, Int,
/// Double, Bool). Dieser Wrapper akzeptiert alle vier und liefert einheitlich
/// die String-Repräsentation, die `PreferencesStore.loadFromServer` erwartet
/// (dort werden "1"/"true" bzw. `Int(v)`/`Double(v)` geparst).
struct SettingValue: Decodable {
    let stringValue: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()

        // Bool wird bewusst auf "1"/"0" abgebildet statt auf "true"/"false":
        // das ist exakt das Format, das `toServerDict()` beim PUT zurückschickt
        // und das IConfig persistiert — Hin- und Rückweg bleiben so symmetrisch.
        // Bool muss vor Int/Double geprüft werden, damit JSON-`true` nicht als
        // Zahl interpretiert wird.
        if let v = try? c.decode(String.self) {
            stringValue = v
        } else if let v = try? c.decode(Bool.self) {
            stringValue = v ? "1" : "0"
        } else if let v = try? c.decode(Int.self) {
            stringValue = String(v)
        } else if let v = try? c.decode(Double.self) {
            stringValue = String(v)
        } else if c.decodeNil() {
            stringValue = ""
        } else {
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "Unsupported settings value type"
            )
        }
    }
}

// MARK: – Site credentials (Paywall-Abo-Login)

/// Eine gespeicherte Paywall-Zugangsdaten-Verbindung. Enthält nie das Passwort
/// (siehe SiteCredentialController-Docblock in beiden Backends).
struct SiteCredentialInfo: Decodable, Identifiable {
    var id: String { domain }
    let domain: String
    /// `SiteCredential::STATUS_*`: "ok" | "invalid_credentials" | "login_flow_broken" | "pending".
    let status: String
    let lastLoginAt: String?
}

struct SiteCredentialsResponse: Decodable {
    let credentials: [SiteCredentialInfo]
    /// Alle Domains, die überhaupt Paywall-Login unterstützen (Bundle-Config mit <login>-Sektion).
    let availableDomains: [String]
}

// MARK: – API service

actor MerlinAPI {

    static let shared = MerlinAPI()
    private init() {}

    private var credentials: CredentialsStore { CredentialsStore.shared }

    // MARK: – Base request builder

    private func makeRequest(_ path: String, method: String = "GET") throws -> URLRequest {
        guard credentials.isConfigured else { throw MerlinAPIError.notConfigured }
        guard let auth = credentials.basicAuthHeader else { throw MerlinAPIError.notConfigured }

        let base = credentials.nextcloudUrl
        // merlin-server hängt die API direkt unter /api statt unter Nextclouds
        // App-Routing-Präfix /index.php/apps/merlin/api - Pfade selbst sind
        // identisch (siehe merlin-server/public/index.php).
        let apiPrefix = credentials.backendKind == .standalone ? "/api" : "/index.php/apps/merlin/api"
        guard let url = URL(string: "\(base)\(apiPrefix)\(path)") else {
            throw MerlinAPIError.notConfigured
        }

        // Always bypass the local cache so that polling loops receive the
        // current server state, not a previously cached response.
        var req = URLRequest(url: url,
                             cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 15)
        req.httpMethod = method
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("MerlinApp-iOS/1.0", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func performRaw(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MerlinAPIError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else { throw MerlinAPIError.unknown }

        switch http.statusCode {
        case 200...299: return data
        case 401:       throw MerlinAPIError.unauthorized
        case 404:       throw MerlinAPIError.notFound
        default:        throw MerlinAPIError.serverError(http.statusCode)
        }
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await performRaw(request)
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch {
            // Body-Auszug mitgeben: eine HTML-Fehlerseite oder ein Login-Redirect
            // ist sonst nicht von einem echten Typfehler zu unterscheiden.
            let raw = String(data: data.prefix(300), encoding: .utf8) ?? "<\(data.count) Bytes, kein UTF-8>"
            throw MerlinAPIError.decodingError(error, body: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: – Articles

    func getArticles(isFavorite: Bool? = nil,
                     isArchived: Bool? = nil,
                     tagId: Int? = nil,
                     category: String? = nil,
                     contentType: String? = nil,
                     limit: Int = 50,
                     offset: Int = 0) async throws -> [Article] {
        var query = "?limit=\(limit)&offset=\(offset)"
        if let v = isFavorite { query += "&isFavorite=\(v ? 1 : 0)" }
        if let v = isArchived { query += "&isArchived=\(v ? 1 : 0)" }
        if let v = tagId      { query += "&tagId=\(v)" }
        if let v = category, let encoded = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query += "&category=\(encoded)"
        }
        if let v = contentType { query += "&contentType=\(v)" }

        var req = try makeRequest("/articles\(query)")
        req.httpMethod = "GET"
        return try await perform(req)
    }

    func getArticle(_ id: Int) async throws -> Article {
        let req = try makeRequest("/articles/\(id)")
        return try await perform(req)
    }

    func createArticle(url: String, tagIds: [Int] = []) async throws -> Article {
        var req = try makeRequest("/articles", method: "POST")
        var body: [String: Any] = ["url": url]
        if !tagIds.isEmpty { body["tagIds"] = tagIds }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(req)
    }

    /// Re-triggers server-side content extraction for an article whose
    /// extraction previously failed (e.g. transient network error while the
    /// server fetched the source URL), leaving it with `content == nil` and
    /// `isProcessing == false` forever. See `ArticlesViewModel.retryExtraction`.
    func retryExtraction(_ id: Int) async throws -> Article {
        var req = try makeRequest("/articles/\(id)/retry-extraction", method: "POST")
        req.httpBody = Data()
        return try await perform(req)
    }

    func deleteArticle(_ id: Int) async throws {
        let req = try makeRequest("/articles/\(id)", method: "DELETE")
        _ = try await performRaw(req)
    }

    func toggleFavorite(_ id: Int) async throws -> Article {
        var req = try makeRequest("/articles/\(id)/favorite", method: "PUT")
        req.httpBody = Data()
        _ = try await performRaw(req)
        return try await getArticle(id)
    }

    func toggleArchive(_ id: Int) async throws -> Article {
        var req = try makeRequest("/articles/\(id)/archive", method: "PUT")
        req.httpBody = Data()
        _ = try await performRaw(req)
        return try await getArticle(id)
    }

    /// Pusht die geräteübergreifende Leseposition (Fraktion 0…1 + Client-Zeitstempel
    /// für Last-Write-Wins). Bewusst „fire-and-forget" beim Aufrufer – ein
    /// Fehlschlag (offline) darf das Schließen des Readers nicht blockieren.
    func updateProgress(_ id: Int, progress: Double, updatedAt: Int) async throws {
        var req = try makeRequest("/articles/\(id)/progress", method: "PUT")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "progress": progress,
            "updatedAt": updatedAt,
        ])
        _ = try await performRaw(req)
    }

    func searchArticles(_ query: String) async throws -> [Article] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        let req = try makeRequest("/articles/search?query=\(encoded)")
        return try await perform(req)
    }

    // MARK: – Tags

    func getTags() async throws -> [Tag] {
        let req = try makeRequest("/tags")
        return try await perform(req)
    }

    func createTag(name: String) async throws -> Tag {
        var req = try makeRequest("/tags", method: "POST")
        req.httpBody = try JSONEncoder().encode(["name": name])
        return try await perform(req)
    }

    /// Resolves a list of tag names: matches existing ones by name (case-insensitive),
    /// creates any that don't exist yet, and returns all IDs.
    func resolveTagIds(for names: [String]) async throws -> [Int] {
        guard !names.isEmpty else { return [] }
        let existing = try await getTags()
        var ids: [Int] = []
        for name in names {
            if let found = existing.first(where: { $0.name.lowercased() == name.lowercased() }) {
                ids.append(found.id)
            } else {
                let created = try await createTag(name: name)
                ids.append(created.id)
            }
        }
        return ids
    }

    func addTagToArticle(articleId: Int, tagId: Int) async throws {
        var req = try makeRequest("/articles/\(articleId)/tags/\(tagId)", method: "POST")
        req.httpBody = "{}".data(using: .utf8)
        _ = try await performRaw(req)
    }

    func removeTagFromArticle(articleId: Int, tagId: Int) async throws {
        let req = try makeRequest("/articles/\(articleId)/tags/\(tagId)", method: "DELETE")
        _ = try await performRaw(req)
    }

    func getCounts() async throws -> ArticleCounts {
        let req = try makeRequest("/articles/counts")
        return try await perform(req)
    }

    // MARK: – Highlights

    func getHighlights(_ articleId: Int) async throws -> [Highlight] {
        let req = try makeRequest("/articles/\(articleId)/highlights")
        return try await perform(req)
    }

    func createHighlight(_ articleId: Int, payload: HighlightCreate) async throws -> Highlight {
        var req = try makeRequest("/articles/\(articleId)/highlights", method: "POST")
        req.httpBody = try JSONEncoder().encode(payload)
        return try await perform(req)
    }

    func deleteHighlight(_ id: Int) async throws {
        let req = try makeRequest("/highlights/\(id)", method: "DELETE")
        _ = try await performRaw(req)
    }

    // MARK: – Public Share

    /// Aktueller Share-Status ({ enabled: false }, falls noch kein Link existiert).
    /// Sowohl Nextcloud als auch merlin-server unterstützen Public-Share-Links
    /// unter demselben Pfad (siehe merlin-server/src/Controller/ShareController.php).
    func getShare(_ articleId: Int) async throws -> ArticleShare {
        let req = try makeRequest("/articles/\(articleId)/share")
        return try await perform(req)
    }

    /// Legt einen Share-Link an (idempotent – existiert bereits einer, wird
    /// dieser unverändert zurückgegeben). password/expiresAt (ISO-8601-Datum)
    /// sind optional.
    func createShare(_ articleId: Int, password: String? = nil, expiresAt: String? = nil) async throws -> ArticleShare {
        var body: [String: Any] = [:]
        if let password { body["password"] = password }
        if let expiresAt { body["expiresAt"] = expiresAt }

        var req = try makeRequest("/articles/\(articleId)/share", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(req)
    }

    /// Passwort/Ablaufdatum ändern. Doppel-Optional, um "nicht mitschicken"
    /// (äußeres nil – Feld bleibt unverändert) von "explizit auf null setzen"
    /// (`.some(nil)` – Schutz/Ablauf entfernen) zu unterscheiden, analog zum
    /// Sentinel-Muster in ShareController::update() auf dem Server.
    ///
    /// Beispiele:
    ///   updateShare(id, password: .some("neu"))  → Passwort setzen/ändern
    ///   updateShare(id, password: .some(nil))     → Passwortschutz entfernen
    ///   updateShare(id)                           → Passwort unverändert lassen
    func updateShare(_ articleId: Int, password: String?? = nil, expiresAt: String?? = nil) async throws -> ArticleShare {
        var body: [String: Any] = [:]
        if let password { body["password"] = password ?? NSNull() }
        if let expiresAt { body["expiresAt"] = expiresAt ?? NSNull() }

        var req = try makeRequest("/articles/\(articleId)/share", method: "PUT")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(req)
    }

    /// Token austauschen — alter Link wird sofort ungültig, Passwort/Ablauf bleiben erhalten.
    func regenerateShare(_ articleId: Int) async throws -> ArticleShare {
        var req = try makeRequest("/articles/\(articleId)/share/regenerate", method: "POST")
        req.httpBody = Data()
        return try await perform(req)
    }

    /// Share-Link widerrufen.
    func deleteShare(_ articleId: Int) async throws {
        let req = try makeRequest("/articles/\(articleId)/share", method: "DELETE")
        _ = try await performRaw(req)
    }

    // MARK: – Site credentials (Paywall-Abo-Login)

    /// Eigene gespeicherte Zugangsdaten + alle Domains, die Paywall-Login unterstützen.
    func getSiteCredentials() async throws -> SiteCredentialsResponse {
        let req = try makeRequest("/user/site-credentials")
        return try await perform(req)
    }

    /// Legt Zugangsdaten für `domain` an/überschreibt sie und löst serverseitig sofort einen
    /// Login-Versuch gegen die externe Paywall-Seite aus. Wirft `.siteCredentialLoginFailed` mit
    /// der lokalisierten Server-Meldung, falls der Login fehlschlägt (Zugangsdaten sind trotzdem
    /// gespeichert – ein späterer automatischer Retry funktioniert dann ohne erneute Eingabe).
    func updateSiteCredential(domain: String, username: String, password: String) async throws -> SiteCredentialInfo {
        var req = try makeRequest("/user/site-credentials/\(domain)", method: "PUT")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        return try await performSiteCredentialUpdate(req)
    }

    func deleteSiteCredential(domain: String) async throws {
        let req = try makeRequest("/user/site-credentials/\(domain)", method: "DELETE")
        _ = try await performRaw(req)
    }

    /// Eigene Statuscode-Behandlung statt `performRaw`/`perform`: 400/401 tragen bei diesem
    /// Endpunkt ein `{message, reason?}`-Fehlerobjekt, das dem Nutzer angezeigt werden soll
    /// (siehe SiteCredentialController::update in beiden Backends) – die generische
    /// `.unauthorized`-Meldung ("Check username and app password") bezieht sich auf die
    /// Merlin-Zugangsdaten selbst und wäre hier irreführend.
    private func performSiteCredentialUpdate(_ request: URLRequest) async throws -> SiteCredentialInfo {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MerlinAPIError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else { throw MerlinAPIError.unknown }

        switch http.statusCode {
        case 200...299:
            do {
                return try JSONDecoder().decode(SiteCredentialInfo.self, from: data)
            } catch {
                let raw = String(data: data.prefix(300), encoding: .utf8) ?? "<\(data.count) Bytes, kein UTF-8>"
                throw MerlinAPIError.decodingError(error, body: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case 400, 401:
            struct ErrorBody: Decodable { let message: String; let reason: String? }
            if let body = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw MerlinAPIError.siteCredentialLoginFailed(message: body.message, reason: body.reason)
            }
            throw MerlinAPIError.serverError(http.statusCode)
        default:
            throw MerlinAPIError.serverError(http.statusCode)
        }
    }

    // MARK: – TTS (via Proxy → Piper-Daemon; Nextcloud oder merlin-server)

    /// Gibt die vollständige Stream-URL für AVURLAsset zurück.
    /// Auth wird per AVURLAssetHTTPHeaderFieldsKey-Option gesetzt.
    ///
    /// Der kombinierte Endpunkt (GET /api/articles/{id}/tts?lang=…) übernimmt
    /// intern Plaintext-Extraktion, Daemon-Session-Anlage und das Streaming —
    /// iOS bekommt eine einzige URL ohne separaten prepare-Schritt. Existiert
    /// unter identischem Pfad-Suffix auf beiden Backends (siehe
    /// merlin-server/src/Controller/TtsController.php), nur das Präfix
    /// unterscheidet sich - gleiche Logik wie makeRequest().
    nonisolated func ttsStreamURL(articleId: Int, lang: String) throws -> URL {
        // Direkt auf CredentialsStore.shared zugreifen statt auf das actor-isolierte
        // credentials-Property, da diese Funktion nonisolated ist.
        let store = CredentialsStore.shared
        guard store.isConfigured else { throw MerlinAPIError.notConfigured }
        let base = store.nextcloudUrl
        let apiPrefix = store.backendKind == .standalone ? "/api" : "/index.php/apps/merlin/api"
        let safeLang = lang.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "de"
        guard let url = URL(string: "\(base)\(apiPrefix)/articles/\(articleId)/tts?lang=\(safeLang)") else {
            throw MerlinAPIError.notConfigured
        }
        return url
    }

    // MARK: – Native video (ARD/ZDF/Arte direct-stream playback)

    /// Eine abspielbare Variante aus `GET /articles/{id}/video-stream` (z. B. eine
    /// Sprachfassung oder Gebärdensprachversion). `subtitleLanguage` ist Arte-spezifisch
    /// (bei ARD/ZDF nicht gesetzt) und erzwingt nach dem Laden die passende Untertitelspur.
    struct VideoStreamVariant: Decodable {
        let label: String
        let url: String
        let subtitleLanguage: String?
    }

    /// Antwort des Stream-Resolvers. `available == false`, wenn die Artikel-URL zwar von
    /// `ardmediathek.de`/`zdf.de`/`arte.tv` stammt, sich aber kein Stream auflösen ließ.
    struct VideoStreamResponse: Decodable {
        let available: Bool
        let type: String?
        let variants: [VideoStreamVariant]?
        let defaultIndex: Int?
    }

    /// Löst die native HLS-Stream-URL für ARD/ZDF/Arte-Artikel auf (siehe
    /// `VideoStreamResolverService`/`VideoStreamController` in beiden Backends – identischer
    /// Pfad und identisches Antwortformat auf Nextcloud und merlin-server, nur das
    /// API-Präfix unterscheidet sich, siehe `makeRequest()`).
    func getVideoStream(articleId: Int) async throws -> VideoStreamResponse {
        let req = try makeRequest("/articles/\(articleId)/video-stream")
        return try await perform(req)
    }

    // MARK: – Settings

    /// Lädt alle Merlin-Einstellungen des aktuellen Nutzers vom Server.
    /// Gibt ein flaches Dictionary zurück (Schlüssel = Setting-Name, Wert = String).
    ///
    /// Der Server liefert seit `SettingsController::castForResponse()` bewusst
    /// gemischte JSON-Typen (fontSize als Number, saveProgress als Bool, Rest als
    /// String), damit der Vue-Client keine Typ-Flapping-Schleife auslöst. Ein
    /// direktes `[String: String]`-Decode scheitert daran mit `typeMismatch`,
    /// deshalb wird über `SettingValue` auf String normalisiert.
    func getSettings() async throws -> [String: String] {
        let req = try makeRequest("/settings")
        let raw: [String: SettingValue] = try await perform(req)
        return raw.mapValues(\.stringValue)
    }

    /// Speichert ein oder mehrere Einstellungen auf dem Server (PUT /settings).
    /// `settings` ist ein flaches Dictionary; alle Werte werden als String serialisiert.
    ///
    /// Die Antwort ist `{"success": true, "settings": {…}}` — nicht mehr ein flaches
    /// Bool-Dictionary. Deshalb wird nur der Statuscode ausgewertet und der Body
    /// verworfen; die kanonisch typisierten Werte holt der nächste `getSettings()`.
    func updateSettings(_ settings: [String: Any]) async throws {
        var req = try makeRequest("/settings", method: "PUT")
        req.httpBody = try JSONSerialization.data(withJSONObject: settings)
        _ = try await performRaw(req)
    }

    // MARK: – Storage usage

    /// Antwort von `GET /storage` (identischer Pfad und identisches
    /// Antwortformat auf Nextcloud und merlin-server, siehe
    /// StorageController::get()/AccountController::storageUsage()).
    struct StorageUsage: Decodable {
        let articleCount: Int
        let highlightCount: Int
        let articleBytes: Int
        let highlightBytes: Int
        let totalBytes: Int
    }

    /// Lädt den Speicherverbrauch des Nutzers in der Server-Datenbank
    /// (Artikel- + Highlight-Textspalten), für die Anzeige in den
    /// iOS-Einstellungen.
    func getStorageUsage() async throws -> StorageUsage {
        let req = try makeRequest("/storage")
        return try await perform(req)
    }

    // MARK: – Capabilities

    /// Antwort von `GET /capabilities` (identischer Pfad und identisches
    /// Antwortformat auf Nextcloud und merlin-server, siehe
    /// CapabilitiesController::index()).
    struct Capabilities: Decodable {
        struct Tts: Decodable {
            let available: Bool
        }
        let tts: Tts
    }

    /// Fragt server-seitige Feature-Verfügbarkeit ab (z. B. ob der
    /// Piper-TTS-Daemon konfiguriert und erreichbar ist), damit Clients
    /// optionale UI wie den Vorlesen-Button nur zeigen, wenn sie
    /// tatsächlich funktioniert.
    func getCapabilities() async throws -> Capabilities {
        let req = try makeRequest("/capabilities")
        return try await perform(req)
    }

    // MARK: – Connection test

    func testConnection() async throws {
        let req = try makeRequest("/articles/counts")
        let _: ArticleCounts = try await perform(req)
    }

    // MARK: – SSE: article processing updates

    /// Streams `Article` values as they finish processing on the server.
    ///
    /// The server holds the connection open until all pending articles are
    /// ready (or a ~55 s timeout expires) and then closes it.  The stream
    /// finishes without error when the server sends the `done`/`idle` sentinel.
    /// Callers should not poll — just `for try await article in stream { … }`.
    nonisolated func articleUpdateStream() -> AsyncThrowingStream<Article, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let req = try? await makeRequest("/events", method: "GET") else {
                    continuation.finish()
                    return
                }

                // SSE connections can stay open for up to ~55 s; use a longer timeout.
                var streamReq = req
                streamReq.timeoutInterval = 120

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: streamReq)
                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else {
                        continuation.finish()
                        return
                    }

                    var eventType = ""
                    var dataLines: [String] = []

                    for try await line in bytes.lines {
                        if line.isEmpty {
                            // Blank line = end of one SSE message block.
                            let payload = dataLines
                                .filter { $0.hasPrefix("data:") }
                                .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                                .joined()

                            if eventType == "article-ready",
                               let data = payload.data(using: .utf8),
                               let article = try? JSONDecoder().decode(Article.self, from: data) {
                                continuation.yield(article)
                            } else if payload.contains("\"idle\"") || payload.contains("\"done\"") {
                                continuation.finish()
                                return
                            }

                            eventType = ""
                            dataLines = []
                        } else if line.hasPrefix("event:") {
                            eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(line)
                        }
                        // Lines starting with ':' are SSE comments/heartbeats — ignore.
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
