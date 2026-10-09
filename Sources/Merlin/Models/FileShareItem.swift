import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The original file of a "Merlin files" entry for `ShareLink`: sharing an
/// entry hands on the file itself (photo to Photos, PDF to Files, AirDrop …)
/// instead of its Nextcloud link. The file is only downloaded once the user
/// picks a target, through the signed download link from the metadata
/// section (no credentials needed).
struct FileShareItem: Transferable {
    let downloadURL: URL
    let fileName: String
    let contentType: UTType

    /// Types with their own representation, so targets like Photos ("Save
    /// Image") or Files recognise the file; anything else goes out as plain
    /// data with its file name.
    private static let knownTypes: [UTType] = [.image, .movie, .audio, .pdf]

    static var transferRepresentation: some TransferRepresentation {
        representation(.image)
        representation(.movie)
        representation(.audio)
        representation(.pdf)
        FileRepresentation(exportedContentType: .data) { item in
            SentTransferredFile(try await item.download(), allowAccessingOriginalFile: false)
        }
        .exportingCondition { item in
            !knownTypes.contains { item.contentType.conforms(to: $0) }
        }
    }

    /// Exports items whose type conforms to `type`.
    private static func representation(_ type: UTType) -> some TransferRepresentation<FileShareItem> {
        FileRepresentation(exportedContentType: type) { item in
            SentTransferredFile(try await item.download(), allowAccessingOriginalFile: false)
        }
        .exportingCondition { item in item.contentType.conforms(to: type) }
    }

    /// Downloads into its own temporary folder under the entry's file name, so
    /// the target receives "IMG_1234.HEIC" rather than a random name.
    private func download() async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("merlin-share-out", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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
        let fileName = name.isEmpty ? "file" : name
        let type = fileMime.flatMap { UTType(mimeType: $0) }
            ?? UTType(filenameExtension: (fileName as NSString).pathExtension)
            ?? .data
        return FileShareItem(downloadURL: downloadURL, fileName: fileName, contentType: type)
    }
}
