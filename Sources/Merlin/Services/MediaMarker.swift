import Foundation

// MARK: – Audio-Quelle eines Artikels

/// Abspielbare Audio-Quelle eines Artikels - entweder aus dem Medien-Marker im gespeicherten
/// Content (`div.merlin-media`, siehe `MediaResolverService::buildMarkerHtml()` im Server) oder
/// aus `GET /articles/{id}/media`.
struct AudioSource: Equatable {
    struct Variant: Equatable {
        let label: String
        let url: URL
    }

    let variants: [Variant]
    let defaultIndex: Int
}

enum MediaMarker {
    private static let divRegex = try? NSRegularExpression(
        pattern: #"<div\b[^>]*\bmerlin-media\b[^>]*>.*?</div>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let fallbackLinkRegex = try? NSRegularExpression(
        pattern: #"<a\b[^>]*\bmerlin-media-fallback-link\b[^>]*>.*?</a>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// Inhalt des ersten Medien-Markers. `src`/`delivery` sind nur gesetzt, wenn der Marker eine
    /// https-Quelle mit bekannter Auslieferung trägt (wie `MediaResolverService::parseMarker()`).
    struct Parsed: Equatable {
        let kind: String
        let delivery: String?
        let src: URL?
    }

    static func parse(_ html: String) -> Parsed? {
        guard html.contains("merlin-media"), let regex = divRegex else { return nil }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let tag = ns.substring(with: match.range)
        guard let kind = attribute("data-media-kind", in: tag),
              kind == "audio" || kind == "video" else { return nil }
        let delivery = attribute("data-media-delivery", in: tag)
        let src = attribute("data-media-src", in: tag)
        guard let delivery, ["hls", "file", "embed"].contains(delivery),
              let src, src.hasPrefix("https://"), let url = URL(string: src) else {
            return Parsed(kind: kind, delivery: nil, src: nil)
        }
        return Parsed(kind: kind, delivery: delivery, src: url)
    }

    /// Entfernt den Marker samt „Zum Audio“-Fallback-Link (und den alten Einzel-Link ohne Marker-Div).
    static func stripMarker(from html: String) -> String {
        var result = html
        for regex in [divRegex, fallbackLinkRegex] {
            guard let regex else { continue }
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: name + #"\s*=\s*"([^"]*)""#),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        return (tag as NSString).substring(with: match.range(at: 1))
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: – Führendes Hero Image

    private static let leadingHeroRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:<figure\b[^>]*>.*?</figure>|<img\b[^>]*>)"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let captionRegex = try? NSRegularExpression(
        pattern: #"<figcaption\b[^>]*>(.*?)</figcaption>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let tagRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#)

    /// Trennt das Hero Image ab, das direkt am Anfang des Contents steht (Figure oder nacktes
    /// `<img>`), und liefert dessen Bildunterschrift als Klartext. Bei Audio-Artikeln ersetzt der
    /// native Player das Hero Image; die Bildunterschrift zeigt er selbst an.
    static func splitLeadingHero(from html: String) -> (caption: String?, rest: String) {
        guard let regex = leadingHeroRegex else { return (nil, html) }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else {
            return (nil, html)
        }
        let hero = ns.substring(with: match.range)
        let rest = ns.substring(from: match.range.location + match.range.length)

        var caption: String?
        if let captionRegex,
           let m = captionRegex.firstMatch(in: hero, range: NSRange(location: 0, length: (hero as NSString).length)),
           m.numberOfRanges > 1 {
            var text = (hero as NSString).substring(with: m.range(at: 1))
            if let tagRegex {
                text = tagRegex.stringByReplacingMatches(
                    in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
            }
            for (entity, char) in [("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&#039;", "'"),
                                   ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
                text = text.replacingOccurrences(of: entity, with: char)
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            caption = text.isEmpty ? nil : text
        }
        return (caption, rest)
    }

    // MARK: – Aufmacher-Video

    private static let figureOpenTagRegex = try? NSRegularExpression(
        pattern: #"^\s*<figure\b[^>]*>"#, options: [.caseInsensitive]
    )
    private static let classAttributeRegex = try? NSRegularExpression(
        pattern: #"\bclass\s*=\s*"([^"]*)""#, options: [.caseInsensitive]
    )
    private static let figureInsertRegex = try? NSRegularExpression(
        pattern: #"<figcaption\b|</figure>"#, options: [.caseInsensitive]
    )

    /// Aufmacher-Video eines Textartikels (Marker `div.merlin-media` mit `kind == video` und
    /// https-Datei/HLS, z. B. das VideoObject aus dem JSON-LD bei tagesschau.de): Das führende
    /// Hero Image wird zur Inline-Medien-Figure (`figure.merlin-inline-media` mit
    /// `div.merlin-inline-media-source`), auf die `merlinInlineMediaJS` den Player mit dem Hero
    /// Image als Poster legt – wie das Web (`MediaPlayer.vue`), das den Player ebenfalls auf das
    /// Hero-Bild setzt. Die Bildunterschrift bleibt unter dem Player.
    ///
    /// Der ursprüngliche Marker bleibt im DOM und wird nur per `display:none` ausgeblendet, damit sich
    /// die Tag-Zähler der Highlight-XPaths nicht verschieben; seinen „Zum Video“-Link übernimmt
    /// die Figure (sichtbar, bis der Player steht oder wenn die Wiedergabe scheitert).
    static func promoteHeroVideo(in html: String) -> String {
        guard let marker = parse(html), marker.kind == "video",
              let delivery = marker.delivery, delivery == "file" || delivery == "hls",
              let src = marker.src,
              let divRegex, let fallbackLinkRegex, let leadingHeroRegex,
              let figureOpenTagRegex, let classAttributeRegex, let figureInsertRegex else { return html }

        let ns = html as NSString
        guard let markerMatch = divRegex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else {
            return html
        }
        let markerHTML = ns.substring(with: markerMatch.range)
        let markerNS = markerHTML as NSString
        let link = fallbackLinkRegex.firstMatch(in: markerHTML, range: NSRange(location: 0, length: markerNS.length))
            .map { markerNS.substring(with: $0.range) } ?? ""

        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let sourceDiv = "<div class=\"merlin-inline-media-source\" data-media-kind=\"video\""
            + " data-media-delivery=\"\(delivery)\" data-media-src=\"\(escaped(src.absoluteString))\">"
            + link + "</div>"

        // Marker ausblenden (vor dem Umbau der Figure, die davor steht – Offsets bleiben gültig).
        var result = ns.replacingCharacters(
            in: NSRange(location: markerMatch.range.location, length: 4), with: "<div style=\"display:none\"")

        let resultNS = result as NSString
        guard let hero = leadingHeroRegex.firstMatch(in: result, range: NSRange(location: 0, length: resultNS.length)),
              hero.range.location + hero.range.length <= markerMatch.range.location,
              let openTag = figureOpenTagRegex.firstMatch(in: result, range: hero.range) else {
            // Kein führendes Hero-Figure: Player ohne Poster ganz oben.
            return "<figure class=\"merlin-inline-media\">\(sourceDiv)</figure>" + result
        }

        // sourceDiv vor der figcaption (bzw. vor </figure>) einsetzen …
        let heroNS = resultNS.substring(with: hero.range) as NSString
        if let insert = figureInsertRegex.firstMatch(in: heroNS as String, range: NSRange(location: 0, length: heroNS.length)) {
            result = resultNS.replacingCharacters(
                in: NSRange(location: hero.range.location + insert.range.location, length: 0), with: sourceDiv)
        }

        // … und die Figure als Inline-Medien-Figure markieren.
        let tagNS = (result as NSString).substring(with: openTag.range) as NSString
        let newTag: String
        if let cls = classAttributeRegex.firstMatch(in: tagNS as String, range: NSRange(location: 0, length: tagNS.length)) {
            newTag = tagNS.replacingCharacters(in: NSRange(location: cls.range(at: 1).location, length: 0),
                                               with: "merlin-inline-media ")
        } else {
            let figureEnd = tagNS.range(of: "<figure", options: .caseInsensitive)
            newTag = tagNS.replacingCharacters(in: NSRange(location: figureEnd.location + figureEnd.length, length: 0),
                                               with: " class=\"merlin-inline-media\"")
        }
        return (result as NSString).replacingCharacters(in: openTag.range, with: newTag)
    }

    // MARK: – Quelle auflösen

    /// Nur die im Content-Marker mitgelieferte Quelle (synchron, ohne Netzwerk).
    static func inlineAudioSource(from content: String?) -> AudioSource? {
        guard let content, let marker = parse(content), marker.kind == "audio",
              let src = marker.src, let delivery = marker.delivery,
              delivery == "file" || delivery == "hls" else { return nil }
        return AudioSource(variants: [.init(label: "", url: src)], defaultIndex: 0)
    }

    /// Marker mit Quelle → direkt; Marker ohne Quelle oder Artikel der Kategorie „Audio“ ohne Marker
    /// → `GET /articles/{id}/media`. Nur `kind == audio` mit Auslieferung `file`/`hls` ist abspielbar;
    /// Video und Embeds bleiben beim bisherigen Verhalten (nil).
    static func resolveAudio(for article: Article) async -> AudioSource? {
        let marker = article.content.flatMap(parse)
        if let marker {
            guard marker.kind == "audio" else { return nil }
            if let src = marker.src, let delivery = marker.delivery {
                guard delivery == "file" || delivery == "hls" else { return nil }
                return AudioSource(variants: [.init(label: "", url: src)], defaultIndex: 0)
            }
        } else if article.category != "Audio" {
            return nil
        }

        guard let response = try? await MerlinAPI.shared.getMedia(articleId: article.id),
              response.available, response.kind == "audio",
              response.delivery == "file" || response.delivery == "hls",
              let raw = response.variants else { return nil }
        let variants = raw.compactMap { v -> AudioSource.Variant? in
            guard v.url.hasPrefix("https://"), let url = URL(string: v.url) else { return nil }
            return .init(label: v.label, url: url)
        }
        guard !variants.isEmpty else { return nil }
        return AudioSource(variants: variants,
                           defaultIndex: min(max(response.defaultIndex ?? 0, 0), variants.count - 1))
    }
}
