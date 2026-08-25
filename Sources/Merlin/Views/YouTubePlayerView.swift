import SwiftUI
import WebKit

// MARK: – State passed from ArticleReaderView

struct YouTubePlayerState: Identifiable {
    let id = UUID()
    let videoId: String
    let startSeconds: Int?
}

// MARK: – Full-screen YouTube player
//
// Loads YoutubeEmbedController's proxy page (server-side, see its docblock)
// via a TOP-LEVEL WKWebView navigation — its own window, no parent frame —
// instead of embedding the YouTube <iframe> inside the article reader's
// file://-origin WKWebView.
//
// Why not just embed it inline? Two approaches were tried and both failed
// silently:
//   1. A YouTube <iframe> nested directly in the reader's file:// document:
//      breaks with "Error 153" (no valid https origin/referrer for the
//      player to validate).
//   2. A proxy <iframe> (real https origin) nested INSIDE the reader's
//      file:// document: WKWebView doesn't reliably honour CSP
//      frame-ancestors for a file:// parent — the frame just renders blank,
//      no error at all.
// A top-level navigation has no parent frame whatsoever, so
// X-Frame-Options/frame-ancestors never come into play, and the proxy
// page's own referrerpolicy on its inner YouTube <iframe> is respected
// normally since there's no file:// ancestor confusing things.
struct YouTubePlayerView: View {
    let state: YouTubePlayerState
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let url = Self.embedURL(for: state) {
                YouTubeWebView(url: url)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            } else {
                // Kein konfigurierter Server – rewriteYouTubeEmbeds() prüft
                // denselben Guard schon vor der Platzhalter-Erzeugung, sollte
                // hier also praktisch nie greifen.
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.8))
                    Text("Server nicht konfiguriert")
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.white.opacity(0.25))
                    .shadow(color: .black.opacity(0.4), radius: 4)
            }
            .padding(.top, 56)
            .padding(.trailing, 20)
        }
    }

    private static func embedURL(for state: YouTubePlayerState) -> URL? {
        let store = CredentialsStore.shared
        guard store.isConfigured else { return nil }

        // merlin-server hat (noch) keinen YoutubeEmbedController-Analog. Statt
        // das Feature dafür auszublenden, wird die YouTube-Embed-Seite bei
        // Standalone-Backends direkt top-level geladen (ohne Proxy-Umweg) -
        // funktioniert genauso gut, weil laut YouTubePlayerView-Docblock schon
        // die Top-Level-Navigation selbst (ohne Elternframe) das ursprüngliche
        // file://-Origin-Problem löst; der Proxy fügte nur eine zusätzliche,
        // hier unnötige Origin-Bestätigungsebene hinzu.
        guard store.supportsNextcloudOnlyFeatures else {
            var components = URLComponents(string: "https://www.youtube-nocookie.com/embed/\(state.videoId)")
            var items = [
                URLQueryItem(name: "controls", value: "1"),
                URLQueryItem(name: "modestbranding", value: "1"),
                URLQueryItem(name: "playsinline", value: "1"),
                URLQueryItem(name: "rel", value: "0"),
            ]
            if let start = state.startSeconds {
                items.append(URLQueryItem(name: "start", value: String(start)))
            }
            components?.queryItems = items
            return components?.url
        }

        var components = URLComponents(string: "\(store.nextcloudUrl)/index.php/apps/merlin/api/youtube-embed")
        var items = [URLQueryItem(name: "v", value: state.videoId)]
        if let start = state.startSeconds {
            items.append(URLQueryItem(name: "t", value: String(start)))
        }
        components?.queryItems = items
        return components?.url
    }
}

// MARK: – Top-level WKWebView (its own window, no parent frame, no file:// origin)

private struct YouTubeWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // playsinline=1 (siehe YoutubeEmbedController) erwartet ein WebView,
        // das Inline-Wiedergabe zulässt statt jeden Videostart in einen
        // nativen Vollbildplayer zu zwingen.
        config.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.isScrollEnabled = false
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Die URL hängt über state.id (Identifiable) an der Lebensdauer
        // dieser View — bei einem anderen Video erzeugt SwiftUI eine neue
        // View statt diese wiederzuverwenden, ein Reload hier ist also nie nötig.
    }
}
