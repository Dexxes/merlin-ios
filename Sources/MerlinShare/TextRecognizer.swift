import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Recognises text in shared photos on the device (Vision, no network), so
/// the server can store it with the entry: shown below the image as
/// "Recognized text" and found by the search (merlin-nextcloud ≥ 1.0.19).
enum TextRecognizer {
    /// Longer side the photo is scaled to for recognition; enough for
    /// documents and signs, small enough for the share extension's memory.
    private static let maxPixelSize = 3000

    /// Text in reading order; paragraphs (larger vertical gaps) separated by
    /// a blank line. nil when the image has no text or can't be read.
    static func recognize(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else { return nil }

        var text = ""
        var previous: CGRect?
        for observation in observations {
            guard let line = observation.topCandidates(1).first?.string, !line.isEmpty else { continue }
            if let previous {
                // Normalisierte Koordinaten, Ursprung unten links: Abstand
                // zwischen Unterkante der vorigen und Oberkante dieser Zeile.
                let gap = previous.minY - observation.boundingBox.maxY
                text += gap > previous.height * 1.2 ? "\n\n" : "\n"
            }
            text += line
            previous = observation.boundingBox
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
