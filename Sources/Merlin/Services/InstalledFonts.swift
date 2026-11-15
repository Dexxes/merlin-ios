import CoreText
import UIKit

/// Listet die auf dem Gerät installierten Schriftfamilien für die freie Schriftwahl im
/// Erscheinungsbild-Sheet (Gegenstück zu `InstalledFonts.kt` unter Android).
///
/// Einschränkungen:
/// - `UIFont.familyNames` enthält nur die mit iOS ausgelieferten Schriften. Über Apps oder
///   Profile nachinstallierte Schriften (Einstellungen › Allgemein › Schriften) stehen einer App
///   nur über `UIFontPickerViewController` zur Verfügung und tauchen hier nicht auf.
/// - Familien ohne lateinische Grundzeichen (z. B. Emoji, reine Symbolschriften) werden
///   ausgefiltert, weil der Artikeltext damit nicht darstellbar wäre.
enum InstalledFonts {
    /// Alphabetisch sortierte Familiennamen. Ergebnis wird gecacht.
    static let familyNames: [String] = UIFont.familyNames
        .filter(coversBasicLatin)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    /// Ist die Familie (noch) installiert? Nach einem iOS-Update kann eine Schrift wegfallen.
    static func isInstalled(_ family: String) -> Bool {
        !UIFont.fontNames(forFamilyName: family).isEmpty
    }

    private static func coversBasicLatin(_ family: String) -> Bool {
        guard let name = UIFont.fontNames(forFamilyName: family).first,
              let font = UIFont(name: name, size: 17) else { return false }
        let chars = Array("Aa".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, chars, &glyphs, chars.count)
    }
}
