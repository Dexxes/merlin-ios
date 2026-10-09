import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Compression levels the share sheet offers for shared photos.
enum ImageCompression: String, CaseIterable, Sendable {
    case strong, light, original

    /// Longest side in pixels and JPEG quality, `nil` = upload the original.
    var settings: (maxPixelSize: Int, quality: Double)? {
        switch self {
        case .strong:   return (1600, 0.55)
        case .light:    return (4096, 0.8)
        case .original: return nil
        }
    }
}

/// The shared files at one compression level: photos re-encoded as JPEG,
/// everything else (videos, PDFs, GIFs …) unchanged.
struct CompressionOption: Sendable {
    let level: ImageCompression
    let files: [SharedFile]
    let totalSize: Int64
    /// PNG of a centre crop of the first photo at this level, so the tiles show
    /// the actual loss of detail (a whole-image thumbnail would look the same
    /// for all three levels).
    let preview: Data?
}

/// Re-encodes shared photos with ImageIO. Works on files, never on whole
/// decoded images in memory beyond one photo at a time, because a share
/// extension is killed at around 120 MB.
enum ImageCompressor {
    /// Decoding limit for previews: a 48 MP photo decoded at full size would
    /// take ~200 MB.
    private static let previewDecodeSize = 4096
    /// Side of the preview crop relative to the longer image side.
    private static let previewCropFraction = 0.15
    private static let previewPixels = 360

    static func isCompressible(_ file: SharedFile) -> Bool {
        guard let type = UTType(mimeType: file.mimeType), type.conforms(to: .image) else { return false }
        // Animated GIFs would lose their animation, SVG is not a bitmap.
        return !type.conforms(to: .gif) && !type.conforms(to: .svg)
    }

    static func option(for files: [SharedFile], level: ImageCompression) -> CompressionOption {
        // Cancelled when the share sheet closes: skip the remaining photos.
        let converted = files.map { file in
            isCompressible(file) && !Task.isCancelled ? (compress(file, level: level) ?? file) : file
        }
        let firstImage = zip(files, converted).first { isCompressible($0.0) }?.1
        return CompressionOption(
            level: level,
            files: converted,
            totalSize: converted.reduce(0) { $0 + $1.size },
            preview: firstImage.flatMap(previewCrop(of:))
        )
    }

    /// JPEG version of `file` next to it (`<folder>/<level>/<name>.jpg`). The
    /// original when it is already smaller, `nil` when it can't be read.
    /// All metadata (EXIF incl. location, TIFF, IPTC, XMP) is copied as is;
    /// only the pixel dimensions are updated to the new size. The pixels stay
    /// in the original's orientation, so its orientation tag stays valid too.
    static func compress(_ file: SharedFile, level: ImageCompression) -> SharedFile? {
        guard let settings = level.settings else { return file }
        guard let source = CGImageSourceCreateWithURL(file.localURL as CFURL, nil),
              let image = decode(source, maxPixelSize: settings.maxPixelSize, applyOrientation: false)
        else { return nil }

        let name = (file.name as NSString).deletingPathExtension + ".jpg"
        let folder = file.localURL.deletingLastPathComponent()
            .appendingPathComponent(level.rawValue, isDirectory: true)
        let target = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard let destination = CGImageDestinationCreateWithURL(
            target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: settings.quality] as CFDictionary
        if let original = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let metadata = CGImageMetadataCreateMutableCopy(original) {
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension, image.width as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension, image.height as CFNumber)
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, options)
        } else {
            CGImageDestinationAddImage(destination, image, options)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }

        let size = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard size > 0, size < file.size else {
            try? FileManager.default.removeItem(at: target)
            return file
        }
        return SharedFile(localURL: target, name: name, mimeType: "image/jpeg", size: size)
    }

    /// Decodes the image scaled down to at most `maxPixelSize` on the longer
    /// side (never up). `applyOrientation` turns the pixels upright (preview);
    /// without it they keep the stored orientation (compression, so the
    /// copied orientation tag still matches).
    private static func decode(_ source: CGImageSource, maxPixelSize: Int,
                               applyOrientation: Bool = true) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? maxPixelSize
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? maxPixelSize
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: applyOrientation,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, max(width, height)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Square centre crop of the image, drawn into a small bitmap so the big
    /// decoded image can be released right away.
    private static func previewCrop(of file: SharedFile) -> Data? {
        guard let source = CGImageSourceCreateWithURL(file.localURL as CFURL, nil),
              let image = decode(source, maxPixelSize: previewDecodeSize) else { return nil }
        let longSide = Double(max(image.width, image.height))
        let side = min(Double(min(image.width, image.height)), max(1, (longSide * previewCropFraction).rounded()))
        let rect = CGRect(x: ((Double(image.width) - side) / 2).rounded(),
                          y: ((Double(image.height) - side) / 2).rounded(),
                          width: side, height: side)
        guard let crop = image.cropping(to: rect),
              let context = CGContext(data: nil, width: previewPixels, height: previewPixels,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // Upscaling (strong compression) with nearest-neighbour keeps its
        // pixels visible instead of smoothing them away.
        context.interpolationQuality = side < Double(previewPixels) ? .none : .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: previewPixels, height: previewPixels))
        guard let scaled = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
