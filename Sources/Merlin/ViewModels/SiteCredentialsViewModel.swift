import Foundation
import Observation

/// Zustand für die Paywall-Abo-Zugangsdaten-Verwaltung (SiteCredentialsView).
/// Eigenes ViewModel statt Teil von ArticlesViewModel, da es einen komplett
/// eigenen Datenbereich (Personal-API `/user/site-credentials`) kapselt, der mit
/// der Artikel-Liste nichts zu tun hat.
@MainActor
@Observable
final class SiteCredentialsViewModel {
    private(set) var credentials: [SiteCredentialInfo] = []
    private(set) var availableDomains: [String] = []
    var isLoading = false
    var errorMessage: String?

    /// Domains ohne gespeicherte Zugangsdaten – Grundlage für die "Abo hinzufügen"-Auswahl.
    var connectableDomains: [String] {
        let connected = Set(credentials.map(\.domain))
        return availableDomains.filter { !connected.contains($0) }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await MerlinAPI.shared.getSiteCredentials()
            credentials = response.credentials
            availableDomains = response.availableDomains
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Speichert Zugangsdaten für `domain` und führt sofort einen Login-Test aus.
    /// Liefert `true` bei Erfolg; bei Fehlschlag steht die Server-Meldung in `errorMessage`.
    @discardableResult
    func save(domain: String, username: String, password: String) async -> Bool {
        errorMessage = nil
        do {
            _ = try await MerlinAPI.shared.updateSiteCredential(domain: domain, username: username, password: password)
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(domain: String) async {
        errorMessage = nil
        do {
            try await MerlinAPI.shared.deleteSiteCredential(domain: domain)
            credentials.removeAll { $0.domain == domain }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
