import SwiftUI

/// An image view that serves from the on-disk `ImageCacheService` when
/// available, falling back to a URLSession download that also persists
/// the result to the cache — so any view that opens the same URL
/// afterwards (e.g. the article reader after the card view) gets it
/// instantly from disk without a second network request.
///
/// Loading is done off the main thread; the placeholder is shown while
/// the image is in-flight.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {

    let url: URL?
    @ViewBuilder let content:     (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var uiImage: UIImage? = nil

    var body: some View {
        Group {
            if let uiImage {
                content(Image(uiImage: uiImage).resizable())
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    // MARK: – Private

    private func loadImage() async {
        guard let url else {
            await MainActor.run { uiImage = nil }
            return
        }

        // Fast path: already on disk – no network needed.
        if let img = loadFromDisk(url: url) {
            await MainActor.run { uiImage = img }
            return
        }

        // Slow path: download via ImageCacheService (stores to disk),
        // then read back from disk. Any subsequent view showing the same
        // URL will hit the fast path above.
        let cached = await ImageCacheService.shared.fetchSingle(url: url)
        guard cached, let img = loadFromDisk(url: url) else { return }
        await MainActor.run { uiImage = img }
    }

    /// Synchronous disk read – safe to call from background threads.
    private func loadFromDisk(url: URL) -> UIImage? {
        guard let localURL = ImageCacheService.shared.localURL(for: url),
              let data     = try? Data(contentsOf: localURL) else { return nil }
        return UIImage(data: data)
    }
}
