import SwiftUI
import UIKit

struct ZoomableImageConfiguration: Equatable {
    enum Fit: Equatable {
        /// The whole image fits inside the view, centered.
        case whole
        /// The image fills the view width; taller images scroll vertically from the top.
        case width
    }

    var fit: Fit
    /// Space kept clear at the top for an overlaid header.
    var headerClearance: CGFloat
    var imageAccessibilityIdentifier: String
    /// Zoom scale a double tap toggles to; nil disables double tap.
    var doubleTapZoomScale: CGFloat?
    /// Keep the zoom scale and offset when a replacement image has the same size.
    var preservesZoomOnSameSize: Bool

    static let artifactViewer = ZoomableImageConfiguration(
        fit: .whole,
        headerClearance: 68,
        imageAccessibilityIdentifier: "TerminalArtifactViewerImage",
        doubleTapZoomScale: nil,
        preservesZoomOnSameSize: false
    )

    static let browserCapture = ZoomableImageConfiguration(
        fit: .width,
        headerClearance: 0,
        imageAccessibilityIdentifier: "BrowserViewerImage",
        doubleTapZoomScale: 2.5,
        preservesZoomOnSameSize: true
    )
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let accessibilityLabel: String
    var configuration: ZoomableImageConfiguration

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        let view = ZoomableImageScrollView(configuration: configuration)
        view.setImage(image, accessibilityLabel: accessibilityLabel)
        return view
    }

    func updateUIView(_ view: ZoomableImageScrollView, context: Context) {
        view.setImage(image, accessibilityLabel: accessibilityLabel)
    }
}

final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    let configuration: ZoomableImageConfiguration
    let imageView = UIImageView()
    private var sourceSize: CGSize = .zero
    private var laidOutBounds: CGSize = .zero

    init(configuration: ZoomableImageConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        decelerationRate = .fast
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityIdentifier = configuration.imageAccessibilityIdentifier
        addSubview(imageView)

        if configuration.doubleTapZoomScale != nil {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: UIImage, accessibilityLabel: String) {
        guard imageView.image !== image || imageView.accessibilityLabel != accessibilityLabel else { return }
        let keepsLayout = configuration.preservesZoomOnSameSize
            && sourceSize != .zero
            && sourceSize == image.size
        imageView.image = image
        imageView.accessibilityLabel = accessibilityLabel
        imageView.accessibilityValue = "\(Int(image.size.width))x\(Int(image.size.height))"
        guard !keepsLayout else { return }
        sourceSize = image.size
        laidOutBounds = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, sourceSize.width > 0, sourceSize.height > 0 else { return }
        var scrollsToTop = false
        if laidOutBounds != bounds.size {
            let headerClearance = configuration.headerClearance
            let available = CGSize(width: bounds.width, height: max(1, bounds.height - headerClearance))
            let fit: CGFloat
            switch configuration.fit {
            case .whole:
                fit = min(available.width / sourceSize.width, available.height / sourceSize.height)
            case .width:
                fit = available.width / sourceSize.width
            }
            let fitted = CGSize(width: sourceSize.width * fit, height: sourceSize.height * fit)
            minimumZoomScale = 1
            maximumZoomScale = 6
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            contentInset = UIEdgeInsets(top: headerClearance, left: 0, bottom: 0, right: 0)
            laidOutBounds = bounds.size
            scrollsToTop = configuration.fit == .width
        }
        centerImage()
        if scrollsToTop {
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let target = configuration.doubleTapZoomScale else { return }
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let scale = min(target, maximumZoomScale)
        let point = recognizer.location(in: imageView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(
            to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
            animated: true
        )
    }

    private func centerImage() {
        let headerClearance = configuration.headerClearance
        let availableHeight = max(0, bounds.height - headerClearance)
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (availableHeight - contentSize.height) / 2) + headerClearance
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: 0, right: horizontal)
    }
}
