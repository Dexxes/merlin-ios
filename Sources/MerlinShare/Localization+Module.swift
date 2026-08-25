import Foundation

// MARK: – Lokalisierung über das Modul-Bundle

/// Siehe Merlin/Localization+Module.swift für die ausführliche Begründung.
/// Die Share-Extension ist ein eigenes SwiftPM-Target mit eigenem
/// `Bundle.module` – braucht daher eine eigene Kopie dieses Wrappers.
func L(_ key: String.LocalizationValue, table: String? = nil) -> String {
    String(localized: key, table: table, bundle: .module)
}
