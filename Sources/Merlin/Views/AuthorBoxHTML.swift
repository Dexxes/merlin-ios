import Foundation

/// Autorenboxen (Foto, Name, Kurzbiografie) am Artikelende – Gegenstück zu `src/author-box.js` im
/// Nextcloud-Web-Reader. Daten: `Article.authors[].image/.bio` aus den Content-Filter-Feldern
/// `<metadata><author-image>/<author-bio>`. Ersetzt im Reader die Zeile „Autor, Medium“ am Ende.
///
/// Als eigene Elemente `<merlin-author-box>` hinter dem Artikeltext: der XPath-Zähler der Highlights
/// (`getXPath`) zählt Geschwister je Tag-Name und nur nach vorn, die Boxen verschieben also keinen Index.
enum AuthorBoxHTML {

    /// Autoren mit Name und mindestens Foto oder Bio (Foto nur als http(s)-URL).
    static func entries(_ authors: [ArticleAuthor]?) -> [ArticleAuthor] {
        (authors ?? []).compactMap { a in
            let name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let bio = a.bio?.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = ArticleAuthor(name: name,
                                      url: httpURL(a.url),
                                      image: httpURL(a.image),
                                      bio: (bio?.isEmpty ?? true) ? nil : bio)
            return (entry.image != nil || entry.bio != nil) ? entry : nil
        }
    }

    /// HTML aller Boxen oder "" ohne passende Autoren. `accent` ist die Akzentfarbe des Nutzers (#RRGGBB).
    static func html(for authors: [ArticleAuthor]?, accent: String) -> String {
        let list = entries(authors)
        guard !list.isEmpty else { return "" }
        let color = accent.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil ? accent : "#FF3B30"
        let boxes = list.map { box(for: $0) }.joined()
        return "<merlin-author-boxes style=\"--merlin-author-accent:\(color)\">\(boxes)</merlin-author-boxes>"
    }

    /// CSS für `html(for:)`, in den `<style>`-Block des Readers einzufügen.
    static let css = """
    merlin-author-boxes { display: block; margin: 2em 0 1.5em; -webkit-user-select: none; user-select: none; }
    merlin-author-box {
      display: block; margin: 1em 0; padding: 0.9em 1em;
      border-left: 4px solid var(--merlin-author-accent);
      border-radius: 0 8px 8px 0;
      background: rgba(128,128,128,0.1);
      background: color-mix(in srgb, var(--merlin-author-accent) 12%, transparent);
      font-size: 0.93em; line-height: 1.55;
    }
    /* Zeile 1: Foto und Name nebeneinander, zusammen zentriert; Zeile 2: Bio linksbündig. */
    merlin-author-box .merlin-author-header {
      display: flex; flex-wrap: wrap; align-items: center; justify-content: center;
      gap: 0.5em 1em; text-align: center;
    }
    merlin-author-box img.merlin-author-photo {
      display: block; flex: none; width: 4em !important; height: 4em !important; max-width: 4em !important;
      margin: 0 !important; object-fit: cover; border-radius: 50% !important;
    }
    merlin-author-box .merlin-author-name { font-weight: 600; margin: 0; }
    merlin-author-box .merlin-author-bio {
      margin: 0.75em 0 0; font-size: 0.9em; text-align: left; white-space: pre-line;
    }
    /* Dezente Trennlinie zwischen Kopfzeile und Bio, zentriert in Akzentfarbe. */
    merlin-author-box .merlin-author-bio::before {
      content: ""; display: block; width: 40%; height: 1px; margin: 0 auto 0.6em;
      background: var(--merlin-author-accent); opacity: 0.5;
    }
    merlin-author-box a {
      color: inherit !important; text-decoration: underline;
      text-decoration-color: var(--merlin-author-accent);
      text-decoration-thickness: 2px; text-underline-offset: 2px;
    }
    """

    // MARK: – Intern

    private static func box(for author: ArticleAuthor) -> String {
        var html = "<merlin-author-box role=\"note\"><div class=\"merlin-author-header\">"
        if let image = author.image {
            // Nicht ladbares Foto (Hotlink-Schutz, 404) einfach weglassen, Name und Bio bleiben.
            html += "<img class=\"merlin-author-photo\" alt=\"\" referrerpolicy=\"no-referrer\" loading=\"lazy\" "
                + "src=\"\(escape(image))\" onerror=\"this.remove()\">"
        }
        html += "<div class=\"merlin-author-name\">"
        if let url = author.url {
            html += "<a href=\"\(escape(url))\">\(escape(author.name))</a>"
        } else {
            html += escape(author.name)
        }
        html += "</div></div>"
        if let bio = author.bio {
            html += "<div class=\"merlin-author-bio\">\(linkified(bio))</div>"
        }
        return html + "</merlin-author-box>"
    }

    /// http(s)://… oder www.… bis zum nächsten Leerzeichen/Klammer/Anführungszeichen, oder ein
    /// Bluesky-Handle (@name.bsky.social bzw. @eigene-domain.de) – kein Mastodon-Handle (@name@instanz).
    private static let linkPattern = try! NSRegularExpression(
        pattern: #"\b(?:https?://|www\.)[^\s<>"'()]+|(?<![\w@])@[a-z0-9-]+(?:\.[a-z0-9-]+)+(?![\w@-])"#,
        options: [.caseInsensitive])

    /// Bio als HTML: Text escaped, URLs und Bluesky-Handles als Links (wie `appendLinkified` im Web-Reader).
    static func linkified(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in linkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var raw = ns.substring(with: match.range)
            // Satzzeichen am Ende gehören meist zum Satz, nicht zur URL.
            while let ch = raw.last, ".,;:!?…".contains(ch) { raw.removeLast() }
            let line = ns.substring(with: ns.lineRange(for: match.range))
            guard !raw.isEmpty, let href = linkTarget(raw, line: line) else { continue }
            out += escape(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            out += "<a href=\"\(escape(href))\">\(escape(raw))</a>"
            last = match.range.location + (raw as NSString).length
        }
        out += escape(ns.substring(from: last))
        return out
    }

    /// Handles auf *.bsky.social sind immer Bluesky; andere Domain-Handles nur, wenn die Zeile Bluesky
    /// erwähnt („Bluesky: @name.de“).
    private static func linkTarget(_ raw: String, line: String) -> String? {
        if raw.hasPrefix("@") {
            let handle = raw.dropFirst().lowercased()
            let isBluesky = handle.hasSuffix(".bsky.social")
                || line.range(of: "bluesky|bsky", options: [.regularExpression, .caseInsensitive]) != nil
            return isBluesky ? httpURL("https://bsky.app/profile/" + handle) : nil
        }
        return httpURL(raw.lowercased().hasPrefix("www.") ? "https://" + raw : raw)
    }

    private static func httpURL(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), let u = URL(string: s),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              u.host?.isEmpty == false else { return nil }
        return u.absoluteString
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
