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
