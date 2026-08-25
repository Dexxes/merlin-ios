import Foundation

// MARK: – Lokalisierung über das Modul-Bundle

/// `String(localized:)` sucht ohne explizites `bundle:`-Argument standardmäßig
/// in `Bundle.main`. SwiftPM packt die Resources des `Merlin`-Targets aber in
/// ein eigenes Resource-Bundle (`Bundle.module`) – ohne diesen Wrapper würde
/// jeder Lookup ins Leere laufen und `String(localized:)` auf den rohen Key
/// zurückfallen (genau das beobachtete Symptom unter xtool/`swift build`,
/// das keinen Xcode-Build-Schritt zum Mergen der Resources in die Haupt-App
/// kennt). `Bundle.module`-Zugriffe auf andere Resources, z. B. das Logo-PNG,
/// funktionieren bereits korrekt – also reicht es, denselben Bundle-Bezug
/// auch für Lokalisierung zu erzwingen.
func L(_ key: String.LocalizationValue, table: String? = nil) -> String {
    String(localized: key, table: table, bundle: .module)
}
