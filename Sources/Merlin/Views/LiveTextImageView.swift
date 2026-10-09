import SwiftUI
import UIKit
import VisionKit

/// Image with Apple's Live Text on top (select, copy, look up, translate text
/// in the image, like in Photos). Used by the lightbox's text mode; the
/// analysis runs on the device (`ImageAnalyzer`), nothing is stored.
struct LiveTextImageView: UIViewRepresentable {
    let image: UIImage
    let analysis: ImageAnalysis

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        // Ohne das meldet der UIImageView die Pixelgröße des Bildes als eigene
        // Größe, der ZStack der Lightbox wächst mit und schiebt Schließen- und
        // Live-Text-Knopf aus dem Bild – man kam nicht mehr zurück.
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            view.setContentHuggingPriority(.defaultLow, for: axis)
            view.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        let interaction = ImageAnalysisInteraction()
        interaction.preferredInteractionTypes = .automatic
        view.addInteraction(interaction)
        context.coordinator.interaction = interaction
        interaction.analysis = analysis
        // Erkannten Text gleich hervorheben, damit sichtbar ist, was markierbar ist.
        interaction.selectableItemsHighlighted = true
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if view.image !== image { view.image = image }
        if context.coordinator.interaction?.analysis !== analysis {
            context.coordinator.interaction?.analysis = analysis
        }
    }

    /// Nimmt immer den angebotenen Platz, nie die Bildgröße.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var interaction: ImageAnalysisInteraction?
    }
}

/// Loads an image and runs the Live Text analysis for the lightbox.
enum LiveTextLoader {
    enum Failure: Error { case unsupported, unreadable, noText }

    @MainActor
    static func load(_ urlString: String) async throws -> (UIImage, ImageAnalysis) {
        guard ImageAnalyzer.isSupported else { throw Failure.unsupported }
        guard let url = URL(string: urlString) else { throw Failure.unreadable }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let image = UIImage(data: data) else { throw Failure.unreadable }
        let analyzer = ImageAnalyzer()
        let analysis = try await analyzer.analyze(image, configuration: ImageAnalyzer.Configuration([.text]))
        guard analysis.hasResults(for: .text) else { throw Failure.noText }
        return (image, analysis)
    }
}
