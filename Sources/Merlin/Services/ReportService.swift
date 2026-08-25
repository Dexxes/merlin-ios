import Foundation

/// Sendet Artikel-Meldungen an das merlin-reports-Backend.
///
/// Die Backend-URL wird aus den Merlin-Nextcloud-Settings gelesen
/// (Schlüssel "reportBackendUrl", konfigurierbar unter Einstellungen → Reporting).
/// Der Wert wird nach dem ersten erfolgreichen Abruf gecacht; `invalidateCache()`
/// erzwingt beim nächsten Aufruf einen erneuten Settings-Fetch.
actor ReportService {

    static let shared = ReportService()
    private init() {}

    private var cachedBackendURL: String? = nil

    // MARK: – API

    /// Meldet einen Artikel mit optionalem Kommentar ans merlin-reports-Backend.
    /// Wirft `ReportError`, wenn die URL nicht konfiguriert ist oder der Server non-2xx antwortet.
    func report(url: String, comment: String = "") async throws {
        let backendURL = try await resolveBackendURL()

        guard let endpoint = URL(string: backendURL + "?action=report") else {
            throw ReportError.backendURLInvalid(backendURL)
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod  = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: String] = ["url": url, "comment": comment]
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw ReportError.serverError
        }
    }

    /// Leert den URL-Cache, damit beim nächsten `report()`-Aufruf die
    /// Settings erneut vom Server geladen werden (z.B. nach einer Einstellungsänderung).
    func invalidateCache() {
        cachedBackendURL = nil
    }

    // MARK: – Private

    /// Gibt die konfigurierte Backend-URL zurück.
    /// Beim ersten Aufruf (oder nach `invalidateCache()`) wird der Wert
    /// live aus den Nextcloud-Settings geladen und danach gecacht.
    private func resolveBackendURL() async throws -> String {
        if let cached = cachedBackendURL, !cached.isEmpty {
            return cached
        }

        let settings = try await MerlinAPI.shared.getSettings()
        let url = (settings["reportBackendUrl"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !url.isEmpty else {
            throw ReportError.backendURLNotConfigured
        }

        cachedBackendURL = url
        return url
    }

    // MARK: – Errors

    enum ReportError: LocalizedError {
        case backendURLNotConfigured
        case backendURLInvalid(String)
        case serverError

        var errorDescription: String? {
            switch self {
            case .backendURLNotConfigured:
                return "Kein Report-Backend konfiguriert. Bitte die URL unter Einstellungen → Reporting hinterlegen."
            case .backendURLInvalid(let url):
                return "Ungültige Backend-URL: \(url)"
            case .serverError:
                return "Der Server hat die Meldung abgelehnt."
            }
        }
    }
}
