import Foundation

/// Manuell gepflegter Commit-Marker für die Settings-Seite (siehe "About"-Sektion in
/// SettingsView.swift). Es gibt hier KEINE automatische Build-Zeit-Erfassung des
/// tatsächlichen Git-Commits: dieses Repo baut mit xtool/`swift build`, ohne einen
/// Xcode-Build-Phase-Mechanismus, der so etwas zuverlässig ohne ungetestete
/// SwiftPM-Build-Tool-Plugin-Komplexität injizieren könnte. Stattdessen wird dieser
/// Wert von Hand auf den Commit-Hash gesetzt, der diese Datei zuletzt geändert hat -
/// hilft beim Debuggen zu verifizieren, ob ein installierter Build einen bestimmten
/// Push tatsächlich enthält, kann aber hinter dem wirklich ausgecheckten Commit
/// zurückliegen, wenn seitdem committet wurde, ohne diesen Wert mit anzupassen.
enum BuildInfo {
    static let commit = "68d28e6"
}
