import Foundation
import Observation

/// Kommentare und Markierungen des offenen Artikels, live gehalten über den
/// Push-Kanal des Servers (`MerlinAPI.commentStream`).
///
/// Schreibt ein Gast hinter dem Share-Link (oder der Besitzer auf einem
/// anderen Gerät) einen Kommentar, schickt der Server ihn innerhalb von etwa
/// einer Sekunde über die offene Verbindung; gepollt wird nicht. Die
/// Verbindung läuft ~50 s und wird dann mit der letzten Änderungsmarke neu
/// aufgebaut. Ohne Share-Link beendet der Server den Kanal (`.closed`) –
/// dann kann ohnehin niemand außer dem Besitzer schreiben; `reconnect()`
/// nach dem Schließen des Share-Dialogs öffnet ihn wieder.
///
/// merlin-server kennt keine Kommentare: dort bleibt `isAvailable` false und
/// die Oberfläche blendet alles Kommentarbezogene aus.
@MainActor
@Observable
final class CommentStore {
    /// Thread-Wurzeln (Antworten in `replies`), Reihenfolge wie vom Server.
    private(set) var threads: [Comment] = []
    /// Alle Markierungen des Artikels, auch die von Gästen.
    private(set) var highlights: [Highlight] = []
    /// true, sobald der Server Kommentare unterstützt (erster Abruf geklappt).
    private(set) var isAvailable = false
    /// Zählt jede inhaltliche Änderung hoch – Signal für den WebView, die
    /// Markierungen und Kommentar-Zähler im Text neu zu setzen.
    private(set) var revision = 0

    @ObservationIgnored private var signature = ""
    @ObservationIgnored private var articleId: Int?
    @ObservationIgnored private var streamTask: Task<Void, Never>?

    /// Sichtbare Kommentare insgesamt (gelöschte Platzhalter zählen nicht).
    var totalCount: Int {
        threads.reduce(0) { sum, thread in
            sum + (thread.deleted ? 0 : 1) + (thread.replies?.count ?? 0)
        }
    }

    /// Kommentare je Markierung (für die Zähler im Text und die Rückfrage
    /// beim Entfernen einer kommentierten Markierung).
    var countsByHighlight: [Int: Int] {
        var counts: [Int: Int] = [:]
        for thread in threads {
            guard let hid = thread.highlightId else { continue }
            counts[hid, default: 0] += (thread.deleted ? 0 : 1) + (thread.replies?.count ?? 0)
        }
        return counts
    }

    func count(forHighlight id: Int) -> Int {
        countsByHighlight[id] ?? 0
    }

    func highlight(_ id: Int) -> Highlight? {
        highlights.first { $0.id == id }
    }

    // MARK: – Verbindung

    func start(articleId: Int) {
        stop()
        if self.articleId != articleId {
            threads = []
            highlights = []
            signature = ""
            isAvailable = false
            revision += 1
        }
        self.articleId = articleId
        streamTask = Task { [weak self] in
            await self?.run(articleId: articleId)
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Nach Änderungen am Share-Link: Kanal neu öffnen (er wurde evtl. mit
    /// `.closed` beendet, weil es keinen Link gab).
    func reconnect() {
        guard let articleId else { return }
        start(articleId: articleId)
    }

    private func run(articleId: Int) async {
        var backoff = 1.0
        while !Task.isCancelled {
            if signature.isEmpty {
                do {
                    apply(try await MerlinAPI.shared.getComments(articleId))
                    isAvailable = true
                } catch {
                    if Task.isCancelled || Self.isUnsupported(error) { return }
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 30)
                    continue
                }
            }

            do {
                var closed = false
                for try await event in MerlinAPI.shared.commentStream(articleId: articleId, since: signature) {
                    switch event {
                    case .update(let payload): apply(payload)
                    case .closed:              closed = true
                    }
                }
                if closed { return }
                backoff = 1
            } catch {
                if Task.isCancelled || Self.isUnsupported(error) { return }
                // Netz weg oder App war im Hintergrund: mit wachsender Pause
                // neu verbinden; die Marke sorgt dafür, dass Verpasstes beim
                // ersten Ereignis nachkommt.
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    private static func isUnsupported(_ error: Error) -> Bool {
        if case MerlinAPIError.notFound = error { return true }
        if let e = error as? CommentAPIError, e.status == 404 { return true }
        return false
    }

    private func apply(_ payload: CommentsPayload) {
        guard payload.signature != signature else { return }
        signature = payload.signature
        threads = payload.comments
        highlights = payload.highlights
        revision += 1
    }

    /// Sofort neu laden (nach eigenen Änderungen – kommt bei offenem Kanal
    /// ohnehin, bei geschlossenem aber nicht).
    func refresh() async {
        guard let articleId,
              let payload = try? await MerlinAPI.shared.getComments(articleId) else { return }
        isAvailable = true
        apply(payload)
    }

    // MARK: – Schreiben

    func create(body: String, highlightId: Int?, parentId: Int?) async throws {
        guard let articleId else { return }
        _ = try await MerlinAPI.shared.createComment(articleId, body: body, highlightId: highlightId, parentId: parentId)
        await refresh()
    }

    func update(_ id: Int, body: String) async throws {
        _ = try await MerlinAPI.shared.updateComment(id, body: body)
        await refresh()
    }

    func delete(_ id: Int) async throws {
        try await MerlinAPI.shared.deleteComment(id)
        await refresh()
    }

    // MARK: – WebView

    /// JS-Aufruf, der Markierungen und Kommentar-Zähler im Text auf den
    /// aktuellen Stand bringt (siehe `merlinSetCommentState` in
    /// ArticleReaderView). nil, solange nichts geladen ist.
    func webViewScript() -> String? {
        guard isAvailable,
              let hData = try? JSONEncoder().encode(highlights),
              let hJSON = String(data: hData, encoding: .utf8) else { return nil }
        let counts = Dictionary(uniqueKeysWithValues: countsByHighlight.map { (String($0.key), $0.value) })
        guard let cData = try? JSONEncoder().encode(counts),
              let cJSON = String(data: cData, encoding: .utf8) else { return nil }
        return "window.merlinSetCommentState && window.merlinSetCommentState(\(hJSON), \(cJSON))"
    }
}
