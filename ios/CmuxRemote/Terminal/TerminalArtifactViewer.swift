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
                ZoomableImageView(image: image, accessibilityLabel: filename, configuration: .artifactViewer)
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
