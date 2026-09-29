import PDFKit
import SwiftUI
import UIKit

/// Shows the PDF of a PDF article (`Article.isPDF`) inside the reader.
///
/// The server stores only the source URL. `PDFCacheService` downloads the file when the article is
/// opened (or serves the cached copy offline); each page is then rendered as an image in a
/// `LazyVStack`. The pages deliberately live in the reader's *outer* `ScrollView` instead of a
/// `PDFView` with its own scrolling: that way reading progress, position restore, the progress bar and
/// the bottom-bar auto-hide keep working unchanged. Trade-off: no pinch zoom and no text selection.
struct PDFArticleView: View {
    let sourceURL: URL
    /// Width of the reader viewport; pages fill it minus a small margin.
    let availableWidth: CGFloat

    private enum Phase {
        case loading
        case failed
        case encrypted
        case ready(PDFDocument)
    }

    @State private var phase: Phase = .loading
    /// Bumped by "Try again" to re-run `.task(id:)`.
    @State private var attempt = 0

    private var pageWidth: CGFloat { max(200, availableWidth - 32) }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 16) {
                    ProgressView()
                    Text(L("articleReader.pdf.loading"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)

            case .failed:
                messageView(text: L("articleReader.pdf.failed"), showRetry: true)

            case .encrypted:
                messageView(text: L("articleReader.pdf.encrypted"), showRetry: false)

            case .ready(let document):
                LazyVStack(spacing: 12) {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        if let page = document.page(at: index) {
                            PDFPageView(page: page, width: pageWidth)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .task(id: "\(sourceURL.absoluteString)#\(attempt)") {
            await load()
        }
    }

    private func messageView(text: String, showRetry: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if showRetry {
                Button(L("articleReader.pdf.retry")) {
                    phase = .loading
                    attempt += 1
                }
                .buttonStyle(.bordered)
            }
            Link(L("articleReader.pdf.openBrowser"), destination: sourceURL)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    @MainActor
    private func load() async {
        do {
            let file = try await PDFCacheService.shared.fetch(sourceURL)
            guard let document = PDFDocument(url: file) else {
                // Unreadable file: drop it so "Try again" downloads a fresh copy.
                await PDFCacheService.shared.remove(sourceURL)
                phase = .failed
                return
            }
            phase = document.isLocked ? .encrypted : .ready(document)
        } catch is CancellationError {
            // View went away (e.g. next article) – nothing to show.
        } catch {
            phase = .failed
        }
    }
}

// MARK: – Single page

/// Renders one PDF page as an image once it scrolls into view and frees it again when it leaves,
/// so long documents don't keep every page bitmap in memory.
private struct PDFPageView: View {
    /// `PDFPage` isn't `Sendable`; each page is rendered by exactly one task at a time, which PDFKit
    /// tolerates, so it is boxed to cross into the background renderer.
    private struct PageBox: @unchecked Sendable { let page: PDFPage }

    let page: PDFPage
    let width: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private var aspect: CGFloat {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let w = rotated ? box.height : box.width
        let h = rotated ? box.width : box.height
        return h / max(w, 1)
    }

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(width: width, height: width * aspect)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .task(id: width) {
            let box = PageBox(page: page)
            // Cap the bitmap so a huge page can't blow up memory.
            let pixelWidth = min(width * displayScale, 2000)
            let size = CGSize(width: pixelWidth, height: pixelWidth * aspect)
            image = await Task.detached(priority: .userInitiated) {
                box.page.thumbnail(of: size, for: .cropBox)
            }.value
        }
        .onDisappear { image = nil }
        .accessibilityHidden(true)
    }
}
