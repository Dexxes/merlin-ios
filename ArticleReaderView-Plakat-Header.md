# ArticleReaderView – Plakat-Header mit Tonstufen (Design 2b)

Ziel: Farbfläche in der **User-Akzentfarbe** (`merlin_accent_progress_color`) von der Topline bis unter die Bildunterschrift des Titelbilds, danach vier Tonstufen (Akzent → Hintergrund) als Übergang zum Text. Info-Card und Tag-Pills entfallen; Metadaten werden eine Textzeile mit 2px-Linie.

Alle Änderungen in `Sources/Merlin/Views/ArticleReaderView.swift`.

Aufbau: Das Titelbild liegt nicht im nativen Header, sondern als erste `<figure>` im WKWebView. Die Fläche wird deshalb zweigeteilt:

- SwiftUI-Header (`articleHeader`) = Fläche mit Topline, Titel, Teaser, Metazeile.
- HTML-CSS: Die erste `figure`/`img` wird randlos auf Akzent gesetzt, danach folgen die Tonstufen.
- Gibt es kein führendes Titelbild (oder ist es ein Video-Artikel), zeichnet der SwiftUI-Header die Tonstufen selbst.

---

## 1 · Helfer (in `ArticleReaderView`, z. B. unter `infoCardBgColor`)

```swift
/// Lesbare Vordergrundfarbe auf der Akzentfläche (weiß, bei sehr hellen Akzenten dunkel).
private var onAccentHex: String {
    let s = accentColorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard s.count >= 6, let v = UInt32(s.prefix(6), radix: 16) else { return "#ffffff" }
    func lin(_ c: UInt32) -> Double {
        let x = Double(c) / 255
        return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    let l = 0.2126 * lin(v >> 16 & 0xff) + 0.7152 * lin(v >> 8 & 0xff) + 0.0722 * lin(v & 0xff)
    return l > 0.35 ? "#1c1c1e" : "#ffffff"
}

/// Tonstufen Akzent → Reader-Hintergrund: (Höhe, Akzentanteil). Muss zum CSS in §3 passen.
private static let accentSteps: [(height: CGFloat, amount: Double)] =
    [(14, 0.75), (12, 0.55), (10, 0.35), (8, 0.15)]

/// true, wenn der WebView-Inhalt direkt mit dem Titelbild beginnt – dann setzt das CSS
/// Fläche + Tonstufen fort, sonst zeichnet der native Header die Stufen.
private var readerLeadsWithHero: Bool {
    guard let content = current.content, !content.isEmpty,
          !NativeVideoHost.matches(current.url) else { return false }
    let head = injectHeroImageIfNeeded(into: content)
        .drop(while: \.isWhitespace).prefix(8).lowercased()
    return head.hasPrefix("<figure") || head.hasPrefix("<img")
}

/// „VON DAJANA RUBERT · 4 MIN · 24.09.26“
private var headerMetaLine: String {
    infoCardCells.map { $0.kind == .author ? "\($0.label) \($0.value)" : $0.value }
        .joined(separator: "  ·  ")
        .uppercased()
}
```

## 2 · `articleHeader` ersetzen (komplette `@ViewBuilder private var articleHeader`)

```swift
@ViewBuilder
private var articleHeader: some View {
    let accent   = Color(hexString: accentColorHex) ?? .red
    let onAccent = Color(hexString: onAccentHex) ?? .white
    let design   = readerFont.swiftUIDesign

    VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: safeAreaTop + 12)

            VStack(alignment: .leading, spacing: 18) {

                // ── Topline: Site links, erster Tag rechts, 2px-Linie darunter ──
                let hasSite = !current.displaySiteName.isEmpty
                if hasSite || !current.tags.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if hasSite {
                            let site = Text(current.displaySiteName.uppercased())
                            if let url = URL(string: current.url) {
                                Button { tappedLinkURL = url } label: { site }
                                    .buttonStyle(.plain)
                            } else { site }
                        }
                        Spacer(minLength: 0)
                        if let tag = current.tags.first {
                            Text(tag.name.uppercased()).lineLimit(1)
                        }
                    }
                    .font(.system(size: 11, weight: .bold, design: design))
                    .tracking(2.0)
                    .foregroundStyle(onAccent)
                    .padding(.bottom, 8)
                    .overlay(alignment: .bottom) { onAccent.frame(height: 2) }
                }

                // ── Titel ──
                Text(current.displayTitle)
                    .font(.system(size: CGFloat(fontSize) * 2.1, weight: .heavy, design: design))
                    .tracking(-1)
                    .foregroundStyle(onAccent)
                    .fixedSize(horizontal: false, vertical: true)

                // ── Teaser ──
                if let ex = current.excerpt, !ex.isEmpty {
                    Text(ex)
                        .font(.system(size: CGFloat(fontSize), weight: .medium, design: design))
                        .foregroundStyle(onAccent)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // ── Metazeile: 2px-Linie darüber (Gegenstück zur Topline) ──
                let meta = headerMetaLine
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 11, weight: .bold, design: design))
                        .tracking(1.0)
                        .foregroundStyle(onAccent)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                        .overlay(alignment: .top) { onAccent.frame(height: 2) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 22)
        }
        .background(accent)

        // ── Tonstufen nur, wenn kein Titelbild im WebView die Fläche fortsetzt ──
        if !readerLeadsWithHero {
            ForEach(Self.accentSteps.indices, id: \.self) { i in
                let step = Self.accentSteps[i]
                Rectangle()
                    .fill(accent.mix(with: readerBgColor, by: 1 - step.amount, in: .perceptual))
                    .frame(height: step.height)
            }
            Color.clear.frame(height: 16)
        }
    }
}
```

Dadurch werden `showAuthorFlyout`, `showSavedAtFlyout`, `authorIsTruncated`, `AuthorTruncationKey` und `infoCardCell(label:value:)` nicht mehr verwendet und können entfernt werden. `infoCardCells` bleibt die Datenquelle.

## 3 · CSS in `buildReaderHTML` (im `<style>`-Block, **nach** der `figcaption`-Regel einfügen)

Vorher neben `let accent = accentColorHex` ergänzen:

```swift
let onAccent = onAccentHex
```

Dann ins CSS:

```css
/* ── Titelbild auf Akzentfläche, randlos, danach Tonstufen ── */
body > figure:first-child,
body > img:first-child {
  display: block;
  width: calc(100% + 40px) !important;
  max-width: none !important;
  margin: 0 -20px 0 !important;
  background: \(accent);
  border-radius: 0 !important;
}
body > figure:first-child img {
  width: 100%; margin: 0 !important; border-radius: 0 !important;
}
body > figure:first-child figcaption {
  margin: 0; padding: 10px 20px 14px;
  color: \(onAccent);
  font-size: 11px; font-weight: 700; letter-spacing: 1px; text-transform: uppercase;
}
body > figure:first-child::after {
  content: ""; display: block; height: 44px;
  background: linear-gradient(to bottom,
    color-mix(in oklch, \(accent) 75%, \(bg)) 0 14px,
    color-mix(in oklch, \(accent) 55%, \(bg)) 14px 26px,
    color-mix(in oklch, \(accent) 35%, \(bg)) 26px 36px,
    color-mix(in oklch, \(accent) 15%, \(bg)) 36px 44px);
}
/* nacktes <img> ohne <figure>: Stufen per box-shadow */
body > img:first-child {
  margin-bottom: 44px !important;
  box-shadow:
    0 14px 0 color-mix(in oklch, \(accent) 75%, \(bg)),
    0 26px 0 color-mix(in oklch, \(accent) 55%, \(bg)),
    0 36px 0 color-mix(in oklch, \(accent) 35%, \(bg)),
    0 44px 0 color-mix(in oklch, \(accent) 15%, \(bg));
}
```

Die Stufen im CSS (14/12/10/8 px, 75/55/35/15 %) entsprechen `accentSteps` in §1.

## 4 · Hinweise

- Der Fortschrittsbalken nutzt dieselbe Akzentfarbe und ist oben auf der Fläche unsichtbar. Empfehlung: dort `onAccentHex` bzw. `readerFgColor` verwenden.
- Beim Überscrollen nach oben (Bounce) erscheint über dem Header die Hintergrundfarbe. Wer das nicht will, gibt dem `ScrollView` einen Hintergrund, der oben in der Akzentfarbe liegt.
- Dark/Sepia: Die Stufen mischen gegen `readerBgColor` bzw. `bg`, funktionieren also in allen Themes.
- `Color.mix(with:by:in:)` braucht iOS 18 (entspricht dem Deployment-Target); `color-mix()` in WebKit ab iOS 16.2.
