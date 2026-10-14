import SwiftUI
import UIKit

/// Share button for an article: entries from "Merlin files" share the file
/// itself (`FileSharePresenter`), everything else its link. Renders nothing
/// when neither is available.
struct ArticleShareLink<Label: View>: View {
    let article: Article
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let file = article.fileShareItem {
            Button { FileSharePresenter.share(file) } label: { label() }
        } else if let url = URL(string: article.url) {
            ShareLink(item: url, subject: Text(article.displayTitle)) {
                label()
            }
        }
    }
}

/// `UIActivityViewController` for places that open the share sheet from a
/// plain button (swipe actions on cards). Links only; file entries go
/// through `FileSharePresenter`.
struct ArticleShareSheet: UIViewControllerRepresentable {
    let article: Article

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let items: [Any] = URL(string: article.url).map { [$0, article.displayTitle] } ?? [article.displayTitle]
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Downloads a file entry's file and then opens the share sheet with the
/// local file. Presents from the top view controller, so it also works from
/// context menus, which are gone by the time the download finishes. While
/// loading, a small dialog with "Cancel" shows that something is happening.
@MainActor
enum FileSharePresenter {
    @MainActor
    private final class Download {
        var task: Task<Void, Never>?
        var cancelled = false
    }

    static func share(_ item: FileShareItem) {
        guard let presenter = topViewController() else { return }
        removeEarlierDownloads()
        let download = Download()
        let loading = UIAlertController(title: L("fileShare.loading"), message: nil, preferredStyle: .alert)
        loading.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel) { _ in
            download.cancelled = true
            download.task?.cancel()
        })
        // Start only once the dialog is up, so dismissing it never races its presentation.
        presenter.present(loading, animated: true) {
            download.task = Task { @MainActor in
                do {
                    let file = try await item.download()
                    guard !download.cancelled else { return removeFolder(of: file) }
                    loading.dismiss(animated: true) { presentShareSheet(for: file, from: presenter) }
                } catch {
                    guard !download.cancelled else { return }
                    loading.dismiss(animated: true) {
                        let alert = UIAlertController(title: L("common.error"),
                                                      message: L("fileShare.failed"),
                                                      preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: L("common.ok"), style: .default))
                        presenter.present(alert, animated: true)
                    }
                }
            }
        }
    }

    private static func presentShareSheet(for file: URL, from presenter: UIViewController) {
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true)
    }

    /// Files from earlier shares. Not removed right after sharing, because
    /// some targets still read the file after the share sheet has closed.
    private static func removeEarlierDownloads() {
        try? FileManager.default.removeItem(at: FileShareItem.downloadsFolder)
    }

    private static func removeFolder(of file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
