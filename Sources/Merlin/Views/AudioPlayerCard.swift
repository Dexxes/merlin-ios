import AVKit
import SwiftUI

// MARK: – Zeitformat

enum AudioTime {
    /// „3:07“ bzw. „1:03:07“.
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: – AirPlay

/// System-Routenwahl (AirPlay/Bluetooth) als SwiftUI-View.
struct AirPlayRoutePicker: UIViewRepresentable {
    var tint: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tint
        view.activeTintColor = tint
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tint
    }
}

// MARK: – Player card (Ersatz für das Hero Image bei Audio-Artikeln)

/// Audio-Player im Artikel-Header: das Titelbild dient als Cover, die Bedienung liegt als
/// Overlay darüber. Darunter folgen Bildunterschrift auf der Akzentfläche und die Tonstufen
/// (dasselbe Plakat-Layout, das sonst das WebView-CSS für das Hero Image zeichnet).
///
/// Solange der Artikel nicht der aktuell geladene ist, zeigt die Karte nur Cover + Play - ein
/// bereits laufendes Audio eines anderen Artikels wird durch das bloße Öffnen nicht unterbrochen.
struct AudioPlayerCard: View {
    @ObservedObject var audio: AudioPlaybackService
    let article: Article
    let source: AudioSource
    let coverURL: URL?
    let caption: String?
    let accent: Color
    let onAccent: Color
    let design: Font.Design
    let steps: [(height: CGFloat, color: Color)]

    @State private var scrubFraction: Double?

    private var isActive: Bool { audio.currentArticleId == article.id }
    private var savedPosition: Double { PreferencesStore.shared.savedAudioPosition(for: article.id) }

    var body: some View {
        VStack(spacing: 0) {
            cover

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11, weight: .bold, design: design))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(onAccent)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                    .background(accent)
            }

            ForEach(steps.indices, id: \.self) { i in
                Rectangle().fill(steps[i].color).frame(height: steps[i].height)
            }
            Color.clear.frame(height: 16)
        }
    }

    // MARK: Cover + Overlay

    private var cover: some View {
        Color.clear
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                ZStack {
                    accent
                    if let coverURL {
                        CachedAsyncImage(url: coverURL) { image in
                            image.scaledToFill()
                        } placeholder: {
                            accent
                        }
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(onAccent.opacity(0.6))
                    }
                }
            }
            .clipped()
            .overlay(alignment: .bottom) {
                Group {
                    if isActive { controls } else { idleOverlay }
                }
            }
    }

    private var idleOverlay: some View {
        Button {
            audio.load(article: article, source: source, coverURL: coverURL, play: true)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.black.opacity(0.55), in: Circle())
                if savedPosition > 1 {
                    Text(String(format: L("audioPlayer.resumeAt"), AudioTime.format(savedPosition)))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("audioPlayer.play"))
    }

    private var controls: some View {
        VStack(spacing: 6) {
            if let message = audio.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            scrubber
            timeRow
            transportRow
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .padding(.top, 48)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: Scrubber

    private var displayFraction: Double { scrubFraction ?? audio.progress }

    private var scrubber: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: 4)
                Capsule().fill(.white).frame(width: width * displayFraction, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: scrubFraction == nil ? 12 : 18, height: scrubFraction == nil ? 12 : 18)
                    .offset(x: min(max(width * displayFraction - 6, 0), width - 12))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubFraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { value in
                        let fraction = min(max(value.location.x / width, 0), 1)
                        scrubFraction = nil
                        audio.seek(to: fraction * audio.duration)
                    }
            )
        }
        .frame(height: 22)
        .disabled(audio.duration <= 0)
        .accessibilityElement()
        .accessibilityLabel(L("audioPlayer.position"))
        .accessibilityValue(AudioTime.format(audio.elapsed))
    }

    private var timeRow: some View {
        let shownElapsed = scrubFraction.map { $0 * audio.duration } ?? audio.elapsed
        return HStack {
            Text(AudioTime.format(shownElapsed))
            Spacer()
            if audio.duration > 0 {
                Text("-" + AudioTime.format(max(audio.duration - shownElapsed, 0)))
            }
        }
        .font(.system(size: 11, weight: .medium, design: design).monospacedDigit())
        .foregroundStyle(.white.opacity(0.85))
    }

    // MARK: Transport

    private var transportRow: some View {
        HStack(spacing: 0) {
            rateMenu
                .frame(width: 84, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 22) {
                Button { audio.skip(by: -AudioPlaybackService.skipBackSeconds) } label: {
                    Image(systemName: "gobackward.15").font(.system(size: 24))
                }
                .accessibilityLabel(L("audioPlayer.skipBack"))

                Button { audio.togglePlayPause() } label: {
                    ZStack {
                        if audio.isBuffering {
                            ProgressView().progressViewStyle(.circular).tint(.white)
                        } else {
                            Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 30))
                        }
                    }
                    .frame(width: 52, height: 52)
                }
                .accessibilityLabel(audio.isPlaying ? L("audioPlayer.pause") : L("audioPlayer.play"))

                Button { audio.skip(by: AudioPlaybackService.skipForwardSeconds) } label: {
                    Image(systemName: "goforward.30").font(.system(size: 24))
                }
                .accessibilityLabel(L("audioPlayer.skipForward"))
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if audio.variants.count > 1 { variantMenu }
                AirPlayRoutePicker()
                    .frame(width: 32, height: 32)
                    .accessibilityLabel(L("audioPlayer.airplay"))
            }
            .frame(width: 84, alignment: .trailing)
        }
        .buttonStyle(.plain)
    }

    private var rateMenu: some View {
        Menu {
            ForEach(AudioPlaybackService.rates, id: \.self) { value in
                Button {
                    audio.setRate(value)
                } label: {
                    if value == audio.rate {
                        Label(Self.rateTitle(value), systemImage: "checkmark")
                    } else {
                        Text(Self.rateTitle(value))
                    }
                }
            }
        } label: {
            Text(Self.rateTitle(audio.rate))
                .font(.system(size: 13, weight: .bold, design: design).monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.2), in: Capsule())
        }
        .accessibilityLabel(L("audioPlayer.rate"))
    }

    private var variantMenu: some View {
        Menu {
            ForEach(Array(audio.variants.enumerated()), id: \.offset) { index, variant in
                Button {
                    audio.selectVariant(index)
                } label: {
                    if index == audio.selectedVariant {
                        Label(variant.label, systemImage: "checkmark")
                    } else {
                        Text(variant.label)
                    }
                }
            }
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel(L("audioPlayer.variant"))
    }

    private static func rateTitle(_ rate: Float) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}
