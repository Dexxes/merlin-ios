import Foundation

/// A calendar event suggested from the "Recognized text" section the server
/// puts into image entries (merlin-nextcloud `MerlinFileService::textHtml`,
/// text from the share extension's OCR). The reader offers it under the text
/// and opens Apple's event dialog pre-filled; nothing is saved without the
/// user confirming there.
struct RecognizedTextEvent: Equatable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String

    /// Link the reader puts below the recognized text (`ArticleWebView`
    /// hands it to `onLinkTapped` like other links).
    static let linkURL = URL(string: "merlin-event:create")!

    /// Plain text of the recognized-text section in `html`, nil without one.
    static func recognizedText(in html: String) -> String? {
        guard let start = html.range(of: #"<section class="merlin-file-text">"#),
              let end = html.range(of: "</section>", range: start.upperBound..<html.endIndex)
        else { return nil }
        var section = String(html[start.upperBound..<end.lowerBound])
        section = section.replacingOccurrences(of: #"<h2>.*?</h2>"#, with: "", options: .regularExpression)
        section = section.replacingOccurrences(of: #"<br\s*/?>\s*"#, with: "\n", options: .regularExpression)
        section = section.replacingOccurrences(of: "</p>", with: "\n\n")
        let text = FileMetadataParser.plainText(section)
        return text.isEmpty ? nil : text
    }

    /// The first date in `text` as an event: the first line that is not
    /// just the date becomes the title, a found address the location, the
    /// whole text the notes. Without a time of day the event is all-day;
    /// without an end it lasts an hour.
    static func detect(in text: String, calendar: Calendar = .current) -> RecognizedTextEvent? {
        let types: NSTextCheckingResult.CheckingType = [.date, .address]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return nil }
        let ns = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let dateMatch = matches.first(where: { $0.resultType == .date && $0.date != nil }),
              let date = dateMatch.date else { return nil }

        let matchedText = ns.substring(with: dateMatch.range)
        let isAllDay = !hasTimeOfDay(matchedText)
        let start = isAllDay ? calendar.startOfDay(for: date) : date
        let end: Date
        if dateMatch.duration > 0 {
            end = start.addingTimeInterval(dateMatch.duration)
        } else if isAllDay {
            end = start
        } else {
            end = start.addingTimeInterval(3600)
        }

        let location = matches.first { $0.resultType == .address }
            .map { ns.substring(with: $0.range).replacingOccurrences(of: "\n", with: ", ") }

        return RecognizedTextEvent(
            title: title(in: text, skipping: [matchedText, location].compactMap { $0 }),
            start: start, end: end, isAllDay: isAllDay,
            location: location, notes: text)
    }

    /// "19:30", "19.30 Uhr", "7 pm", "20h" and the like.
    private static func hasTimeOfDay(_ text: String) -> Bool {
        // "14.06." is a date, so a dot only counts as a time with "Uhr" after it.
        let pattern = #"(?<![\d.])\d{1,2}:\d{2}(?!\d)|(?<![\d.])\d{1,2}(\.\d{2})?\s*(uhr|h|am|pm|a\.m\.|p\.m\.)(?![a-zäöü])"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func title(in text: String, skipping parts: [String]) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines where line.count >= 3 {
            var rest = line
            for part in parts { rest = rest.replacingOccurrences(of: part, with: "") }
            // Lines that are only the date or address (plus separators) don't name the event.
            guard rest.rangeOfCharacter(from: .letters) != nil else { continue }
            return String(line.prefix(80))
        }
        return ""
    }

    /// `html` with a "create event" link right below the recognized-text
    /// section, when that text contains a date.
    static func addingEventLink(to html: String, label: String) -> String {
        guard html.contains(#"<section class="merlin-file-text">"#),
              let text = recognizedText(in: html), detect(in: text) != nil,
              let start = html.range(of: #"<section class="merlin-file-text">"#),
              let end = html.range(of: "</section>", range: start.upperBound..<html.endIndex)
        else { return html }
        let escaped = label
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let link = #"<p class="merlin-file-event"><a href="\#(linkURL.absoluteString)">\#(escaped)</a></p>"#
        var result = html
        result.insert(contentsOf: link, at: end.lowerBound)
        return result
    }
}
