import UIKit
import UniformTypeIdentifiers
import MerlinShared

/// "Read in Merlin" in the share sheet (an action extension).
///
/// Takes the shared link, hands it to the main app as
/// `merlin://read?url=…` and closes right away. The app saves the article
/// like a shared link and opens it in the reader, so this extension needs
/// neither the login nor any network access.
final class ActionViewController: UIViewController {

    private let messageLabel = UILabel()
    private var didStart = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        Task { await run() }
    }

    private func run() async {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        guard let articleURL = await Self.findURL(in: items),
              let deepLink = ReadInMerlinLink.deepLink(for: articleURL) else {
            showError(L("readInMerlin.errorNoUrl"))
            return
        }
        guard openContainingApp(deepLink) else {
            showError(L("readInMerlin.errorOpenApp"))
            return
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Extensions may not call `UIApplication.shared`; the application object
    /// is still reachable through the responder chain, and since iOS 18 only
    /// `open(_:options:completionHandler:)` works there (not `openURL:`).
    private func openContainingApp(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func showError(_ message: String) {
        view.backgroundColor = .systemBackground
        messageLabel.text = message + "\n\n" + L("readInMerlin.tapToClose")
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
    }

    @objc private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: – URL extraction (as in the Share Extension)

    /// Web URLs first; then the first http(s) link in shared text.
    private static func findURL(in items: [NSExtensionItem]) async -> String? {
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURL(from: provider) { return url }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let url = await loadTextURL(from: provider) { return url }
        }
        return nil
    }

    private static func loadURL(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { data, _ in
                if let url = data as? URL {
                    continuation.resume(returning: url.isFileURL ? nil : url.absoluteString)
                } else if let string = data as? String, !string.isEmpty {
                    continuation.resume(returning: string)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadTextURL(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                continuation.resume(returning: (data as? String).flatMap(firstWebURL(in:)))
            }
        }
    }

    private nonisolated static func firstWebURL(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range)
            .compactMap(\.url)
            .first { $0.scheme == "http" || $0.scheme == "https" }?
            .absoluteString
    }
}
