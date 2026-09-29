import CryptoKit
import Foundation

/// On-disk cache for PDFs of PDF articles (`Article.isPDF`).
///
/// The server never stores the PDF – an article only holds the source URL. The reader downloads the
/// document from that URL when it is opened; this cache keeps the file so it can be read again offline.
/// It is purely client-side and can be wiped at any time (the next open just downloads again).
///
/// **Storage:** `Application Support/merlin/pdf-cache/<sha256(url)>.pdf`
/// **Eviction:** age-based (`prune(olderThanDays:)`, called at launch with the article retention),
/// per article on delete (`remove(_:)`), and completely from "Clear Cache" (`clear()`).
///
/// The download deliberately uses a plain `URLSession` without Merlin credentials: the source is an
/// arbitrary third-party host and must never see the Nextcloud/merlin-server login.
actor PDFCacheService {

    static let shared = PDFCacheService()
    private init() {}

    enum PDFError: Error {
        case invalidURL
        case badStatus(Int)
        case notAPDF
        case tooLarge
    }

    /// Upper bound for a single PDF (larger files are rejected instead of filling the disk).
    static let maxBytes: Int64 = 100 * 1024 * 1024

    // MARK: – Paths

    nonisolated var cacheDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("merlin/pdf-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(name).pdf")
    }

    /// Local file for `url` if it has been downloaded before, otherwise `nil`.
    nonisolated func cachedFile(for url: URL) -> URL? {
        let file = fileURL(for: url)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    // MARK: – Download

    /// Returns the local file for `url`, downloading it first if needed.
    /// - Throws: `PDFError` for a bad URL/status, a response that is not a PDF, or an oversized file;
    ///   `URLError` for network failures.
    func fetch(_ url: URL) async throws -> URL {
        let fm = FileManager.default
        let destination = fileURL(for: url)
        if fm.fileExists(atPath: destination.path) {
            // Refresh the modification date so age-based pruning behaves like "last opened".
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return destination
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host else {
            throw PDFError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        request.setValue("application/pdf,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(for: request)
        defer { try? fm.removeItem(at: tempURL) }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PDFError.badStatus(http.statusCode)
        }

        let size = (try? fm.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        guard size <= Self.maxBytes else { throw PDFError.tooLarge }
        guard Self.looksLikePDF(tempURL) else { throw PDFError.notAPDF }

        try? fm.removeItem(at: destination)
        try fm.moveItem(at: tempURL, to: destination)
        return destination
    }

    /// PDF files start with `%PDF-`, though the spec tolerates junk in the first 1024 bytes.
    private static func looksLikePDF(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1024) else { return false }
        return head.range(of: Data("%PDF-".utf8)) != nil
    }

    // MARK: – Eviction

    /// Deletes the cached file for `url` (article deleted).
    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: fileURL(for: url))
    }

    /// Deletes cached PDFs that were not opened within the last `days` days.
    func prune(olderThanDays days: Int) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        guard let files = try? fm.contentsOfDirectory(at: cacheDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: file) }
        }
    }

    /// Wipes the whole PDF cache ("Clear Cache" in Settings).
    func clear() {
        try? FileManager.default.removeItem(at: cacheDir)
    }
}
