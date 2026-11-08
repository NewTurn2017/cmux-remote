import Foundation

/// Fixed bounds of the `surface.browser.capture` contract.
public struct SurfaceBrowserCaptureLimits: Sendable, Equatable {
    /// Longest edge of the image the relay sends, in pixels.
    public static let maxDimension = 1600
    /// Maximum JPEG bytes in one capture, so one response frame stays under 1 MiB.
    public static let maxImageBytes = 737_280
    /// Recommended refresh interval while the browser surface is visible.
    public static let recommendedRefreshSeconds = 2

    private init() {}
}

/// Result of `surface.browser.capture`: a downscaled JPEG of the page plus optional page metadata.
public struct SurfaceBrowserCaptureResult: Codable, Sendable, Equatable {
    /// Canonical base64 of the JPEG image.
    public var imageBase64: String
    /// Image MIME type, always `image/jpeg`.
    public var mimeType: String
    /// Pixel width of the sent image.
    public var width: Int
    /// Pixel height of the sent image.
    public var height: Int
    /// Pixel width of cmux's original screenshot.
    public var sourceWidth: Int
    /// Pixel height of cmux's original screenshot.
    public var sourceHeight: Int
    /// Page URL, omitted when cmux did not report one.
    public var url: String?
    /// Page title, omitted when cmux did not report one.
    public var title: String?
    /// Capture time in milliseconds since 1970. Equal values mean the same capture was reused.
    public var capturedAt: Int64

    /// Creates a browser-capture result.
    public init(imageBase64: String, mimeType: String, width: Int, height: Int,
                sourceWidth: Int, sourceHeight: Int, url: String?, title: String?, capturedAt: Int64) {
        self.imageBase64 = imageBase64; self.mimeType = mimeType; self.width = width; self.height = height
        self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
        self.url = url; self.title = title; self.capturedAt = capturedAt
    }

    /// Decodes and validates a browser-capture result.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let dimensions = 1...SurfaceBrowserCaptureLimits.maxDimension
        guard c.contains(.imageBase64), let imageBase64 = try? c.decode(String.self, forKey: .imageBase64), !imageBase64.isEmpty else { throw RemoteProtocolError.missingField("image_base64") }
        guard c.contains(.mimeType), let mimeType = try? c.decode(String.self, forKey: .mimeType) else { throw RemoteProtocolError.missingField("mime_type") }
        guard mimeType == "image/jpeg" else { throw RemoteProtocolError.invalidField("mime_type") }
        guard let width = try? c.decode(Int.self, forKey: .width), dimensions.contains(width) else { throw RemoteProtocolError.invalidField("width") }
        guard let height = try? c.decode(Int.self, forKey: .height), dimensions.contains(height) else { throw RemoteProtocolError.invalidField("height") }
        guard let sourceWidth = try? c.decode(Int.self, forKey: .sourceWidth), sourceWidth > 0 else { throw RemoteProtocolError.invalidField("source_width") }
        guard let sourceHeight = try? c.decode(Int.self, forKey: .sourceHeight), sourceHeight > 0 else { throw RemoteProtocolError.invalidField("source_height") }
        guard let capturedAt = try? c.decode(Int64.self, forKey: .capturedAt) else { throw RemoteProtocolError.invalidField("captured_at") }
        let url = try c.decodeIfPresent(String.self, forKey: .url)
        let title = try c.decodeIfPresent(String.self, forKey: .title)
        self.init(imageBase64: imageBase64, mimeType: mimeType, width: width, height: height,
                  sourceWidth: sourceWidth, sourceHeight: sourceHeight, url: url, title: title, capturedAt: capturedAt)
    }

    /// Decodes the JPEG bytes after enforcing canonical base64 and the capture-size limit.
    ///
    /// - Returns: The decoded JPEG bytes.
    /// - Throws: ``RemoteProtocolError`` for malformed or oversized data.
    public func decodedImage() throws -> Data {
        guard let data = Data(base64Encoded: imageBase64), data.base64EncodedString() == imageBase64 else { throw RemoteProtocolError.invalidBase64 }
        guard data.count <= SurfaceBrowserCaptureLimits.maxImageBytes else { throw RemoteProtocolError.chunkTooLarge(maxBytes: SurfaceBrowserCaptureLimits.maxImageBytes) }
        return data
    }

    private enum CodingKeys: String, CodingKey {
        case imageBase64, mimeType, width, height, sourceWidth, sourceHeight, url, title, capturedAt
    }
}
