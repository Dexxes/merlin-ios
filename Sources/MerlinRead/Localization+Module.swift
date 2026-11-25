import Foundation

/// Siehe Merlin/Localization+Module.swift: eigenes SwiftPM-Target mit eigenem
/// `Bundle.module`, daher eine eigene Kopie dieses Wrappers.
func L(_ key: String.LocalizationValue, table: String? = nil) -> String {
    String(localized: key, table: table, bundle: .module)
}
