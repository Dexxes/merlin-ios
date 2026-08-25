import CryptoKit
import Foundation
import UIKit

/// Persistent on-disk image cache for offline article reading.
///
/// **Storage:** `Application Support/merlin/img-cache/`
/// **Filenames:** FNV-1a hash of the remote URL string (no extension needed –
///   UIImage detects format from bytes).
/// **Index:** `img-index.json` maps `articleId → [urlString]` so eviction can
///   delete exactly the files that belong to a given article.
///
/// `localURL(for:)` is `nonisolated` and synchronous so it can be called
/// directly from SwiftUI View bodies and `buildReaderHTML` without `await`.
actor ImageCacheService {

    static let shared = ImageCacheService()
    private init() {}

    // MARK: – Paths

    nonisolated var cacheDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("merlin/img-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }

    private var indexURL: URL { cacheDir.appendingPathComponent("img-index.json") }

    // MARK: – Filename (nonisolated – pure computation)

    /// Maps a Content-Type header value to a known file extension.
    /// Returns nil for unrecognised types so the caller can fall back gracefully.
    nonisolated func mimeTypeToExtension(_ contentType: String) -> String? {
        // Strip parameters like "; charset=utf-8"
        let mime = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? contentType
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg":  return "jpeg"
        case "image/png":                return "png"
        case "image/gif":                return "gif"
        case "image/webp":               return "webp"
        case "image/avif":               return "avif"
        case "image/svg+xml":            return "svg"
        default:                         return nil
        }
    }

    /// SHA-256 hash of the URL string, hex-encoded.
    nonisolated func filename(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Like `filename(for:)` but appends the original URL's file extension
    /// (e.g. `.jpeg`, `.png`) so WKWebView can infer the MIME type without
    /// relying on content sniffing.  Falls back to no extension for URLs
    /// whose path extension is absent or non-standard.
    nonisolated func filenameWithExtension(for url: URL) -> String {
        let base = filename(for: url)
        let ext  = url.pathExtension.lowercased()
        let known: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "svg"]
        return known.contains(ext) ? "\(base).\(ext)" : base
    }

    // MARK: – Synchronous lookup (nonisolated)

    /// Returns the local `file://` URL for `url` if it is cached on disk,
    /// otherwise `nil`.  Safe to call from any thread or SwiftUI body.
    ///
    /// Lookup order:
    /// 1. Extension derived from the URL path (new format, e.g. "abc123.jpeg")
    /// 2. Bare hash without extension (legacy format)
    ///    → lazily migrated to the extension-suffixed name when possible
    /// 3. Extension derived from Content-Type at download time
    ///    → checked for all known image extensions so URLs without a path
    ///    extension (e.g. CDN query-param URLs) are found correctly
    nonisolated func localURL(for url: URL) -> URL? {
        let fm      = FileManager.default
        let withExt = cacheDir.appendingPathComponent(filenameWithExtension(for: url))
        if fm.fileExists(atPath: withExt.path) { return withExt }

        let plain = cacheDir.appendingPathComponent(filename(for: url))
        if fm.fileExists(atPath: plain.path) {
            // Lazy migration: copy the extensionless legacy file to the new name.
            // Skip when filenames are identical (URL had no recognised extension).
            guard withExt.lastPathComponent != plain.lastPathComponent else { return plain }
            try? fm.copyItem(at: plain, to: withExt)
            if fm.fileExists(atPath: withExt.path) {
                try? fm.removeItem(at: plain)
                return withExt
            }
            return plain
        }

        // Fallback: the file was stored with a Content-Type-derived extension
        // that differs from what the URL path suggests (or the URL has none).
        // Try every known extension – this is only a handful of fileExists calls.
        let base = filename(for: url)
        for ext in ["jpeg", "jpg", "png", "webp", "gif", "avif", "svg"] {
            let candidate = cacheDir.appendingPathComponent("\(base).\(ext)")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        return nil
    }

    // MARK: – Index (actor-isolated)

    private var index: [String: [String]] = [:]
    private var indexLoaded = false

    private func loadIndex() {
        guard !indexLoaded else { return }
        indexLoaded = true
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return }
        index = decoded
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: – Prefetch

    /// Downloads all images for the given (unarchived) articles and stores them
    /// on disk.  Respects the user's Wi-Fi-only preference via URLSession
    /// configuration.  Already-cached files are skipped.
    ///
    /// Call with `.background` / `.utility` priority – this can be slow on
    /// first run.
    func prefetch(for articles: [Article]) async {
        loadIndex()
        let wifiOnly = PreferencesStore.shared.prefetchImagesOnWifiOnly
        let session  = makeSession(wifiOnly: wifiOnly)

        // Collect all URLs per article, deduplicating globally.
        var seen = Set<String>()
        var work: [(articleId: Int, url: URL)] = []

        for article in articles where !article.isArchived {
            let urls = imageURLs(for: article)
            let key  = String(article.id)
            // Merge new URLs into existing index entry (article may have
            // gained more images since last prefetch).
            let existing = Set(index[key] ?? [])
            let allStrs  = Set(urls.map(\.absoluteString)).union(existing)
            index[key]   = Array(allStrs)

            for url in urls {
                let str = url.absoluteString
                guard !seen.contains(str) else { continue }
                seen.insert(str)
                guard localURL(for: url) == nil else { continue }  // already cached
                work.append((article.id, url))
            }
        }

        saveIndex()

        // Download with max 4 concurrent tasks.
        await withTaskGroup(of: Void.self) { group in
            var slots = 4
            for item in work {
                guard !Task.isCancelled else { break }
                if slots == 0 { await group.next(); slots += 1 }
                group.addTask(priority: .utility) { [weak self] in
                    guard let self else { return }
                    await self.downloadAndStore(url: item.url, session: session)
                }
                slots -= 1
            }
        }
    }

    /// Downloads a single image and stores it.
    /// Returns true if the image is available in cache afterwards.
    /// Pass `respectWifiOnly: true` to honour the user's Wi-Fi-only prefetch
    /// preference; `false` (default) always allows cellular access.
    func fetchSingle(url: URL, respectWifiOnly: Bool = false) async -> Bool {
        loadIndex()
        if localURL(for: url) != nil { return true }   // already cached
        let wifiOnly = respectWifiOnly && PreferencesStore.shared.prefetchImagesOnWifiOnly
        let session  = makeSession(wifiOnly: wifiOnly)
        await downloadAndStore(url: url, session: session)
        return localURL(for: url) != nil
    }

    private func downloadAndStore(url: URL, session: URLSession) async {
        // Send a Referer matching the image's own origin so CDNs with hotlink
        // protection (e.g. Gumlet domain restrictions) accept the request.
        var request = URLRequest(url: url)
        if let origin = url.host.map({ "\(url.scheme ?? "https")://\($0)" }) {
            request.setValue(origin, forHTTPHeaderField: "Referer")
        }
        guard let (data, response) = try? await session.data(for: request),
              !data.isEmpty,
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true
        else { return }

        // Prefer the URL-derived filename (e.g. "abc123.jpeg").
        // If the URL has no recognised extension, try to get one from the
        // Content-Type header so WKWebView can infer the MIME type later.
        var destFilename = filenameWithExtension(for: url)
        let urlHasKnownExt = destFilename != filename(for: url)
        if !urlHasKnownExt,
           let httpResponse = response as? HTTPURLResponse,
           let ct = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           let ext = mimeTypeToExtension(ct) {
            destFilename = "\(filename(for: url)).\(ext)"
        }

        let dest = cacheDir.appendingPathComponent(destFilename)
        try? data.write(to: dest, options: .atomic)
    }

    // MARK: – Eviction

    /// Removes all cached images that belong to `articleId`.
    func evict(articleId: Int) {
        loadIndex()
        let key = String(articleId)
        guard let urls = index[key] else { return }
        let fm = FileManager.default
        for urlStr in urls {
            guard let url = URL(string: urlStr) else { continue }
            // Try the extension-suffixed name first (current format), then the
            // legacy bare-hash name so old cached files are also cleaned up.
            let withExt = cacheDir.appendingPathComponent(filenameWithExtension(for: url))
            let plain   = cacheDir.appendingPathComponent(filename(for: url))
            try? fm.removeItem(at: withExt)
            if withExt.lastPathComponent != plain.lastPathComponent {
                try? fm.removeItem(at: plain)
            }
        }
        index.removeValue(forKey: key)
        saveIndex()
    }

    /// Wipes the entire image cache (called from "Clear Cache" in Settings).
    func clear() {
        try? FileManager.default.removeItem(at: cacheDir)
        index      = [:]
        indexLoaded = false
    }

    // MARK: – Helpers

    /// Extracts every `<img src="...">` URL from an HTML fragment (article body
    /// content). `nonisolated` and pure so it can also be called from
    /// ArticleReaderView (e.g. to find images the bulk `prefetch(for:)` below
    /// hasn't gotten to yet, so it can fetch them itself with the same
    /// Referer-aware `fetchSingle`).
    nonisolated func contentImageURLs(in content: String) -> [URL] {
        var urls: [URL] = []
        let pattern = #"<img\b[^>]*\ssrc="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return urls }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            guard let r = Range(m.range(at: 1), in: content) else { continue }
            let raw = String(content[r])
                .replacingOccurrences(of: "&amp;",  with: "&")
                .replacingOccurrences(of: "&lt;",   with: "<")
                .replacingOccurrences(of: "&gt;",   with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;",  with: "'")
            if let url = URL(string: raw) {
                urls.append(url)
            }
        }
        return urls
    }

    /// Extracts every image URL from an article: hero, favicon, and all
    /// `<img src="...">` occurrences in the HTML content.
    private func imageURLs(for article: Article) -> [URL] {
        var urls: [URL] = []

        if let str = article.imageUrl, let url = URL(string: str) {
            urls.append(url)
        }
        if let url = article.faviconUrl {
            urls.append(url)
        }
        if let content = article.content {
            urls.append(contentsOf: contentImageURLs(in: content))
        }
        return urls
    }

    private func makeSession(wifiOnly: Bool) -> URLSession {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess       = !wifiOnly
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }
}
