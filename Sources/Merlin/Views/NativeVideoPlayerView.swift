import SwiftUI
import AVKit

// MARK: – Host detection (mirrors VideoPlayer.vue's NATIVE_VIDEO_HOSTS/hasNativeVideoHost())

/// ARD-, ZDF- und Arte-Mediathek-Artikel können vom Server (siehe
/// `VideoStreamResolverService` in merlin-nextcloud/merlin-server) in eine direkt abspielbare
/// HLS-Stream-URL aufgelöst werden. Dieser Host-Check entscheidet, ob es sich überhaupt lohnt,
/// den `/video-stream`-Endpunkt für einen Artikel anzufragen.
enum NativeVideoHost {
    private static let hosts = ["ardmediathek.de", "zdf.de", "arte.tv"]

    static func matches(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}

// MARK: – Native player card (embedded inline in ArticleReaderView, above the article content)

/// Lädt und spielt den nativen ARD/ZDF/Arte-Stream für einen Artikel ab. Fragt den
/// `/video-stream`-Endpunkt nur einmal pro Artikel ab (`.task(id: articleId)`) und blendet sich
/// selbst aus, wenn kein Stream verfügbar ist (z. B. Sendung nicht mehr online) — analog zu
/// `VideoPlayer.vue`, das bei `available == false` ebenfalls nichts rendert.
struct NativeVideoPlayerCard: View {
    let articleId: Int
    /// Artikel-Titelbild - dient als Player-Cover (wie das `poster`-Attribut bei HTML5-Video),
    /// bis der Nutzer auf Play tippt, statt sofort einen schwarzen Player-Rahmen zu zeigen.
    let posterURL: URL?

    /// Diagnose-Ausgabe für den `/video-stream`-Ladezustand - nur bei Developer Mode sichtbar
    /// (siehe Settings → Entwickler). War zeitweise unconditional, um zu beweisen, dass diese
    /// View überhaupt gemountet wird; jetzt bestätigt, also wieder hinter dem Toggle.
    @AppStorage("merlin_developer_mode") private var developerMode: Bool = false

    private enum LoadPhase {
        case idle, loading, failed(String), ok(Int)
    }

    @State private var variants: [MerlinAPI.VideoStreamVariant] = []
    @State private var selectedIndex = 0
    @State private var player: AVPlayer?
    @State private var phase: LoadPhase = .idle
    @State private var showCover = true
    @State private var isFullScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if developerMode {
                Text("NativeVideoPlayerCard aktiv (Artikel \(articleId))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)
                phaseText
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.orange)
            }

            if !variants.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if let player {
                        ZStack(alignment: .topTrailing) {
                            VideoPlayer(player: player)
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .frame(maxWidth: .infinity)

                            if showCover, let posterURL {
                                CachedAsyncImage(url: posterURL) { image in
                                    image.aspectRatio(16.0 / 9.0, contentMode: .fill)
                                } placeholder: {
                                    Color.black
                                }
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .overlay {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 54))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 6)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    showCover = false
                                    player.play()
                                }
                            } else {
                                // Vollbild-Umschalter erst sichtbar, sobald die Wiedergabe
                                // begonnen hat - auf dem Cover würde er nur den Play-Tap stören.
                                Button {
                                    isFullScreen = true
                                } label: {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(8)
                                        .background(.black.opacity(0.45), in: Circle())
                                }
                                .padding(8)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if variants.count > 1 {
                        Picker(L("articleReader.video.variant"), selection: $selectedIndex) {
                            ForEach(Array(variants.enumerated()), id: \.offset) { idx, variant in
                                Text(variant.label).tag(idx)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                .padding(.top, 4)
                .onChange(of: selectedIndex) { _, newIndex in
                    loadPlayer(for: variants[newIndex])
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .task(id: articleId) {
            await load()
        }
        .fullScreenCover(isPresented: $isFullScreen) {
            if let player {
                NativeVideoFullScreenView(player: player) { isFullScreen = false }
            }
        }
    }

    @ViewBuilder
    private var phaseText: some View {
        switch phase {
        case .idle:                Text("Phase: idle (task noch nicht gestartet)")
        case .loading:              Text("Phase: lädt /video-stream …")
        case .failed(let message): Text("Phase: fehlgeschlagen – \(message)")
        case .ok(let count):       Text("Phase: ok – \(count) Variante(n)")
        }
    }

    private func load() async {
        phase = .loading
        variants = []
        player = nil

        do {
            let response = try await MerlinAPI.shared.getVideoStream(articleId: articleId)
            guard response.available,
                  let responseVariants = response.variants, !responseVariants.isEmpty
            else {
                phase = .failed("available=\(response.available), variants=\(response.variants?.count ?? 0)")
                return
            }

            variants = responseVariants
            selectedIndex = min(max(response.defaultIndex ?? 0, 0), responseVariants.count - 1)
            phase = .ok(responseVariants.count)
            loadPlayer(for: responseVariants[selectedIndex])
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadPlayer(for variant: MerlinAPI.VideoStreamVariant) {
        guard let url = URL(string: variant.url) else { return }
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        showCover = true

        // Arte liefert mehrsprachige Untertitelspuren im selben Manifest — ohne explizite
        // Auswahl spielt AVPlayer die erste Spur, die selten zur Sprachfassung passt (siehe
        // hls.js-Handling in VideoPlayer.vue, das dieselbe Spur erzwingt).
        guard let subtitleLanguage = variant.subtitleLanguage else { return }
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            let locale = Locale(identifier: subtitleLanguage)
            let matches = AVMediaSelectionGroup.mediaSelectionOptions(from: group.options, with: locale)
            if let option = matches.first {
                item.select(option, in: group)
            }
        }
    }
}

// MARK: – Fullscreen presentation

/// Vollbild-Ansicht für den nativen ARD/ZDF/Arte-Player - denselben `AVPlayer` weiterreichen
/// statt einen zweiten zu erzeugen, damit Wiedergabeposition und -status beim Auf-/Zuklappen
/// erhalten bleiben. Stil (Close-Button oben rechts, schwarzer Hintergrund) folgt bewusst
/// `YouTubePlayerView`, damit sich beide Vollbild-Player im Reader identisch anfühlen.
private struct NativeVideoFullScreenView: View {
    let player: AVPlayer
    let onDismiss: () -> Void

    @State private var controlsVisible = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

            if controlsVisible {
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.white.opacity(0.25))
                        .shadow(color: .black.opacity(0.4), radius: 4)
                }
                .padding(.top, 56)
                .padding(.trailing, 20)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        // Der eigene Close-Button ist ein SwiftUI-Overlay über dem AVKit-Player und
        // bekommt dessen Ein-/Ausblenden der Bedienelemente per Tap nicht mit (AVKit
        // bietet dafür keine öffentliche API). Ein Tap auf den Player toggelt daher
        // zusätzlich unseren Button, exakt wie AVKit die eigenen Bedienelemente togglet
        // - kein Timer, kein Auto-Hide.
        .simultaneousGesture(TapGesture().onEnded { controlsVisible.toggle() })
    }
}
