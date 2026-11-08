import Testing
import UIKit
@testable import CmuxRemote

@Suite("ZoomableImageViewTests")
@MainActor
struct ZoomableImageViewTests {
    private func image(_ width: Int, _ height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func browserView(_ image: UIImage) -> ZoomableImageScrollView {
        let view = ZoomableImageScrollView(configuration: .browserCapture)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        view.setImage(image, accessibilityLabel: "page")
        view.layoutIfNeeded()
        return view
    }

    @Test
    func testWidthFitInitialLayout() {
        let view = browserView(image(600, 1200))

        #expect(view.contentSize == CGSize(width: 300, height: 600))
        #expect(view.contentOffset.y == -view.contentInset.top)
        #expect(view.imageView.accessibilityIdentifier == "BrowserViewerImage")
        #expect(view.imageView.accessibilityValue == "600x1200")
        #expect(view.gestureRecognizers?.contains { ($0 as? UITapGestureRecognizer)?.numberOfTapsRequired == 2 } == true)
    }

    @Test
    func testSameSizeReplacementPreservesZoomAndOffset() {
        let view = browserView(image(600, 1200))
        view.setZoomScale(3, animated: false)
        view.contentOffset = CGPoint(x: 120, y: 400)

        let replacement = image(600, 1200)
        view.setImage(replacement, accessibilityLabel: "page")
        view.layoutIfNeeded()

        #expect(view.imageView.image === replacement)
        #expect(view.zoomScale == 3)
        #expect(view.contentOffset == CGPoint(x: 120, y: 400))
    }

    @Test
    func testSizeChangeResetsToFit() {
        let view = browserView(image(600, 1200))
        view.setZoomScale(3, animated: false)

        view.setImage(image(600, 900), accessibilityLabel: "page")
        view.layoutIfNeeded()

        #expect(view.zoomScale == 1)
        #expect(view.contentSize == CGSize(width: 300, height: 450))
        #expect(view.imageView.accessibilityValue == "600x900")
    }

    @Test
    func testWholeFitMatchesArtifactViewerLayout() {
        let view = ZoomableImageScrollView(configuration: .artifactViewer)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 800)
        view.setImage(image(600, 1200), accessibilityLabel: "shot.png")
        view.layoutIfNeeded()

        // Header clearance 68: fit = min(300/600, 732/1200) = 0.5, centered below the header.
        #expect(view.contentSize == CGSize(width: 300, height: 600))
        let centeredTop: CGFloat = (732 - 600) / 2 + 68
        #expect(view.contentInset.top == centeredTop)
        #expect(view.imageView.accessibilityIdentifier == "TerminalArtifactViewerImage")
        #expect(view.imageView.accessibilityLabel == "shot.png")
        #expect(view.gestureRecognizers?.contains { ($0 as? UITapGestureRecognizer)?.numberOfTapsRequired == 2 } != true)

        view.setZoomScale(3, animated: false)
        view.setImage(image(600, 1200), accessibilityLabel: "shot.png")
        view.layoutIfNeeded()
        #expect(view.zoomScale == 1)
    }
}
