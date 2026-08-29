import SwiftUI
import SharedKit

struct TerminalArtifactRow: View {
    let artifact: TerminalArtifact
    @Bindable var store: TerminalArtifactStore
    let onOpen: (TerminalArtifact) -> Void

    @State private var thumbnailState: TerminalArtifactRowState

    init(
        artifact: TerminalArtifact,
        store: TerminalArtifactStore,
        onOpen: @escaping (TerminalArtifact) -> Void
    ) {
        self.artifact = artifact
        self.store = store
        self.onOpen = onOpen
        _thumbnailState = State(initialValue: artifact.isImage ? .loading : .generic)
    }

    @ViewBuilder
    var body: some View {
        if artifact.isImage {
            Button {
                onOpen(artifact)
            } label: {
                rowContent(showsDisclosure: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("TerminalArtifactRowImage")
            .accessibilityLabel(accessibilitySummary)
            .accessibilityHint(accessibilityHint)
            .task(id: "\(artifact.artifactId)|\(artifact.revision)") {
                await loadThumbnailIfNeeded()
            }
        } else {
            rowContent(showsDisclosure: false)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("TerminalArtifactRowGeneric")
                .accessibilityLabel(accessibilitySummary)
                .accessibilityHint(accessibilityHint)
        }
    }

    private func rowContent(showsDisclosure: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            preview

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: artifact.filename)
                    .cmuxMono(13, weight: .medium)
                    .foregroundStyle(CmuxTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(verbatim: artifact.mimeType)
                    .cmuxDisplay(10)
                    .foregroundStyle(CmuxTheme.accentCyan)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text(verbatim: formattedSize)
                        .cmuxMono(11)
                        .foregroundStyle(CmuxTheme.inkDim)
                    stateLabel
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(CmuxTheme.muted)
                    .frame(width: 20, height: 44)
                    .accessibilityHidden(true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(CmuxTheme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(stateColor.opacity(0.75), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CmuxTheme.surfaceRaised)

            switch thumbnailState {
            case .ready(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityIdentifier("TerminalArtifactThumbnailImage")
                    .accessibilityLabel(String(
                        localized: "terminal.artifact.thumbnail",
                        defaultValue: "Image thumbnail"
                    ))
            case .loading:
                ProgressView()
                    .tint(CmuxTheme.accentBlue)
                    .accessibilityLabel(String(
                        localized: "terminal.artifact.loading_thumbnail",
                        defaultValue: "Loading thumbnail"
                    ))
            case .generic:
                Image(systemName: "doc")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(CmuxTheme.inkDim)
                    .accessibilityHidden(true)
            default:
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(stateColor)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var stateLabel: some View {
        Text(thumbnailState.localizedLabel)
            .cmuxMono(11, weight: .medium)
            .foregroundStyle(stateColor)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(thumbnailState.accessibilityIdentifier)
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(artifact.bytes), countStyle: .file)
    }

    private var stateColor: Color {
        switch thumbnailState {
        case .ready: return CmuxTheme.accentGreen
        case .loading: return CmuxTheme.accentBlue
        case .generic: return CmuxTheme.inkDim
        case .stale, .fileChanged: return CmuxTheme.accentYellow
        case .unavailable: return CmuxTheme.muted
        case .corrupt, .oversized, .byteCap, .pixelCap, .error: return CmuxTheme.accentRed
        }
    }

    private var accessibilitySummary: String {
        String.localizedStringWithFormat(
            String(
                localized: "terminal.artifact.accessibility_summary",
                defaultValue: "%1$@, %2$@, %3$@, %4$@"
            ),
            artifact.filename,
            artifact.mimeType,
            formattedSize,
            thumbnailState.localizedLabel
        )
    }

    private var accessibilityHint: String {
        if artifact.isImage {
            return String(
                localized: "terminal.artifact.open_hint",
                defaultValue: "Opens the full image viewer."
            )
        }
        return String(
            localized: "terminal.artifact.generic_hint",
            defaultValue: "This file type cannot be previewed."
        )
    }

    @MainActor
    private func loadThumbnailIfNeeded() async {
        guard artifact.isImage else {
            thumbnailState = .generic
            return
        }
        guard artifact.bytes <= TerminalArtifactLimits.maxImageBytes else {
            thumbnailState = .oversized
            return
        }
        thumbnailState = .loading
        do {
            let data = try await store.thumbnail(for: artifact)
            try Task.checkCancellation()
            guard let image = decodedThumbnail(data) else {
                thumbnailState = .corrupt
                return
            }
            thumbnailState = .ready(image)
        } catch is CancellationError {
            return
        } catch {
            thumbnailState = TerminalArtifactRowState(error: error)
        }
    }

    private func decodedThumbnail(_ data: Data) -> UIImage? {
        if let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 {
            return image
        }
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["CMUX_UI_TEST_FILE_FEATURE_FIXTURES"] == "1",
           environment["CMUX_UI_TEST_ARTIFACT_SCENARIO"] == "happy",
           data == DemoContent.fileFeatureThumbnailBytes,
           let image = UIImage(data: DemoContent.fileFeatureImageBytes),
           image.size.width > 0,
           image.size.height > 0
        {
            return image
        }
        #endif
        return nil
    }
}
