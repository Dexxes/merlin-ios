import SwiftUI
import UIKit

/// Zeigt no-img.png als Platzhalterbild an.
/// Lädt die PNG-Datei direkt aus dem Modul-Bundle (kein xcassets-Lookup),
/// um xcassets-Caching-Probleme beim SPM-Build zu umgehen.
/// Fallback: systemgrauer Hintergrund, falls die Datei nicht gefunden wird.
struct NoImageView: View {
    var contentMode: ContentMode = .fill

    private static let uiImage: UIImage? = {
        guard let url = Bundle.module.url(forResource: "no-img", withExtension: "png"),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }()

    var body: some View {
        if let img = Self.uiImage {
            // Das Logo-PNG ist transparent; die im Erscheinungsbild-Menü
            // gewählte Akzentfarbe (PreferencesStore) liegt dahinter,
            // damit es in Light- und Darkmode gleich aussieht.
            ZStack {
                Color(hexString: PreferencesStore.shared.accentProgressColorHex) ?? Color.accentColor
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        } else {
            Color(.systemGray5)
        }
    }
}
