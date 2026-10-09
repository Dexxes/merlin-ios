import SwiftUI

/// Share button for an article: entries from "Merlin files" share the file
/// itself (`FileShareItem`), everything else its link. Renders nothing when
/// neither is available.
struct ArticleShareLink<Label: View>: View {
    let article: Article
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let file = article.fileShareItem {
            ShareLink(item: file, preview: SharePreview(article.displayTitle)) {
                label()
            }
        } else if let url = URL(string: article.url) {
            ShareLink(item: url, subject: Text(article.displayTitle)) {
                label()
            }
        }
    }
}

/// `UIActivityViewController` for places that open the share sheet from a
/// plain button (swipe actions on cards). Same rule as `ArticleShareLink`.
struct ArticleShareSheet: UIViewControllerRepresentable {
    let article: Article

    func makeUIViewController(context: Context) -> UIActivityViewController {
        if let file = article.fileShareItem {
            let provider = NSItemProvider()
            provider.suggestedName = file.fileName
            provider.register(file)
            return UIActivityViewController(activityItemsConfiguration: UIActivityItemsConfiguration(itemProviders: [provider]))
        }
        let items: [Any] = URL(string: article.url).map { [$0, article.displayTitle] } ?? [article.displayTitle]
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
