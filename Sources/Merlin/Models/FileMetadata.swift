import Foundation

/// One group of the "Metadata" section the server puts below a file entry's
/// content (merlin-nextcloud `MerlinFileService::metadataHtml`): file details,
/// EXIF, GPS, IPTC, XMP, ID3, QuickTime/MP4 or PDF.
struct FileMetadataGroup: Identifiable, Equatable {
    struct Entry: Identifiable, Equatable {
        let id: Int
        let label: String
        let value: String
    }

    let id: Int
    let title: String
    let entries: [Entry]
}

enum FileMetadataParser {
    /// Heading and groups of the metadata section in `html`, nil without one.
    /// The reader web view shows the section itself; this is for views that
    /// don't render the content (PDF entries).
    static func parse(_ html: String) -> (title: String, groups: [FileMetadataGroup])? {
        guard let start = html.range(of: #"<section class="merlin-file-metadata">"#) else { return nil }
        let section = html[start.upperBound...]
        let title = firstMatch(#"<h2>(.*?)</h2>"#, in: section).map(plainText) ?? ""

        var groups: [FileMetadataGroup] = []
        for (index, details) in matches(#"<summary>(.*?)</summary>(.*?)</details>"#, in: section).enumerated() {
            let rows = matches(#"<tr><th>(.*?)</th><td>(.*?)</td></tr>"#, in: details[1])
            let entries = rows.enumerated().map { rowIndex, row in
                FileMetadataGroup.Entry(id: rowIndex, label: plainText(row[0]), value: plainText(row[1]))
            }
            groups.append(FileMetadataGroup(id: index, title: plainText(details[0]), entries: entries))
        }
        return groups.isEmpty ? nil : (title, groups)
    }

    private static func firstMatch(_ pattern: String, in text: Substring) -> String? {
        matches(pattern, in: String(text)).first?.first
    }

    private static func matches(_ pattern: String, in text: Substring) -> [[String]] {
        matches(pattern, in: String(text))
    }

    /// Capture groups of every match.
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { i in
                let range = match.range(at: i)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }

    /// Strips tags (e.g. the map link around the GPS position) and decodes
    /// the entities `htmlspecialchars` writes, plus numeric ones.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#039;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9A-Fa-f]+|[0-9]+);"#) {
            let ns = text as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let code = ns.substring(with: match.range(at: 1))
                let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                result += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ns.substring(with: match.range)
                last = match.range.location + match.range.length
            }
            text = result + ns.substring(from: last)
        }
        // &amp; last, so "&amp;lt;" stays "&lt;".
        return text.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
