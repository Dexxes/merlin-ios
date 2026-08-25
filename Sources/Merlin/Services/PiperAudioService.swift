import Foundation
import AVFoundation
import NaturalLanguage

// MARK: – PiperAudioService

/// Lädt TTS-Audio vom Merlin-Server per Streaming und spielt es progressiv ab.
///
/// Warum URLSession.bytes + AVPlayer statt URLSession.data + AVAudioPlayer?
///   URLSession.data puffert die gesamte Antwort im RAM bevor es zurückkehrt.
///   Bei einem langen Artikel (3+ Minuten Audio) = 3+ Minuten Wartezeit.
///
///   URLSession.bytes liefert einen AsyncSequence von Bytes. Wir schreiben
///   jeden 64-KB-Block sofort in eine Temp-Datei. Sobald 256 KB (≈ 32 Sekunden
///   Audio bei 64 kbps) angekommen sind, starten wir AVPlayer auf der lokalen
///   Datei. AVPlayer liest die Datei sequenziell und spielt ab, während der
///   Download im Hintergrund weiterläuft.
///
///   Für typische Artikel ist der Download 5-10× schneller als die Wiedergabe,
///   sodass der Puffer nie erschöpft wird. Ein Stall-Timer sorgt als Fallback
///   dafür, dass AVPlayer nach einem kurzen Wartestall weiter spielt.
///
/// Ablauf:
///   start() → URLSession.bytes(for:) → 64-KB-Blöcke in Temp-Datei →
///   nach 256 KB: AVPlayer(url: tempFile).play() →
///   downloadIsDone = true → stallTimer invalidieren →
///   AVPlayerItemDidPlayToEndTime → hasContent = false
@MainActor
final class PiperAudioService: NSObject, ObservableObject {

    // MARK: – Published state

    @Published var isLoading:        Bool    = false   // Wahr während Download vor Wiedergabestart
    @Published var isPlaying:        Bool    = false
    @Published var isPaused:         Bool    = false
    @Published var hasContent:       Bool    = false   // Steuert TTS-Panel-Sichtbarkeit
    @Published var currentArticleId: Int?   = nil     // Artikel der gerade abgespielt wird
    @Published var elapsed:          Double  = 0.0     // Millisekunden seit Wiedergabestart
    @Published var totalDuration:    Double? = nil     // Millisekunden
    @Published var errorMessage:     String? = nil
    @Published var downloadProgress: Double  = 0.0     // 0..1 Ladefortschritt
    @Published var loadingStep:      String  = ""      // Aktueller Schritt beim Laden

    var progress: Double {
        guard let total = totalDuration, total > 0 else { return 0 }
        return min(elapsed / total, 1.0)
    }

    // MARK: – Private

    private var player:              AVPlayer?
    private var playerItem:          AVPlayerItem?
    private var timeObserver:        Any?
    private var endObserver:         Any?
    private var stallTimer:          Timer?
    private var tempFileURL:         URL?
    private var downloadWorkTask:    Task<Void, Never>?
    private var downloadIsDone:      Bool = false
    private var isRefreshing:        Bool = false

    /// 64 KB ≈ 8 Sekunden Puffer vor Abspielbeginn (bei 64 kbps).
    /// Der Piper-Server synthetisiert ca. 5–10× Echtzeit, d.h. der Download
    /// ist bei Abspielbeginn immer weit voraus – ein kleinerer Puffer reicht völlig.
    private let playbackThreshold: Int64 = 64_768

    // MARK: – Public API

    func start(articleId: Int, lang: String, estimatedSeconds: Double? = nil) {
        stopInternal()
        hasContent       = true
        currentArticleId = articleId
        isLoading        = true
        errorMessage     = nil
        elapsed          = 0
        downloadProgress = 0
        totalDuration    = estimatedSeconds.map { $0 * 1000 }
        downloadIsDone   = false
        loadingStep      = "Reintext wird aufbereitet …"

        // Auth-Header hier auf dem MainActor lesen, bevor der detached Task startet.
        let authHeader = CredentialsStore.shared.basicAuthHeader ?? ""

        // Task.detached: Download-Loop läuft auf dem cooperative Thread Pool,
        // nicht auf dem MainActor. UI-Updates in doStart() erfolgen explizit
        // per await MainActor.run { }.
        downloadWorkTask = Task.detached { [weak self] in
            await self?.doStart(articleId: articleId, lang: lang, authHeader: authHeader)
        }
    }

    func togglePlayPause() {
        if isPlaying { pause() } else if isPaused { resume() }
    }

    func pause() {
        guard isPlaying else { return }
        player?.pause()
        stallTimer?.invalidate()
        isPlaying = false
        isPaused  = true
    }

    func resume() {
        guard isPaused else { return }
        player?.play()
        if !downloadIsDone { startStallTimer() }
        isPlaying = true
        isPaused  = false
    }

    func stop() {
        stopInternal()
        hasContent       = false
        currentArticleId = nil
    }

    // MARK: – Spracherkennung

    static func detectLanguage(text: String) -> String {
        let supported = ["de", "en", "es", "fr", "it"]
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(500)))
        if let lang = recognizer.dominantLanguage?.rawValue {
            let prefix = String(lang.prefix(2)).lowercased()
            if supported.contains(prefix) { return prefix }
        }
        if let sys = Locale.preferredLanguages.first {
            let prefix = String(sys.prefix(2)).lowercased()
            if supported.contains(prefix) { return prefix }
        }
        return "de"
    }

    // MARK: – Private: Stopp

    private func stopInternal() {
        downloadWorkTask?.cancel()
        downloadWorkTask = nil

        stallTimer?.invalidate()
        stallTimer = nil

        if let obs = timeObserver {
            player?.removeTimeObserver(obs)
            timeObserver = nil
        }

        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }

        player?.pause()
        player     = nil
        playerItem = nil

        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }

        isLoading        = false
        isPlaying        = false
        isPaused         = false
        elapsed          = 0
        downloadProgress = 0
        downloadIsDone   = false
        isRefreshing     = false
        loadingStep      = ""
    }

    // MARK: – Private: Download + progressives Abspielen

    // nonisolated: läuft auf dem cooperative Thread Pool, nicht auf dem MainActor.
    // Alle Schreibzugriffe auf @Published-Properties und MainActor-only-Objekte
    // (stallTimer, player, …) erfolgen explizit per await MainActor.run { }.
    private nonisolated func doStart(articleId: Int, lang: String, authHeader: String) async {

        // ── 1. Stream-URL aufbauen ────────────────────────────────────────────
        let streamUrl: URL
        do {
            // ttsStreamURL ist nonisolated → kein unnötiger Actor-Hop
            streamUrl = try MerlinAPI.shared.ttsStreamURL(articleId: articleId, lang: lang)
        } catch {
            await MainActor.run {
                self.isLoading    = false
                self.errorMessage = "Nextcloud nicht konfiguriert. Bitte zuerst einloggen."
            }
            return
        }

        guard !authHeader.isEmpty else {
            await MainActor.run {
                self.isLoading    = false
                self.errorMessage = "Anmeldedaten fehlen."
            }
            return
        }

        await MainActor.run { self.loadingStep = "Text wird an Sprachmodell gesendet …" }

        // ── 2. AVAudioSession ─────────────────────────────────────────────────
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            await MainActor.run {
                self.isLoading    = false
                self.errorMessage = "Audio-Session-Fehler: \(error.localizedDescription)"
            }
            return
        }

        // ── 3. Leere Temp-Datei anlegen ───────────────────────────────────────
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("merlin-tts-\(UUID().uuidString).mp3")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        await MainActor.run { self.tempFileURL = tempURL }

        guard let fh = try? FileHandle(forWritingTo: tempURL) else {
            await MainActor.run {
                self.isLoading    = false
                self.errorMessage = "Temp-Datei konnte nicht geöffnet werden."
            }
            return
        }

        // ── 4. HTTP-Request ───────────────────────────────────────────────────
        var request = URLRequest(url: streamUrl, timeoutInterval: 3600)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        guard !Task.isCancelled else { fh.closeFile(); return }

        let asyncBytes: URLSession.AsyncBytes
        let response:   URLResponse
        do {
            (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            fh.closeFile()
            if (error as NSError).code == NSURLErrorCancelled { return }
            await MainActor.run {
                self.isLoading    = false
                self.errorMessage = "Download-Fehler: \(error.localizedDescription)"
            }
            return
        }

        guard !Task.isCancelled else { fh.closeFile(); return }

        // ── 5. HTTP-Status prüfen ─────────────────────────────────────────────
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            fh.closeFile()
            await MainActor.run {
                self.isLoading    = false
                self.errorMessage = "Server-Fehler: HTTP \(http.statusCode)"
            }
            return
        }

        let expectedBytes = (response as? HTTPURLResponse)?.expectedContentLength ?? -1

        // ── 6. Bytes in Temp-Datei streamen; nach Schwellwert Wiedergabe starten
        //
        // Läuft vollständig off-MainActor: fh.write() und buf.append() blockieren
        // nie den UI-Thread. MainActor.run wird nur für UI-Updates aufgerufen
        // (einmal pro 8-KB-Chunk, damit AVPlayer die Daten möglichst früh sieht).
        //
        // Warum 8 KB statt 64 KB?
        //   Der Daemon liefert 8-KB-Chunks (ffmpeg.stdout.read(8192)).
        //   Mit 64-KB-Flush lag der Threshold-Check (32 KB) immer innerhalb
        //   des ersten Flush-Blocks → Wiedergabe startete erst nach 64 KB (≈ 8 s)
        //   statt nach 32 KB (≈ 4 s). Mit 8-KB-Flush greift der Threshold korrekt.
        var totalReceived:     Int64 = 0
        var playbackStarted          = false
        var firstChunkReceived       = false
        var downloadStartedAt        = Date()
        var buf                      = Data(capacity: 8_192)

        func flush() {
            guard !buf.isEmpty else { return }
            fh.write(buf)
            totalReceived += Int64(buf.count)
            buf.removeAll(keepingCapacity: true)
        }

        do {
            for try await byte in asyncBytes {
                guard !Task.isCancelled else { break }
                buf.append(byte)

                if buf.count >= 8_192 {
                    flush()

                    // Beim ersten Chunk: Schritt "Audio wird generiert" anzeigen
                    if !firstChunkReceived {
                        firstChunkReceived  = true
                        downloadStartedAt   = Date()
                        await MainActor.run { self.loadingStep = "Audio wird generiert …" }
                    }

                    // Download-Rate (KB/s) alle 32 KB loggen
                    if totalReceived % 32_768 == 0 {
                        let secs = max(Date().timeIntervalSince(downloadStartedAt), 0.001)
                        let kbps = Double(totalReceived) / secs / 1024
                        print("[PiperAudio] Download: \(totalReceived / 1024) KB, \(String(format: "%.0f", kbps)) KB/s")
                    }

                    // Ladefortschritt (nur wenn Content-Length bekannt)
                    if expectedBytes > 0 {
                        let progress = min(Double(totalReceived) / Double(expectedBytes), 0.99)
                        await MainActor.run { self.downloadProgress = progress }
                    }

                    // Wiedergabe starten sobald genug Puffer da ist
                    if !playbackStarted && totalReceived >= playbackThreshold {
                        playbackStarted = true
                        let secs = max(Date().timeIntervalSince(downloadStartedAt), 0.001)
                        print("[PiperAudio] Playback start nach \(String(format: "%.1f", secs)) s, \(totalReceived / 1024) KB empfangen")
                        await MainActor.run { self.beginPlayback(url: tempURL) }
                    }
                }
            }
        } catch {
            // Netzwerkfehler oder Task-Abbruch – mit vorhandenen Daten weitermachen
        }

        flush()
        fh.closeFile()

        guard !Task.isCancelled else { return }

        await MainActor.run {
            self.downloadIsDone   = true
            self.downloadProgress = 1.0
            self.stallTimer?.invalidate()
            self.stallTimer = nil
            // Exakte Dauer aus tatsächlich empfangenen Bytes: 64 kbps → 8 Bytes/ms
            self.totalDuration = Double(totalReceived) / 8.0

            // Artikel war kürzer als der Puffer → jetzt starten
            if !playbackStarted && totalReceived > 0 {
                self.beginPlayback(url: tempURL)
            }
        }
    }

    // MARK: – AVPlayer starten

    private func beginPlayback(url: URL) {
        let item   = AVPlayerItem(url: url)
        playerItem = item

        let avp = AVPlayer(playerItem: item)
        player  = avp

        // Fortschritts-Observer (0,25-Sekunden-Takt)
        // Closure läuft auf queue: .main → assumeIsolated teilt das dem Compiler mit.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = avp.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.elapsed = time.seconds * 1000   // → Millisekunden
            }
        }

        // Ende der Wiedergabe
        // queue: .main → assumeIsolated
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue:  .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.downloadIsDone {
                    // Download fertig + Wiedergabe fertig → Panel schließen
                    self.isPlaying  = false
                    self.isPaused   = false
                    self.hasContent = false
                } else if !self.isRefreshing {
                    // AVPlayer hat das zum Startzeitpunkt bekannte Dateiende
                    // erreicht, der Download läuft aber noch. AVPlayerItem neu
                    // erstellen damit AVPlayer die gewachsene Datei neu einliest
                    // und ab der aktuellen Position fortsetzt.
                    // isRefreshing-Guard: verhindert kaskadierende Aufrufe falls
                    // AVPlayerItemDidPlayToEndTime mehrfach hintereinander feuert.
                    self.refreshPlayerItem(resumeAt: self.elapsed)
                }
            }
        }

        isLoading = false
        isPlaying = true
        avp.play()

        // Stall-Recovery: Wenn AVPlayer auf weitere Bytes wartet, periodisch
        // .play() aufrufen damit er die neu geschriebenen Bytes aufgreift.
        if !downloadIsDone {
            startStallTimer()
        }
    }

    // MARK: – Nachladen bei wachsender Datei

    /// Erstellt das AVPlayerItem neu, damit AVPlayer die seit dem letzten
    /// beginPlayback()-Aufruf neu geschriebenen Bytes sieht, und setzt die
    /// Wiedergabe nahtlos ab `ms` (Millisekunden) fort.
    ///
    /// Warum replaceCurrentItem statt play()?
    ///   AVPlayer liest die Dateigröße beim Öffnen ein und behandelt die
    ///   Datei als statisch. Ein einfaches play() nach AVPlayerItemDidPlayToEndTime
    ///   startet die Wiedergabe nicht neu — der Player glaubt, er sei am Ende.
    ///   replaceCurrentItem zwingt AVPlayer, die Datei mit der aktuellen Größe
    ///   neu zu öffnen und die zwischenzeitlich geschriebenen Bytes zu sehen.
    private func refreshPlayerItem(resumeAt ms: Double) {
        // Doppelter Schutz gegen Race Conditions:
        // 1. isRefreshing: verhindert parallele Aufrufe falls AVPlayerItemDidPlayToEndTime
        //    mehrfach feuert bevor der Seek abgeschlossen ist (häufig wenn der Download
        //    gerade endet und das neue Item sofort wieder das Ende erreicht).
        // 2. downloadIsDone: falls der Download im Moment zwischen dem Feuern des
        //    endObserver-Callbacks und diesem Aufruf abgeschlossen wurde.
        guard !isRefreshing, !downloadIsDone else { return }
        guard let url = tempFileURL, let avp = player else { return }

        isRefreshing = true

        // Exakte Wiedergabeposition VOR replaceCurrentItem sichern.
        // Nach replaceCurrentItem setzt AVPlayer currentTime() auf 0 zurück —
        // deshalb MUSS der Capture hier am Anfang erfolgen, bevor das Item
        // ausgetauscht wird. self.elapsed (0,25-s-Timer) kann bis zu 250 ms
        // hinter der echten Position liegen; avp.currentTime() ist exakt.
        let captured   = avp.currentTime()
        let resumeTime = captured.isNumeric
            ? captured
            : CMTime(seconds: max(0, ms / 1000), preferredTimescale: 600)

        // Alten End-Observer entfernen — er ist an das alte Item gebunden
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }

        let newItem = AVPlayerItem(url: url)
        playerItem  = newItem

        // End-Observer auf das neue Item registrieren
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newItem,
            queue:  .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.downloadIsDone {
                    self.isPlaying  = false
                    self.isPaused   = false
                    self.hasContent = false
                } else if !self.isRefreshing {
                    self.refreshPlayerItem(resumeAt: self.elapsed)
                }
            }
        }

        avp.replaceCurrentItem(with: newItem)

        // Exaktes Seeking mit toleranceBefore/After: .zero erzwingen.
        // Der Standard-seek(to:) darf laut AVFoundation-Doku mit einer
        // positiven toleranceAfter überspringen — konkret bis zur nächsten
        // MP3-Frame-Grenze (~26 ms). Das reicht, um hörbar Wörter zu
        // überspringen. Mit .zero sucht AVPlayer den exakten Frame.
        //
        // Zusätzlich 80 ms zurücksetzen: Bei CBR-MP3 endet AVPlayer immer
        // am Ende eines vollständig decodierten Frames. Das neue Item startet
        // am selben Frame-Anfang — ein kleiner Overlap ist unhörbar,
        // ein Skip hingegen klar wahrnehmbar.
        let safeResume = CMTimeSubtract(resumeTime,
                                        CMTime(seconds: 0.08, preferredTimescale: 600))
        let finalResume = CMTimeMaximum(safeResume, .zero)

        avp.seek(to: finalResume,
                 toleranceBefore: .zero,
                 toleranceAfter:  .zero) { [weak self] finished in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRefreshing = false
                guard self.isPlaying else { return }

                if finished {
                    self.player?.play()
                } else {
                    // Seek wurde abgebrochen – passiert wenn replaceCurrentItem
                    // während eines laufenden Seeks erneut aufgerufen wird, oder
                    // wenn das Item die Zielposition (noch) nicht kennt.
                    // Fallback: Standard-seek mit lockerer Toleranz, um sicherzustellen
                    // dass wir nicht auf Position 0 landen.
                    print("[PiperAudio] Seek abgebrochen, Fallback-Seek zu \(finalResume.seconds) s")
                    self.player?.seek(to: finalResume) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self, self.isPlaying else { return }
                            self.player?.play()
                        }
                    }
                }
            }
        }
    }

    /// Alle 2 Sekunden prüfen ob AVPlayer pausiert ist obwohl wir spielen wollen.
    /// Passiert wenn AVPlayer die Grenze der bisher heruntergeladenen Bytes erreicht.
    private func startStallTimer() {
        stallTimer?.invalidate()
        // Timer feuert immer auf dem Main Runloop → assumeIsolated.
        // 'timer'-Parameter wird auf '_' gesetzt, da Timer kein Sendable ist
        // und nicht in die assumeIsolated-Closure übergeben werden darf.
        // Invalidierung läuft stattdessen über self.stallTimer.
        stallTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                // Timer nicht mehr nötig sobald Download fertig
                if self.downloadIsDone {
                    self.stallTimer?.invalidate()
                    self.stallTimer = nil
                    return
                }

                // Wenn wir spielen wollen, AVPlayer aber pausiert → resume
                if self.isPlaying,
                   let p = self.player,
                   p.timeControlStatus == .paused {
                    let posMs = Int(self.elapsed)
                    let bufMs = Int((self.totalDuration ?? 0))
                    print("[PiperAudio] Stall bei \(posMs) ms (Buffer bis \(bufMs) ms) – play() erneut")
                    p.play()
                }
            }
        }
    }
}
