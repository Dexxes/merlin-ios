import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted from ArticleReaderView.onDisappear with the article ID as `object`.
    static let articleProgressDidUpdate = Notification.Name("merlin.articleProgressDidUpdate")
}

// MARK: – Reader appearance types

enum ReaderTheme: String, CaseIterable {
    case auto   = "auto"
    case light  = "light"
    case dark   = "dark"
    case sepia  = "sepia"

    var label: String {
        switch self {
        case .auto:  return "Auto"
        case .light: return "Light"
        case .dark:  return "Dark"
        case .sepia: return "Sepia"
        }
    }

    var systemImage: String {
        switch self {
        case .auto:  return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark:  return "moon"
        case .sepia: return "cup.and.saucer"
        }
    }
}

enum ReaderFont: String, CaseIterable {
    case system    = "system"
    case serif     = "serif"
    case sansSerif = "sansSerif"
    case mono      = "mono"

    var label: String {
        switch self {
        case .system:    return "System"
        case .serif:     return "Serif"
        case .sansSerif: return "Sans"
        case .mono:      return "Monospace"
        }
    }

    var cssValue: String {
        switch self {
        case .system:    return "-apple-system, 'Helvetica Neue', Arial, sans-serif"
        case .serif:     return "Georgia, 'Times New Roman', serif"
        case .sansSerif: return "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif"
        case .mono:      return "'SF Mono', Menlo, 'Courier New', monospace"
        }
    }

    /// Wert den der Server für diese Schriftart verwendet.
    var serverValue: String {
        switch self {
        case .system:    return "default"
        case .serif:     return "serif"
        case .sansSerif: return "sans-serif"
        case .mono:      return "monospace"
        }
    }

    /// SwiftUI Font.Design-Äquivalent für native UI-Elemente (Titel, Teaser, Meta).
    var swiftUIDesign: Font.Design {
        switch self {
        case .system:    return .default
        case .serif:     return .serif
        case .sansSerif: return .default
        case .mono:      return .monospaced
        }
    }

    /// Aus Server-Wert (z.B. "default", "monospace") in iOS-Enum konvertieren.
    static func fromServerValue(_ value: String) -> ReaderFont {
        switch value {
        case "default":    return .system
        case "serif":      return .serif
        case "sans-serif": return .sansSerif
        case "monospace":  return .mono
        default:           return .system
        }
    }
}

enum ProgressEdge: String, CaseIterable {
    case left   = "left"
    case right  = "right"
    case top    = "top"
    case bottom = "bottom"
    case off    = "off"

    var label: String {
        switch self {
        case .left:   return "Links"
        case .right:  return "Rechts"
        case .top:    return "Oben"
        case .bottom: return "Unten"
        case .off:    return "Aus"
        }
    }

    var systemImage: String {
        switch self {
        case .left:   return "rectangle.lefthalf.inset.filled"
        case .right:  return "rectangle.righthalf.inset.filled"
        case .top:    return "rectangle.tophalf.inset.filled"
        case .bottom: return "rectangle.bottomhalf.inset.filled"
        case .off:    return "rectangle"
        }
    }
}

// MARK: – Store

/// Stores user preferences (not credentials) in UserDefaults.
final class PreferencesStore: @unchecked Sendable {
    static let shared = PreferencesStore()
    private init() {}

    private let defaults = UserDefaults.standard

    private enum Key {
        static let defaultFilter        = "merlin_default_filter"
        static let readerFontSize       = "merlin_reader_font_size"
        static let readerTheme          = "merlin_reader_theme"
        static let readerFont           = "merlin_reader_font"
        static let progressEdge         = "merlin_progress_edge"
        static let lineHeight           = "merlin_line_height"
        static let saveProgress           = "merlin_save_progress"
        static let resumeOnOpen           = "merlin_resume_on_open"
        static let accentProgressColor    = "merlin_accent_progress_color"
        static let prefetchImagesWifiOnly = "merlin_prefetch_wifi_only"
        static let developerMode          = "merlin_developer_mode"
        static let excludedTagIds         = "merlin_excluded_tag_ids"
        static let cacheRetentionDays     = "merlin_cache_retention_days"
    }

    // MARK: – App preferences

    /// Tag-IDs, deren Artikel in der Artikelliste ausgeblendet werden.
    var excludedTagIds: Set<Int> {
        get {
            guard let data = defaults.data(forKey: Key.excludedTagIds),
                  let ids  = try? JSONDecoder().decode(Set<Int>.self, from: data) else { return [] }
            return ids
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Key.excludedTagIds)
        }
    }

    var defaultFilter: ArticleFilter {
        get {
            guard let raw = defaults.string(forKey: Key.defaultFilter),
                  let filter = ArticleFilter(rawValue: raw) else { return .pagesUnread }
            return filter
        }
        set { defaults.set(newValue.rawValue, forKey: Key.defaultFilter) }
    }

    // MARK: – Reading positions
    //
    // Es wird ausschließlich die Fraktion (0–1) gespeichert/synchronisiert, nicht
    // mehr der absolute Pixel-Offset – siehe `saveScrollProgress`. Der alte
    // `merlin_pos_`-Schlüssel (Pixel) wird von `clearReadingPositions` weiterhin
    // mit aufgeräumt, falls noch Altbestände existieren.

    func clearReadingPositions() {
        let keys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("merlin_pos_") || $0.hasPrefix("merlin_pct_") || $0.hasPrefix("merlin_pcts_")
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
    }

    // MARK: – Reading progress (0–1, for card indicator + cross-device sync)
    //
    // Synchronisiert wird die Fraktion (0–1), nicht der Pixel-Offset (Pixel
    // variieren mit Erscheinungsbild/Gerät). Der Zeitstempel treibt die
    // geräteübergreifende Last-Write-Wins-Auflösung gegen den Server.

    func savedScrollProgress(for articleId: Int) -> CGFloat {
        CGFloat(defaults.double(forKey: "merlin_pct_\(articleId)"))
    }

    func saveScrollProgress(_ progress: CGFloat, for articleId: Int) {
        defaults.set(Double(progress), forKey: "merlin_pct_\(articleId)")
    }

    /// Epoch-Millis des letzten lokalen Progress-Writes (0 = noch nie auf diesem Gerät gespeichert).
    func savedScrollTimestamp(for articleId: Int) -> Int {
        defaults.integer(forKey: "merlin_pcts_\(articleId)")
    }

    func saveScrollTimestamp(_ timestampMillis: Int, for articleId: Int) {
        defaults.set(timestampMillis, forKey: "merlin_pcts_\(articleId)")
    }

    // MARK: – Reader preferences

    var readerFontSize: Int {
        get {
            let v = defaults.integer(forKey: Key.readerFontSize)
            return v == 0 ? 17 : v
        }
        set { defaults.set(newValue, forKey: Key.readerFontSize) }
    }

    var readerTheme: ReaderTheme {
        get {
            guard let raw = defaults.string(forKey: Key.readerTheme),
                  let theme = ReaderTheme(rawValue: raw) else { return .auto }
            return theme
        }
        set { defaults.set(newValue.rawValue, forKey: Key.readerTheme) }
    }

    var readerFont: ReaderFont {
        get {
            guard let raw = defaults.string(forKey: Key.readerFont),
                  let font = ReaderFont(rawValue: raw) else { return .system }
            return font
        }
        set { defaults.set(newValue.rawValue, forKey: Key.readerFont) }
    }

    var progressEdge: ProgressEdge {
        get {
            guard let raw  = defaults.string(forKey: Key.progressEdge),
                  let edge = ProgressEdge(rawValue: raw) else { return .left }
            return edge
        }
        set { defaults.set(newValue.rawValue, forKey: Key.progressEdge) }
    }

    var lineHeight: Double {
        get {
            let v = defaults.double(forKey: Key.lineHeight)
            return v == 0 ? 1.6 : v
        }
        set { defaults.set(newValue, forKey: Key.lineHeight) }
    }

    /// When true, image prefetching only runs on Wi-Fi; cellular is skipped.
    /// Default: true (conservative – avoids unexpected data usage).
    var developerMode: Bool {
        get { defaults.bool(forKey: Key.developerMode) }
        set { defaults.set(newValue, forKey: Key.developerMode) }
    }

    var prefetchImagesOnWifiOnly: Bool {
        get {
            guard defaults.object(forKey: Key.prefetchImagesWifiOnly) != nil else { return true }
            return defaults.bool(forKey: Key.prefetchImagesWifiOnly)
        }
        set { defaults.set(newValue, forKey: Key.prefetchImagesWifiOnly) }
    }

    /// Anzahl Tage, die Artikel offline (im lokalen Cache) vorgehalten werden,
    /// bevor `ArticleCacheService` sie automatisch entfernt – gilt einheitlich
    /// für alle Artikel (auch Favoriten/Archiv), gezählt seit dem letzten
    /// lokalen Sync (Upsert), nicht seit der Erstellung auf dem Server.
    /// 0 = gar nicht offline vorhalten. Bewusst NICHT server-synchronisiert
    /// (wie `prefetchImagesOnWifiOnly`) – Speicherkapazität/-bedarf ist pro
    /// Gerät unterschiedlich (iPhone vs. iPad vs. Android-Tablet).
    var cacheRetentionDays: Int {
        get {
            guard defaults.object(forKey: Key.cacheRetentionDays) != nil else { return 30 }
            return defaults.integer(forKey: Key.cacheRetentionDays)
        }
        set { defaults.set(newValue, forKey: Key.cacheRetentionDays) }
    }

    var accentProgressColorHex: String {
        get {
            defaults.string(forKey: Key.accentProgressColor) ?? "#FF3B30"
        }
        set { defaults.set(newValue, forKey: Key.accentProgressColor) }
    }

    var saveProgress: Bool {
        get {
            guard defaults.object(forKey: Key.saveProgress) != nil else { return true }
            return defaults.bool(forKey: Key.saveProgress)
        }
        set { defaults.set(newValue, forKey: Key.saveProgress) }
    }

    var resumeOnOpen: Bool {
        get {
            guard defaults.object(forKey: Key.resumeOnOpen) != nil else { return true }
            return defaults.bool(forKey: Key.resumeOnOpen)
        }
        set { defaults.set(newValue, forKey: Key.resumeOnOpen) }
    }

    // MARK: – Server sync

    /// Wendet ein vom Server geladenes Settings-Dictionary an (server wins).
    /// Unbekannte Schlüssel werden ignoriert.
    func loadFromServer(_ settings: [String: String]) {
        if let v = settings["theme"],       let t = ReaderTheme(rawValue: v)    { readerTheme   = t }
        if let v = settings["fontFamily"]                                        { readerFont     = ReaderFont.fromServerValue(v) }
        if let v = settings["fontSize"],    let n = Int(v)                       { readerFontSize = n }
        if let v = settings["lineHeight"],  let d = Double(v)                    { lineHeight     = d }
        if let v = settings["progressEdge"], let e = ProgressEdge(rawValue: v)  { progressEdge   = e }
        if let v = settings["defaultView"]                                       { defaultFilter  = ArticleFilter.fromServerValue(v) }
        if let v = settings["saveProgress"]                                      { saveProgress          = v == "1" || v == "true" }
        if let v = settings["resumeOnOpen"]                                      { resumeOnOpen          = v == "1" || v == "true" }
        if let v = settings["accentColor"], !v.isEmpty                           { accentProgressColorHex = v }
    }

    /// Serialisiert alle sync-fähigen Einstellungen für den Server-PUT.
    func toServerDict() -> [String: Any] {
        [
            "theme":        readerTheme.rawValue,
            "fontFamily":   readerFont.serverValue,
            "fontSize":     readerFontSize,
            "lineHeight":   lineHeight,
            "progressEdge": progressEdge.rawValue,
            "defaultView":  defaultFilter.serverValue,
            "saveProgress": saveProgress ? "1" : "0",
            "resumeOnOpen": resumeOnOpen ? "1" : "0",
            "accentColor":  accentProgressColorHex,
        ]
    }
}
