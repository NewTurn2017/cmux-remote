import SwiftUI

struct DocumentViewer: View {
    enum Content: Equatable {
        case loading
        case loaded(RenderedDocument)
        case failed(DocumentLoadFailure)
    }

    static let textScaleRange: ClosedRange<Double> = 0.8...1.6
    static let textScaleStep = 0.1

    let title: String
    let content: Content
    var isRefreshing = false
    var canRefresh = true
    var onRefresh: (() -> Void)?
    var onClose: (() -> Void)?
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0

    @AppStorage("cmux.documentTextScale") private var textScale: Double = 1
    @State private var copiedRevision: String?

    private var scale: CGFloat { CGFloat(textScale) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(CmuxTheme.divider)
            if case .loaded(let rendered) = content, rendered.document.isTruncated {
                truncationNotice(rendered.document)
            }
            bodyContent
        }
        .padding(.top, max(0, topContentInset))
        .padding(.bottom, max(0, bottomContentInset))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CmuxTheme.terminal.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DocumentViewer")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CmuxTheme.accentGreen)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .cmuxMono(13, weight: .medium)
                .foregroundStyle(CmuxTheme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("DocumentViewerTitle")
            Spacer(minLength: 4)
            iconButton(
                "textformat.size.smaller",
                identifier: "DocumentViewerTextSmallerButton",
                label: String(localized: "document.viewer.text_smaller", defaultValue: "Smaller text"),
                isEnabled: textScale > Self.textScaleRange.lowerBound + 0.001
            ) { adjustTextScale(by: -Self.textScaleStep) }
            iconButton(
                "textformat.size.larger",
                identifier: "DocumentViewerTextLargerButton",
                label: String(localized: "document.viewer.text_larger", defaultValue: "Larger text"),
                isEnabled: textScale < Self.textScaleRange.upperBound - 0.001
            ) { adjustTextScale(by: Self.textScaleStep) }
            iconButton(
                copiedRevision == loadedDocument?.revision && copiedRevision != nil ? "checkmark" : "doc.on.doc",
                identifier: "DocumentViewerCopyAllButton",
                label: copiedRevision == loadedDocument?.revision && copiedRevision != nil
                    ? String(localized: "document.viewer.copied", defaultValue: "Copied")
                    : String(localized: "document.viewer.copy_all", defaultValue: "Copy all"),
                isEnabled: loadedDocument != nil,
                action: copyAll
            )
            if let onRefresh {
                iconButton(
                    "arrow.clockwise",
                    identifier: "DocumentViewerRefreshButton",
                    label: String(localized: "document.viewer.refresh", defaultValue: "Refresh document"),
                    isEnabled: canRefresh,
                    action: onRefresh
                )
            }
            if let onClose {
                iconButton(
                    "xmark",
                    identifier: "DocumentViewerCloseButton",
                    label: String(localized: "document.viewer.close", defaultValue: "Close document"),
                    isEnabled: true,
                    action: onClose
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(CmuxTheme.surface)
    }

    private func truncationNotice(_ document: TextDocument) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "scissors")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(CmuxTheme.accentYellow)
                .accessibilityHidden(true)
            Text(String(
                format: String(localized: "document.viewer.truncated", defaultValue: "Showing the first %1$@ of %2$@."),
                ByteCountFormatter.string(fromByteCount: Int64(document.displayedBytes), countStyle: .file),
                ByteCountFormatter.string(fromByteCount: Int64(document.totalBytes), countStyle: .file)
            ))
            .cmuxMono(11)
            .foregroundStyle(CmuxTheme.inkDim)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CmuxTheme.surfaceSunken)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("DocumentViewerTruncationNotice")
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch content {
        case .loading:
            VStack(spacing: 12) {
                ProgressView().tint(CmuxTheme.accentBlue)
                Text(String(localized: "document.viewer.loading", defaultValue: "Loading document…"))
                    .cmuxMono(12)
                    .foregroundStyle(CmuxTheme.inkDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("DocumentViewerLoading")
        case .failed(let failure):
            failureView(failure)
        case .loaded(let rendered):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10 * scale) {
                    switch rendered.body {
                    case .markdown(let blocks):
                        ForEach(blocks) { MarkdownBlockView(block: $0, scale: scale) }
                    case .plain(let chunks):
                        ForEach(chunks.indices, id: \.self) { index in
                            Text(verbatim: chunks[index])
                                .font(CmuxFont.body(12 * scale))
                                .foregroundStyle(CmuxTheme.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
            }
            .overlay(alignment: .top) {
                if isRefreshing {
                    ProgressView()
                        .tint(CmuxTheme.accentBlue)
                        .padding(8)
                        .accessibilityIdentifier("DocumentViewerRefreshing")
                }
            }
            .accessibilityIdentifier("DocumentViewerContent")
        }
    }

    private func failureView(_ failure: DocumentLoadFailure) -> some View {
        VStack(spacing: 12) {
            Image(systemName: failure == .disconnected ? "wifi.slash" : "exclamationmark.triangle")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(failure == .disconnected ? CmuxTheme.muted : CmuxTheme.accentYellow)
                .accessibilityHidden(true)
            Text(failure.message)
                .cmuxMono(13)
                .foregroundStyle(CmuxTheme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if failure.canRetry, let onRefresh {
                Button(action: onRefresh) {
                    Text(String(localized: "document.error.retry", defaultValue: "Try again"))
                        .cmuxMono(12, weight: .medium)
                        .foregroundStyle(CmuxTheme.accentBlue)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(CmuxTheme.surfaceSunken)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(!canRefresh)
                .accessibilityIdentifier("DocumentViewerRetryButton")
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(failure.accessibilityIdentifier)
    }

    private func iconButton(
        _ systemName: String,
        identifier: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isEnabled ? CmuxTheme.accentBlue : CmuxTheme.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }

    private var loadedDocument: TextDocument? {
        if case .loaded(let rendered) = content { return rendered.document }
        return nil
    }

    private func adjustTextScale(by step: Double) {
        let next = (textScale + step).clamped(to: Self.textScaleRange)
        textScale = (next * 10).rounded() / 10
    }

    private func copyAll() {
        guard let document = loadedDocument else { return }
        SystemTerminalClipboard().write(document.text)
        copiedRevision = document.revision
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
