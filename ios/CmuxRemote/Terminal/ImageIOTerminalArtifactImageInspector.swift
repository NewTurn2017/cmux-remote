import Foundation
import ImageIO

struct ImageIOTerminalArtifactImageInspector: TerminalArtifactImageInspecting {
    func dimensions(of url: URL) throws -> TerminalArtifactImageDimensions {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = Self.integer(properties[kCGImagePropertyPixelWidth]),
              let height = Self.integer(properties[kCGImagePropertyPixelHeight]),
              width > 0,
              height > 0
        else {
            throw TerminalArtifactStoreError.malformedChunk
        }
        return TerminalArtifactImageDimensions(width: width, height: height)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Int { return value }
        return nil
    }
}
