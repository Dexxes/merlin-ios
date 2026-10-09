import Foundation
import UniformTypeIdentifiers

/// The original file of a "Merlin files" entry. Sharing an entry hands on
/// the file itself (photo to Photos, Telegram, Signal, PDF to Files, AirDrop …)
/// instead of its Nextcloud link. The file is downloaded first, through the
/// signed download link from the metadata section (no credentials needed),
/// and then shared as a local file URL: other apps' share extensions
/// (Telegram, Signal) only accept that reliably, not a lazily exported
/// `Transferable` with abstract types like `public.image`.
struct FileShareItem {
    let downloadURL: URL
    let fileName: String

    /// Temporary folder for downloaded files to share.
    static var downloadsFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("merlin-share-out", isDirectory: true)
    }

    /// Downloads into its own temporary folder under the entry's file name, so
    /// the target receives "IMG_1234.HEIC" rather than a random name and can
    /// tell the type from the extension.
    func download() async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let folder = Self.downloadsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(fileName)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
}

extension Article {
    /// The file to share instead of the link, for entries from "Merlin files"
    /// whose content carries the download link (merlin-nextcloud ≥ 1.0.18).
    var fileShareItem: FileShareItem? {
        guard fileId != nil, let content,
              let downloadURL = FileMetadataParser.downloadURL(in: content) else { return nil }
        let name = title.replacingOccurrences(of: "/", with: "-")
        var fileName = name.isEmpty ? "file" : name
        // Without an extension the target can't tell the type; take it from the MIME type.
        if (fileName as NSString).pathExtension.isEmpty,
           let ext = fileMime.flatMap({ UTType(mimeType: $0) })?.preferredFilenameExtension {
            fileName += ".\(ext)"
        }
        return FileShareItem(downloadURL: downloadURL, fileName: fileName)
    }
}
