import Foundation

/// Berechnet die Größe des lokalen App-Speichers für die Anzeige in den
/// Einstellungen (Pendant zur serverseitigen Speicherverbrauchs-Anzeige,
/// siehe `MerlinAPI.getStorageUsage()`).
///
/// Erfasst `Application Support/merlin/` (Artikel-, Bild- und Highlight-Cache,
/// siehe `ArticleCacheService`/`ImageCacheService`/`HighlightCacheService`,
/// sowie `ReminderService`) plus `URLCache.shared` (HTTP-Antwort-Cache).
/// Der WKWebView-eigene Cache (`WKWebsiteDataStore`) wird nicht mitgezählt –
/// dessen Größe lässt sich nur asynchron und ohne Byte-Genauigkeit ermitteln;
/// `SettingsView.clearCache()` leert ihn aber trotzdem mit.
enum LocalStorageService {

    /// Bytegröße von `Application Support/merlin/` (rekursiv) + `URLCache.shared`.
    static func totalCacheBytes() -> Int64 {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("merlin", isDirectory: true)
        return directorySize(dir) + Int64(URLCache.shared.currentDiskUsage)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
