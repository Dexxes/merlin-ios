import SwiftUI

extension Color {
    init?(hexString hex: String) {
        let s = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard s.count == 6 else { return nil }
        var val: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&val) else { return nil }
        self.init(red:   Double((val >> 16) & 0xff) / 255,
                  green: Double((val >>  8) & 0xff) / 255,
                  blue:  Double( val        & 0xff) / 255)
    }

    /// Returns a `#RRGGBB` hex string for this color (ignores alpha).
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()),
                      Int((g * 255).rounded()),
                      Int((b * 255).rounded()))
    }
}

/// WCAG-Kontrast für Hex-Farben (#RRGGBB) — u. a. damit die frei wählbare
/// Akzentfarbe als Textfarbe im Reader lesbar bleibt (dunkles Lila auf Schwarz).
enum HexContrast {
    private static func rgb(_ hex: String) -> (Double, Double, Double)? {
        let s = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double(v >> 16 & 0xff) / 255, Double(v >> 8 & 0xff) / 255, Double(v & 0xff) / 255)
    }

    private static func luminance(_ c: (Double, Double, Double)) -> Double {
        func lin(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
    }

    private static func ratio(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Kontrastverhältnis zweier Hex-Farben (1…21), `nil` bei ungültiger Eingabe.
    static func ratio(_ fg: String, _ bg: String) -> Double? {
        guard let f = rgb(fg), let b = rgb(bg) else { return nil }
        return ratio(f, b)
    }

    /// `fg` unverändert, wenn es auf `bg` mindestens `minRatio` erreicht; sonst
    /// schrittweise Richtung Weiß (dunkler Hintergrund) bzw. Schwarz (heller
    /// Hintergrund) gemischt, bis der Kontrast reicht. Der Farbton bleibt erkennbar.
    static func readable(_ fg: String, on bg: String, minRatio: Double = 4.5) -> String {
        guard let f = rgb(fg), let b = rgb(bg) else { return fg }
        if ratio(f, b) >= minRatio { return fg }
        let target: Double = luminance(b) < 0.18 ? 1 : 0
        var mixed = f
        for step in 1...20 {
            let t = Double(step) / 20
            mixed = (f.0 + (target - f.0) * t, f.1 + (target - f.1) * t, f.2 + (target - f.2) * t)
            if ratio(mixed, b) >= minRatio { break }
        }
        return String(format: "#%02X%02X%02X",
                      Int((mixed.0 * 255).rounded()),
                      Int((mixed.1 * 255).rounded()),
                      Int((mixed.2 * 255).rounded()))
    }
}
