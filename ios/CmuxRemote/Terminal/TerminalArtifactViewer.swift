import SwiftUI
import UIKit

struct TerminalArtifactViewer: View {
    let url: URL
    let filename: String
    let onClose: () -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            CmuxTheme.terminal
                .ignoresSafeArea()

            if let image {
                TerminalArtifactZoomImage(image: image, filename: filename)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(CmuxTheme.accentRed)
                        .accessibilityHidden(true)
                    Text(String(
                        localized: "terminal.artifact.viewer.corrupt",
                        defaultValue: "The full image could not be displayed."
                    ))
                    .cmuxMono(13)
                    .foregroundStyle(CmuxTheme.ink)
                    .multilineTextAlignment(.center)
                }
                .padding(24)
                .accessibilityIdentifier("TerminalArtifactViewerCorruptState")
            }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(verbatim: filename)
                        .cmuxMono(13, weight: .medium)
                        .foregroundStyle(CmuxTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(CmuxTheme.ink)
                            .frame(width: 44, height: 44)
                            .background(CmuxTheme.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("TerminalArtifactViewerCloseButton")
                    .accessibilityLabel(String(
                        localized: "terminal.artifact.viewer.close",
                        defaultValue: "Close image viewer"
                    ))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(CmuxTheme.surface.opacity(0.96))

                Spacer()
            }
        }
        .task(id: url) {
            image = UIImage(contentsOfFile: url.path)
        }
        .accessibilityAction(.escape, onClose)
    }
}

private struct TerminalArtifactZoomImage: UIViewRepresentable {
    let image: UIImage
    let filename: String

    func makeUIView(context: Context) -> TerminalArtifactZoomScrollView {
        let view = TerminalArtifactZoomScrollView()
        view.setImage(image, filename: filename)
        return view
    }

    func updateUIView(_ view: TerminalArtifactZoomScrollView, context: Context) {
        view.setImage(image, filename: filename)
    }
}

private final class TerminalArtifactZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let artifactImageView = UIImageView()
    private var sourceSize: CGSize = .zero
    private var laidOutBounds: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        decelerationRate = .fast
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never

        artifactImageView.contentMode = .scaleAspectFit
        artifactImageView.isAccessibilityElement = true
        artifactImageView.accessibilityIdentifier = "TerminalArtifactViewerImage"
        addSubview(artifactImageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: UIImage, filename: String) {
        guard artifactImageView.image !== image || artifactImageView.accessibilityLabel != filename else { return }
        artifactImageView.image = image
        artifactImageView.accessibilityLabel = filename
        artifactImageView.accessibilityValue = "\(Int(image.size.width))x\(Int(image.size.height))"
        sourceSize = image.size
        laidOutBounds = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, sourceSize.width > 0, sourceSize.height > 0 else { return }
        if laidOutBounds != bounds.size {
            let headerClearance: CGFloat = 68
            let available = CGSize(width: bounds.width, height: max(1, bounds.height - headerClearance))
            let fit = min(available.width / sourceSize.width, available.height / sourceSize.height)
            let fitted = CGSize(width: sourceSize.width * fit, height: sourceSize.height * fit)
            minimumZoomScale = 1
            maximumZoomScale = 6
            zoomScale = 1
            artifactImageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            contentInset = UIEdgeInsets(top: headerClearance, left: 0, bottom: 0, right: 0)
            laidOutBounds = bounds.size
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        artifactImageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    private func centerImage() {
        let headerClearance: CGFloat = 68
        let availableHeight = max(0, bounds.height - headerClearance)
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (availableHeight - contentSize.height) / 2) + headerClearance
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: 0, right: horizontal)
    }
}
