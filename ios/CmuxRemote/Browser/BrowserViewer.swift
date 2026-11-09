import SwiftUI

/// Read-only view of a cmux browser tab: the latest capture with page title, address and age.
/// Taps and scrolls only zoom and pan the image; nothing is sent to the Mac.
struct BrowserViewer: View {
    let surfaceTitle: String
    let state: SurfaceBrowserState
    var isRefreshing = false
    var canRefresh = true
    let onRefresh: () -> Void
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter
    }()

    private var capture: BrowserCapture? { state.lastCapture }
    private var title: String { capture?.displayTitle(fallback: surfaceTitle) ?? surfaceTitle }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(CmuxTheme.divider)
            if let failure = state.failure, capture != nil {
                staleBanner(failure)
            }
            content
        }
        .padding(.top, max(0, topContentInset))
        .padding(.bottom, max(0, bottomContentInset))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CmuxTheme.terminal.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("BrowserViewer")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CmuxTheme.accentGreen)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .cmuxMono(13, weight: .medium)
                    .foregroundStyle(CmuxTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("BrowserViewerTitle")
                if let capture {
                    Text(verbatim: capture.url ?? String(localized: "browser.viewer.no_url", defaultValue: "No address"))
                        .cmuxMono(11)
                        .foregroundStyle(CmuxTheme.inkDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("BrowserViewerURL")
                    updatedLabel(capture.receivedAt)
                }
            }
            Spacer(minLength: 4)
            refreshButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(CmuxTheme.surface)
    }

    private func updatedLabel(_ receivedAt: Date) -> some View {
        TimelineView(.periodic(from: receivedAt, by: 1)) { context in
            Text(String(
                format: String(localized: "browser.viewer.updated", defaultValue: "Updated %@"),
                Self.relativeFormatter.localizedString(for: receivedAt, relativeTo: max(context.date, receivedAt))
            ))
            .cmuxMono(10)
            .foregroundStyle(CmuxTheme.muted)
            .lineLimit(1)
            .accessibilityIdentifier("BrowserViewerUpdatedAt")
        }
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            Group {
                if isRefreshing {
                    ProgressView().tint(CmuxTheme.accentBlue)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canRefresh ? CmuxTheme.accentBlue : CmuxTheme.muted)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRefresh)
        .accessibilityIdentifier("BrowserViewerRefreshButton")
        .accessibilityLabel(String(localized: "browser.viewer.refresh", defaultValue: "Refresh page screenshot"))
    }

    private func staleBanner(_ failure: BrowserCaptureFailure) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: failure == .disconnected ? "wifi.slash" : "exclamationmark.triangle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(CmuxTheme.accentYellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "browser.viewer.stale", defaultValue: "Couldn't update. Showing the last capture."))
                    .cmuxMono(11, weight: .medium)
                    .foregroundStyle(CmuxTheme.ink)
                Text(failure.message)
                    .cmuxMono(10)
                    .foregroundStyle(CmuxTheme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CmuxTheme.surfaceSunken)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("BrowserViewerStaleBanner")
    }

    @ViewBuilder
    private var content: some View {
        if let capture {
            ZoomableImageView(
                image: capture.image,
                accessibilityLabel: String(
                    format: String(localized: "browser.viewer.image_label", defaultValue: "Screenshot of %@"),
                    title
                ),
                configuration: .browserCapture
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure = state.failure {
            failureView(failure)
        } else {
            VStack(spacing: 12) {
                ProgressView().tint(CmuxTheme.accentBlue)
                Text(String(localized: "browser.viewer.loading", defaultValue: "Loading page…"))
                    .cmuxMono(12)
                    .foregroundStyle(CmuxTheme.inkDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("BrowserViewerLoading")
        }
    }

    private func failureView(_ failure: BrowserCaptureFailure) -> some View {
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
            Button(action: onRefresh) {
                Text(String(localized: "browser.viewer.retry", defaultValue: "Try again"))
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
            .accessibilityIdentifier("BrowserViewerRetryButton")
        }
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(failure.accessibilityIdentifier)
    }
}
