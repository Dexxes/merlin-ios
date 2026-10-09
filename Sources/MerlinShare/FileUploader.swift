import Foundation

/// A file taken from the share payload, copied into the extension's temp folder
/// so it outlives the `NSItemProvider` callback.
struct SharedFile: Sendable {
    let localURL: URL
    let name: String
    let mimeType: String
    let size: Int64
}

/// Uploads shared files into the Nextcloud folder "Merlin Dateien" and creates
/// their reading-list entries (merlin-nextcloud ≥ 1.0.18, see `MerlinFileService`
/// on the server):
///
/// 1. `POST /api/files/target` → target path in the sub-folder for the file type
/// 2. WebDAV upload: one `PUT` for small files, Nextcloud chunked upload v2
///    (`MKCOL` + numbered `PUT`s + `MOVE`) for large ones, so a video never has
///    to fit into the extension's memory and a failed chunk is retried alone
/// 3. `POST /api/files` → entry in the list, with the selected tags
///
/// The file never goes through the Merlin API itself: PHP upload limits are too
/// small for videos.
struct FileUploader: Sendable {
    let baseURL: String
    let apiPrefix: String
    let authorization: String

    /// Files up to this size go up in one request; larger ones in chunks of
    /// this size (Nextcloud needs ≥ 5 MB per chunk except the last one).
    static let chunkSize: Int64 = 10 * 1024 * 1024
    private static let attempts = 3

    enum UploadError: Error {
        case http(Int, String?)
        case invalidResponse
        case unreadableFile
    }

    /// Uploads `file` and registers it. `progress` receives the uploaded
    /// fraction of this file (0…1).
    func upload(_ file: SharedFile, tagIds: [Int],
                progress: @escaping @Sendable (Double) -> Void) async throws {
        let target = try await requestTarget(for: file)
        guard let destination = URL(string: baseURL + target.davPath) else { throw UploadError.invalidResponse }

        if file.size <= Self.chunkSize {
            try await retrying {
                try await putFile(file, to: destination, progress: progress)
            }
        } else {
            guard let uploadsRoot = URL(string: baseURL + target.uploadsPath) else { throw UploadError.invalidResponse }
            try await chunkedUpload(file, to: destination, uploadsRoot: uploadsRoot, progress: progress)
        }
        progress(1)
        try await retrying { try await register(path: target.path, tagIds: tagIds) }
    }

    // MARK: – Merlin API

    private struct Target: Decodable {
        let path: String
        let davPath: String
        let uploadsPath: String
    }

    private func requestTarget(for file: SharedFile) async throws -> Target {
        let data = try await send(
            method: "POST",
            url: try apiURL("/files/target"),
            json: ["name": file.name, "mimeType": file.mimeType]
        )
        guard let target = try? JSONDecoder().decode(Target.self, from: data) else {
            throw UploadError.invalidResponse
        }
        return target
    }

    private func register(path: String, tagIds: [Int]) async throws {
        var components = URLComponents(url: try apiURL("/files"), resolvingAgainstBaseURL: false)
        if !tagIds.isEmpty {
            components?.queryItems = tagIds.map { URLQueryItem(name: "tagIds[]", value: "\($0)") }
        }
        guard let url = components?.url else { throw UploadError.invalidResponse }
        _ = try await send(method: "POST", url: url, json: ["path": path])
    }

    private func apiURL(_ path: String) throws -> URL {
        guard let url = URL(string: baseURL + apiPrefix + path) else { throw UploadError.invalidResponse }
        return url
    }

    // MARK: – WebDAV

    private func putFile(_ file: SharedFile, to destination: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = makeRequest(method: "PUT", url: destination, timeout: 300)
        request.setValue(file.mimeType, forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgressDelegate { sent in
            progress(file.size > 0 ? min(1, Double(sent) / Double(file.size)) : 1)
        }
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file.localURL, delegate: delegate)
        try check(response, data)
    }

    private func chunkedUpload(_ file: SharedFile, to destination: URL, uploadsRoot: URL,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        let folder = uploadsRoot.appendingPathComponent("merlin-" + UUID().uuidString, isDirectory: true)
        let destinationHeader = destination.absoluteString
        let totalLength = String(file.size)

        try await retrying {
            var mkcol = makeRequest(method: "MKCOL", url: folder)
            mkcol.setValue(destinationHeader, forHTTPHeaderField: "Destination")
            try await perform(mkcol)
        }

        guard let handle = try? FileHandle(forReadingFrom: file.localURL) else { throw UploadError.unreadableFile }
        defer { try? handle.close() }

        var offset: Int64 = 0
        var index = 1
        while offset < file.size {
            let length = Int(min(Self.chunkSize, file.size - offset))
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: length), !chunk.isEmpty else { throw UploadError.unreadableFile }
            let chunkURL = folder.appendingPathComponent(String(index))
            try await retrying {
                var put = makeRequest(method: "PUT", url: chunkURL, timeout: 300)
                put.setValue(destinationHeader, forHTTPHeaderField: "Destination")
                put.setValue(totalLength, forHTTPHeaderField: "OC-Total-Length")
                let (data, response) = try await URLSession.shared.upload(for: put, from: chunk)
                try check(response, data)
            }
            offset += Int64(chunk.count)
            index += 1
            progress(Double(offset) / Double(file.size))
        }

        // Nextcloud assembles the chunks; for big files this can take a while.
        var move = makeRequest(method: "MOVE", url: folder.appendingPathComponent(".file"), timeout: 600)
        move.setValue(destinationHeader, forHTTPHeaderField: "Destination")
        move.setValue(totalLength, forHTTPHeaderField: "OC-Total-Length")
        try await perform(move)
    }

    // MARK: – HTTP helpers

    private func makeRequest(method: String, url: URL, timeout: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    @discardableResult
    private func send(method: String, url: URL, json: [String: String]) async throws -> Data {
        var request = makeRequest(method: method, url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await perform(request)
    }

    @discardableResult
    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return data
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw UploadError.http(http.statusCode, message)
        }
    }

    /// Retries network failures and server errors (5xx, 429); client errors
    /// (wrong password, missing endpoint) fail right away.
    private func retrying<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch UploadError.http(let code, let message) where code < 500 && code != 429 {
                throw UploadError.http(code, message)
            } catch {
                guard attempt < Self.attempts else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }
}

/// Reports the bytes sent for a single upload task.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress(totalBytesSent)
    }
}
