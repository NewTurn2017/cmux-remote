import ImageIO
import SharedKit
import UIKit

enum BrowserCaptureDecodeError: Error, Equatable {
    case undecodableImage
}

/// Turns a capture result into a display-ready image. Called off the main actor.
protocol BrowserCaptureDecoding: Sendable {
    func decode(_ result: SurfaceBrowserCaptureResult) throws -> UIImage
}

struct ImageIOBrowserCaptureDecoder: BrowserCaptureDecoding {
    func decode(_ result: SurfaceBrowserCaptureResult) throws -> UIImage {
        // Release the base64 and JPEG buffers as soon as the bitmap exists.
        try autoreleasepool {
            let data = try result.decodedImage()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(
                      source,
                      0,
                      [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                  )
            else { throw BrowserCaptureDecodeError.undecodableImage }
            return UIImage(cgImage: image)
        }
    }
}
