import Foundation

/// Deep link from the "Read in Merlin" action extension to the main app:
/// `merlin://read?url=<percent-encoded article URL>`.
///
/// The extension cannot save and show an article itself, so it hands the URL
/// to the app, which saves it like a shared link and opens it in the reader.
public enum ReadInMerlinLink {

    /// URL scheme registered by the main app (`CFBundleURLTypes`).
    public static let scheme = "merlin"
    static let host = "read"
    static let queryItem = "url"

    /// The deep link for an article URL, or nil for anything but http(s).
    public static func deepLink(for articleURL: String) -> URL? {
        guard let article = webURL(from: articleURL) else { return nil }
        // Encode everything but unreserved characters: URLQueryItem would leave
        // "&", "=", "+" and "?" of the article URL alone and split it up.
        guard let value = article.absoluteString.addingPercentEncoding(withAllowedCharacters: queryValueAllowed)
        else { return nil }
        return URL(string: "\(scheme)://\(host)?\(queryItem)=\(value)")
    }

    /// The article URL carried by a deep link, or nil if `url` is not one.
    public static func articleURL(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == queryItem })?.value
        else { return nil }
        return webURL(from: value)?.absoluteString
    }

    /// Characters left unencoded in the query value: unreserved ones only.
    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func webURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}
