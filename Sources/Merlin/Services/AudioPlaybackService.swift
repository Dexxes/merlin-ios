import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// Spielt die Audio-Quelle eines Artikels (Datei oder HLS, siehe `MediaMarker`) ab. Läuft
/// unabhängig vom Reader weiter (Hintergrund-Audio, Sperrbildschirm, Mini-Player in der Liste).
///
/// Eine Instanz gehört `ArticleListView` (wie `PiperAudioService`) und wird an den Reader
/// durchgereicht. Position pro Artikel und Tempo werden in `PreferencesStore` gemerkt.
@MainActor
final class AudioPlaybackService: NSObject, ObservableObject {

    static let skipBackSeconds: Double = 15
    static let skipForwardSeconds: Double = 30
    static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    // MARK: – Published state

    @Published private(set) var currentArticleId: Int?
    @Published private(set) var title:       String = ""
    @Published private(set) var siteName:    String = ""
    @Published private(set) var coverURL:    URL?
    @Published private(set) var isPlaying:   Bool   = false
    @Published private(set) var isBuffering: Bool   = false
    /// Sekunden seit Anfang.
    @Published private(set) var elapsed:     Double = 0
    /// Sekunden; 0, solange unbekannt (z. B. HLS-Live oder noch nicht geladen).
    @Published private(set) var duration:    Double = 0
    @Published private(set) var rate:        Float  = PreferencesStore.shared.audioRate
    @Published private(set) var variants:    [AudioSource.Variant] = []
    @Published private(set) var selectedVariant = 0
    @Published private(set) var errorMessage: String?

    /// true, sobald ein Artikel geladen ist (Player-Zustand ≠ leer) - steuert den Mini-Player.
    var hasContent: Bool { currentArticleId != nil }

    /// 0…1 für Fortschrittsbalken; 0, solange die Dauer unbekannt ist.
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    // MARK: – Private

    private var player:        AVPlayer?
    private var timeObserver:  Any?
    private var itemStatusObs: NSKeyValueObservation?
    private var itemDurationObs: NSKeyValueObservation?
    private var controlStatusObs: NSKeyValueObservation?
    private var endObserver:   NSObjectProtocol?
    private var notificationObservers: [NSObjectProtocol] = []
    private var lastPersistedAt: Double = 0
    private var pendingSeek: Double?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var wantsToPlay = false

    override init() {
        super.init()
        registerSessionObservers()
        registerRemoteCommands()
    }

    // MARK: – Public API

    /// Lädt den Artikel (falls nicht schon geladen) und startet auf Wunsch die Wiedergabe.
    /// Ein bereits geladener Artikel wird nicht neu geladen - Wiedergabe läuft dann einfach weiter.
    func load(article: Article, source: AudioSource, coverURL: URL?, play: Bool) {
        if currentArticleId == article.id, player != nil {
            if play { self.play() }
            return
        }

        stop()
        currentArticleId = article.id
        title            = article.displayTitle
        siteName         = article.displaySiteName
        self.coverURL    = coverURL
        variants         = source.variants
        selectedVariant  = source.defaultIndex
        errorMessage     = nil
        elapsed          = PreferencesStore.shared.savedAudioPosition(for: article.id)
        duration         = 0
        nowPlayingArtwork = Self.artwork(for: coverURL)

        startPlayer(url: source.variants[source.defaultIndex].url, resumeAt: elapsed, play: play)
    }

    func play() {
        guard let player else { return }
        activateSession()
        wantsToPlay = true
        player.defaultRate = rate
        player.play()
        player.rate = rate
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        wantsToPlay = false
        player?.pause()
        isPlaying = false
        persistPosition()
        updateNowPlaying()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func skip(by seconds: Double) {
        seek(to: elapsed + seconds)
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        var target = max(0, seconds)
        if duration > 0 { target = min(target, duration) }
        elapsed = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        persistPosition()
        updateNowPlaying()
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        PreferencesStore.shared.audioRate = newRate
        player?.defaultRate = newRate
        if isPlaying { player?.rate = newRate }
        updateNowPlaying()
    }

    func selectVariant(_ index: Int) {
        guard variants.indices.contains(index), index != selectedVariant else { return }
        selectedVariant = index
        let resumeAt = elapsed
        let shouldPlay = isPlaying || wantsToPlay
        teardownPlayer()
        startPlayer(url: variants[index].url, resumeAt: resumeAt, play: shouldPlay)
    }

    func stop() {
        persistPosition()
        teardownPlayer()
        currentArticleId = nil
        title = ""
        siteName = ""
        coverURL = nil
        isPlaying = false
        isBuffering = false
        elapsed = 0
        duration = 0
        variants = []
        selectedVariant = 0
        errorMessage = nil
        wantsToPlay = false
        nowPlayingArtwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: – Player lifecycle

    private func startPlayer(url: URL, resumeAt: Double, play shouldPlay: Bool) {
        let item = AVPlayerItem(url: url)
        // Sprache: Tonhöhe bei geändertem Tempo beibehalten.
        item.audioTimePitchAlgorithm = .timeDomain
        let avp = AVPlayer(playerItem: item)
        avp.defaultRate = rate
        player = avp
        pendingSeek = resumeAt > 1 ? resumeAt : nil
        isBuffering = true

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = avp.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.handleTick(seconds) }
        }

        itemStatusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in self?.handleItemStatus(status, message: message) }
        }
        itemDurationObs = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            let seconds = item.duration.seconds
            Task { @MainActor in self?.handleDuration(seconds) }
        }
        controlStatusObs = avp.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.handleControlStatus(status) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnded() }
        }

        if shouldPlay { play() } else { updateNowPlaying() }
    }

    private func teardownPlayer() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemStatusObs = nil
        itemDurationObs = nil
        controlStatusObs = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        pendingSeek = nil
    }

    // MARK: – Player callbacks

    private func handleTick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        elapsed = seconds
        // Alle ~5 s die Position sichern, damit sie auch bei App-Kill erhalten bleibt.
        if abs(seconds - lastPersistedAt) >= 5 {
            persistPosition()
        }
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status, message: String?) {
        switch status {
        case .readyToPlay:
            errorMessage = nil
            if let seekTo = pendingSeek {
                pendingSeek = nil
                player?.seek(to: CMTime(seconds: seekTo, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero)
            }
            updateNowPlaying()
        case .failed:
            errorMessage = message ?? L("audioPlayer.error.generic")
            isBuffering = false
            isPlaying = false
            wantsToPlay = false
            updateNowPlaying()
        default:
            break
        }
    }

    private func handleDuration(_ seconds: Double) {
        duration = seconds.isFinite && seconds > 0 ? seconds : 0
        updateNowPlaying()
    }

    private func handleControlStatus(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            isBuffering = false
            isPlaying = true
        case .waitingToPlayAtSpecifiedRate:
            isBuffering = wantsToPlay
        case .paused:
            isBuffering = false
            // Vom System pausiert (z. B. Siri, Steuerzentrale): Zustand übernehmen.
            if isPlaying {
                isPlaying = false
                wantsToPlay = false
            }
        @unknown default:
            break
        }
        updateNowPlaying()
    }

    private func handleEnded() {
        wantsToPlay = false
        isPlaying = false
        elapsed = 0
        PreferencesStore.shared.saveAudioPosition(0, for: currentArticleId ?? 0)
        player?.seek(to: .zero)
        updateNowPlaying()
    }

    private func persistPosition() {
        guard let id = currentArticleId else { return }
        lastPersistedAt = elapsed
        // Fast am Ende → beim nächsten Mal von vorn.
        let nearEnd = duration > 0 && elapsed > duration - 5
        PreferencesStore.shared.saveAudioPosition(nearEnd ? 0 : elapsed, for: id)
    }

    // MARK: – Audio session

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    private func registerSessionObservers() {
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(typeRaw: typeRaw, optionRaw: optionRaw) }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.handleRouteChange(reasonRaw: reasonRaw) }
        })
    }

    private func handleInterruption(typeRaw: UInt?, optionRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            if isPlaying { pause() }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw ?? 0)
            if options.contains(.shouldResume), player != nil { play() }
        @unknown default:
            break
        }
    }

    /// Kopfhörer abgezogen → pausieren (iOS-Konvention).
    private func handleRouteChange(reasonRaw: UInt?) {
        guard let reasonRaw, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw),
              reason == .oldDeviceUnavailable, isPlaying else { return }
        pause()
    }

    // MARK: – Now Playing / Remote commands

    private static func artwork(for url: URL?) -> MPMediaItemArtwork? {
        guard let url, let local = ImageCacheService.shared.localURL(for: url),
              let data = try? Data(contentsOf: local), let image = UIImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func updateNowPlaying() {
        guard currentArticleId != nil else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: siteName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func registerRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBackSeconds)]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -Self.skipBackSeconds) }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForwardSeconds)]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: Self.skipForwardSeconds) }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
        c.changePlaybackRateCommand.supportedPlaybackRates = Self.rates.map { NSNumber(value: $0) }
        c.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let newRate = event.playbackRate
            Task { @MainActor in self?.setRate(newRate) }
            return .success
        }
    }
}
