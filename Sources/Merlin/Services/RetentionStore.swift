import Foundation
import Observation

/// Löschfrist für archivierte Artikel (serverseitig, merlin-nextcloud
/// RetentionService). Der Server löscht archivierte Artikel nach Ablauf der
/// Frist, gezählt ab dem Archivieren; Favoriten haben eine eigene Frist.
/// Der Admin gibt je Frist ein Maximum vor, der Nutzer kann kürzer wählen,
/// effektiv gilt das Minimum (0 = unbegrenzt).
///
/// Die Werte kommen flach aus `GET /api/settings`. Der merlin-standalone-server
/// kennt keine Löschfrist und liefert die Felder nicht: dann ist
/// `isSupported == false` und die App zeigt die Einstellungen nicht an.
///
/// Bewusst NICHT Teil von `PreferencesStore.toServerDict()`: der Snapshot wird
/// bei Offline-Fehlern später erneut gesendet (`SettingsSyncQueue`) und könnte
/// so eine inzwischen auf einem anderen Gerät geänderte Frist überschreiben.
/// Eine Frist löscht Daten, deshalb wird sie nur direkt und online gespeichert.
@MainActor
@Observable
final class RetentionStore {
    static let shared = RetentionStore()
    private init() {}

    /// Optionen der Auswahl (zusätzlich 0 = „Nie“ bzw. „Maximum“).
    static let presetDays = [7, 30, 90, 180, 365]

    /// Server kennt die Löschfrist (Felder in `GET /api/settings` vorhanden).
    private(set) var isSupported = false
    /// Admin-Maximum, 0 = keine Vorgabe.
    private(set) var maxDays = 0
    private(set) var favoritesMaxDays = 0
    /// Wahl des Nutzers, 0 = keine eigene Frist.
    private(set) var userDays = 0
    private(set) var favoritesUserDays = 0
    /// Tatsächlich geltende Fristen, 0 = unbegrenzt.
    private(set) var effectiveDays = 0
    private(set) var favoritesEffectiveDays = 0
    /// Nutzer muss (erneut) auf die Frist hingewiesen werden.
    private(set) var noticeRequired = false

    /// Übernimmt die Löschfrist-Felder aus einem Settings-Dictionary.
    func apply(_ settings: [String: String]) {
        guard let effective = settings["retentionEffectiveDays"].flatMap(Int.init) else {
            isSupported = false
            noticeRequired = false
            return
        }
        isSupported            = true
        effectiveDays          = effective
        favoritesEffectiveDays = settings["retentionFavoritesEffectiveDays"].flatMap(Int.init) ?? 0
        maxDays                = settings["retentionMaxDays"].flatMap(Int.init) ?? 0
        favoritesMaxDays       = settings["retentionFavoritesMaxDays"].flatMap(Int.init) ?? 0
        userDays               = settings["retentionDays"].flatMap(Int.init) ?? userDays
        favoritesUserDays      = settings["retentionFavoritesDays"].flatMap(Int.init) ?? favoritesUserDays
        noticeRequired         = settings["retentionNoticeRequired"].map { $0 == "1" || $0 == "true" } ?? false
    }

    /// Lädt die aktuellen Werte vom Server (stillschweigend bei Fehlern).
    func refresh() async {
        guard CredentialsStore.shared.isConfigured,
              let settings = try? await MerlinAPI.shared.getSettings() else { return }
        apply(settings)
    }

    /// Speichert die Nutzerwahl (nur online) und übernimmt die neu berechneten Fristen.
    func save(days: Int? = nil, favoritesDays: Int? = nil) async throws {
        var dict: [String: Any] = [:]
        if let days          { dict["retentionDays"] = days }
        if let favoritesDays { dict["retentionFavoritesDays"] = favoritesDays }
        guard !dict.isEmpty else { return }
        apply(try await MerlinAPI.shared.updateSettingsReturningSaved(dict))
    }

    /// Hinweis als gelesen markieren (gilt auch für die Nextcloud-Web-App).
    func acknowledgeNotice() async {
        guard isSupported, noticeRequired else { return }
        noticeRequired = false
        if let settings = try? await MerlinAPI.shared.acknowledgeRetentionNotice() {
            apply(settings)
        }
    }

    // MARK: – Texte

    /// Beschreibung der geltenden Fristen für Tour-Schritt und Hinweis.
    var summaryText: String {
        guard isSupported else { return L("onboarding.retention.bodyUnknown") }
        let articles = effectiveDays > 0
            ? String(format: L("onboarding.retention.articles"), effectiveDays)
            : L("onboarding.retention.articlesKept")
        let favorites = favoritesEffectiveDays > 0
            ? String(format: L("onboarding.retention.favorites"), favoritesEffectiveDays)
            : L("onboarding.retention.favoritesKept")
        return [articles, favorites, L("onboarding.retention.settingsHint")].joined(separator: " ")
    }
}
