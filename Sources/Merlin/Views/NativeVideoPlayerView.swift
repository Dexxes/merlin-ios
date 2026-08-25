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

    @AppStorage("merlin_developer_mode") private var developerMode: Bool = false

    @State private var variants: [MerlinAPI.VideoStreamVariant] = []
    @State private var selectedIndex = 0
    @State private var player: AVPlayer?
    /// Nur für den Dev-Mode-Dialog unten — es gibt hier kein Xcode-Konsolenfenster, da
    /// dieses Repo mit xtool statt Xcode gebaut wird (`swift build`/auf dem Gerät ohne
    /// angeschlossenen Debugger). Ein stiller Fehlschlag (Netzwerk, 404 weil das Backend
    /// den Endpunkt noch nicht kennt, Decoding) sah für den Nutzer sonst identisch zu
    /// "kein Stream verfügbar" aus und war so nicht diagnostizierbar. Ein Alert statt eines
    /// Inline-Labels, weil Letzteres schon einmal unbemerkt geblieben ist.
    @State private var debugFailure: String?

    var body: some View {
        Group {
            if !variants.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if let player {
                        VideoPlayer(player: player)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
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
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .onChange(of: selectedIndex) { _, newIndex in
                    loadPlayer(for: variants[newIndex])
                }
            }
        }
        .task(id: articleId) {
            await load()
        }
        .alert("NativeVideo Debug", isPresented: Binding(
            get: { developerMode && debugFailure != nil },
            set: { if !$0 { debugFailure = nil } }
        )) {
            Button(L("common.ok")) { debugFailure = nil }
        } message: {
            Text(debugFailure ?? "")
        }
    }

    private func load() async {
        variants = []
        player = nil
        debugFailure = nil

        do {
            let response = try await MerlinAPI.shared.getVideoStream(articleId: articleId)
            guard response.available,
                  let responseVariants = response.variants, !responseVariants.isEmpty
            else {
                debugFailure = "video-stream: available=\(response.available), variants=\(response.variants?.count ?? 0)"
                return
            }

            variants = responseVariants
            selectedIndex = min(max(response.defaultIndex ?? 0, 0), responseVariants.count - 1)
            loadPlayer(for: responseVariants[selectedIndex])
        } catch {
            debugFailure = "video-stream fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func loadPlayer(for variant: MerlinAPI.VideoStreamVariant) {
        guard let url = URL(string: variant.url) else { return }
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)

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
