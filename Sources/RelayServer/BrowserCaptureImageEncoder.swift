import CoreGraphics
import Foundation
import ImageIO
import SharedKit
import UniformTypeIdentifiers

/// Turns cmux's browser screenshot PNG into the JPEG that `surface.browser.capture` sends.
///
/// Each ladder step is tried in order until the JPEG fits the byte limit. Images are only
/// shrunk, never enlarged.
enum BrowserCaptureImageEncoder {
    struct Step: Sendable, Equatable {
        let maxDimension: Int
        let quality: Double
    }

    struct Encoded: Sendable, Equatable {
        let jpeg: Data
        let width: Int
        let height: Int
        let sourceWidth: Int
        let sourceHeight: Int
    }

    enum Failure: Error, Sendable, Equatable {
        case unsupportedImage
        case sizeLimitExceeded
    }

    static let ladder: [Step] = [
        Step(maxDimension: 1600, quality: 0.70),
        Step(maxDimension: 1600, quality: 0.55),
        Step(maxDimension: 1600, quality: 0.40),
        Step(maxDimension: 1280, quality: 0.40),
        Step(maxDimension: 1024, quality: 0.40),
    ]

    static func encode(
        png: Data,
        maxImageBytes: Int = SurfaceBrowserCaptureLimits.maxImageBytes,
        maxPixels: Int64 = TerminalArtifactService.maximumImagePixels,
        ladder: [Step] = BrowserCaptureImageEncoder.ladder
    ) throws -> Encoded {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0, height > 0,
              width <= maxPixels / height
        else { throw Failure.unsupportedImage }

        let longestEdge = Int(max(width, height))
        var scaled: [Int: CGImage] = [:]
        for step in ladder {
            let dimension = min(step.maxDimension, longestEdge)
            let image: CGImage
            if let cached = scaled[dimension] {
                image = cached
            } else {
                guard let made = thumbnail(of: source, maxDimension: dimension) else {
                    throw Failure.unsupportedImage
                }
                scaled[dimension] = made
                image = made
            }
            guard let jpeg = jpeg(image, quality: step.quality) else { throw Failure.unsupportedImage }
            if jpeg.count <= maxImageBytes {
                return Encoded(
                    jpeg: jpeg,
                    width: image.width,
                    height: image.height,
                    sourceWidth: Int(width),
                    sourceHeight: Int(height)
                )
            }
        }
        throw Failure.sizeLimitExceeded
    }

    private static func thumbnail(of source: CGImageSource, maxDimension: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
