import Foundation
import ImageIO
import SharedKit
import Testing
@testable import RelayServer

@Suite("BrowserCaptureImageEncoderTests")
struct BrowserCaptureImageEncoderTests {
    @Test func downscalesTheLongEdgeTo1600AndKeepsTheSourceSize() throws {
        let encoded = try BrowserCaptureImageEncoder.encode(png: BrowserCaptureTestImages.png(width: 2400, height: 1800))

        #expect(encoded.width == 1600)
        #expect(encoded.height == 1200)
        #expect(encoded.sourceWidth == 2400)
        #expect(encoded.sourceHeight == 1800)
        #expect(BrowserCaptureTestImages.isJPEG(encoded.jpeg))
        #expect(encoded.jpeg.count <= SurfaceBrowserCaptureLimits.maxImageBytes)
        let decodedSize = Self.pixelSize(of: encoded.jpeg)
        #expect(decodedSize?.0 == 1600)
        #expect(decodedSize?.1 == 1200)
    }

    @Test func downscalesPortraitScreenshotsByHeight() throws {
        let encoded = try BrowserCaptureImageEncoder.encode(png: BrowserCaptureTestImages.png(width: 1200, height: 2400))

        #expect(encoded.width == 800)
        #expect(encoded.height == 1600)
    }

    @Test func neverEnlargesSmallScreenshots() throws {
        let encoded = try BrowserCaptureImageEncoder.encode(png: BrowserCaptureTestImages.png(width: 800, height: 600))

        #expect(encoded.width == 800)
        #expect(encoded.height == 600)
        #expect(encoded.sourceWidth == 800)
        #expect(encoded.sourceHeight == 600)
    }

    @Test func walksTheLadderUntilTheJPEGFitsAndThenRefuses() throws {
        let png = BrowserCaptureTestImages.png(width: 1500, height: 1000, noise: true)
        let ladder = BrowserCaptureImageEncoder.ladder
        func size(_ step: BrowserCaptureImageEncoder.Step) throws -> Int {
            try BrowserCaptureImageEncoder.encode(png: png, maxImageBytes: .max, ladder: [step]).jpeg.count
        }
        let first = try size(ladder[0])
        let lowestFullSize = try size(ladder[2])
        let at1280 = try size(ladder[3])
        let at1024 = try size(ladder[4])
        #expect(ladder.map(\.maxDimension) == [1600, 1600, 1600, 1280, 1024])
        #expect(ladder.map(\.quality) == [0.70, 0.55, 0.40, 0.40, 0.40])
        #expect(first > lowestFullSize)
        #expect(lowestFullSize > at1280)
        #expect(at1280 > at1024)

        let unconstrained = try BrowserCaptureImageEncoder.encode(png: png, maxImageBytes: first)
        #expect(unconstrained.jpeg.count == first)
        #expect(unconstrained.width == 1500)

        let shrunk = try BrowserCaptureImageEncoder.encode(png: png, maxImageBytes: at1280)
        #expect(shrunk.width == 1280)
        #expect(shrunk.jpeg.count <= at1280)
        #expect(shrunk.sourceWidth == 1500)

        let smallest = try BrowserCaptureImageEncoder.encode(png: png, maxImageBytes: at1024)
        #expect(smallest.width == 1024)

        #expect(throws: BrowserCaptureImageEncoder.Failure.sizeLimitExceeded) {
            try BrowserCaptureImageEncoder.encode(png: png, maxImageBytes: at1024 - 1)
        }
    }

    @Test func rejectsDataThatIsNotAnImage() {
        #expect(throws: BrowserCaptureImageEncoder.Failure.unsupportedImage) {
            try BrowserCaptureImageEncoder.encode(png: Data("not a png".utf8))
        }
    }

    @Test func rejectsImagesOverThePixelCap() {
        #expect(throws: BrowserCaptureImageEncoder.Failure.unsupportedImage) {
            try BrowserCaptureImageEncoder.encode(png: BrowserCaptureTestImages.png(width: 20, height: 20), maxPixels: 399)
        }
    }

    private static func pixelSize(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
