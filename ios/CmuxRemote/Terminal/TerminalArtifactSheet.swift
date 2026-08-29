import SwiftUI
import SharedKit

struct TerminalFilesSheet: View {
    @Bindable var store: TerminalArtifactStore
    let onClose: () -> Void
    let fixtureReleaseAction: (() -> Void)?

    @State private var viewerURL: URL?
    @State private var viewerFilename = ""
    @State private var viewerError: TerminalArtifactRowState?
    @State private var openingArtifactID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(CmuxTheme.divider)
            content
            privacyFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CmuxTheme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("TerminalFilesSheet")
        .overlay(alignment: .bottomTrailing) {
            #if DEBUG
            if let fixtureReleaseAction {
                Button(action: fixtureReleaseAction) {
                    Color.clear
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("FeatureFixtureReleaseStaleResponse")
            }
            #endif
        }
        .fullScreenCover(isPresented: viewerPresentation) {
            if let viewerURL {
                TerminalArtifactViewer(
                    url: viewerURL,
                    filename: viewerFilename,
                    onClose: closeViewer
                )
            }
        }
        .onDisappear {
            closeViewer()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    localized: "terminal.artifact.sheet.title",
                    defaultValue: "Terminal files"
                ))
                .cmuxDisplay(14)
                .foregroundStyle(CmuxTheme.ink)

                Text(String(
                    localized: "terminal.artifact.sheet.subtitle",
                    defaultValue: "Recent uploads and files visible in this terminal"
                ))
                .cmuxMono(11)
                .foregroundStyle(CmuxTheme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(CmuxTheme.accentBlue)
                    .frame(width: 44, height: 44)
                    .background(CmuxTheme.surfaceSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .disabled(store.identity == nil || store.state == .loading)
            .accessibilityIdentifier("TerminalFilesRefreshButton")
            .accessibilityLabel(String(
                localized: "terminal.artifact.sheet.refresh",
                defaultValue: "Refresh terminal files"
            ))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(CmuxTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(CmuxTheme.surfaceSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("TerminalFilesCloseButton")
            .accessibilityLabel(String(
                localized: "terminal.artifact.sheet.close",
                defaultValue: "Close terminal files"
            ))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(spacing: 8) {
                switch store.state {
                case .idle, .loading:
                    stateCard(
                        state: .loading,
                        detail: String(
                            localized: "terminal.artifact.sheet.loading",
                            defaultValue: "Scanning visible terminal output for files."
                        )
                    )
                case .unavailable:
                    stateCard(
                        state: .unavailable,
                        detail: String(
                            localized: "terminal.artifact.sheet.unavailable",
                            defaultValue: "This relay does not provide terminal file previews."
                        )
                    )
                case .failed:
                    stateCard(
                        state: .error,
                        detail: String(
                            localized: "terminal.artifact.sheet.failed",
                            defaultValue: "Terminal files could not be loaded."
                        )
                    )
                case .ready:
                    if store.artifacts.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.artifacts) { artifact in
                            TerminalArtifactRow(
                                artifact: artifact,
                                store: store,
                                onOpen: openViewer
                            )
                        }
                    }
                }

                if let viewerError {
                    stateCard(state: viewerError, detail: viewerError.localizedDetail)
                }

                #if DEBUG
                if failureFixturesEnabled {
                    ForEach(failureFixtureStates, id: \.accessibilityIdentifier) { state in
                        stateCard(state: state, detail: state.localizedDetail)
                    }
                }
                #endif
            }
            .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityLabel(String(
            localized: "terminal.artifact.sheet.list",
            defaultValue: "Terminal file list"
        ))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(CmuxTheme.muted)
                .accessibilityHidden(true)
            Text(String(
                localized: "terminal.artifact.sheet.empty",
                defaultValue: "No visible files found"
            ))
            .cmuxMono(13, weight: .medium)
            .foregroundStyle(CmuxTheme.ink)
            Text(String(
                localized: "terminal.artifact.sheet.empty_detail",
                defaultValue: "Upload a file or print its path in the active terminal, then refresh."
            ))
            .cmuxMono(11)
            .foregroundStyle(CmuxTheme.inkDim)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(20)
        .background(CmuxTheme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("TerminalArtifactEmptyState")
    }

    private var privacyFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(CmuxTheme.accentGreen)
                .accessibilityHidden(true)
            Text(String(
                localized: "terminal.artifact.viewer.cleanup_note",
                defaultValue: "Viewer copies are removed when closed."
            ))
            .cmuxMono(10)
            .foregroundStyle(CmuxTheme.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CmuxTheme.surfaceSunken)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("TerminalArtifactViewerTempCount")
        .accessibilityValue(viewerURL == nil ? "0" : "1")
    }

    private func stateCard(state: TerminalArtifactRowState, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: stateIcon(state))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(stateTint(state))
                .frame(width: 32, height: 32)
                .background(CmuxTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.localizedLabel)
                    .cmuxMono(12, weight: .medium)
                    .foregroundStyle(CmuxTheme.ink)
                Text(detail)
                    .cmuxMono(11)
                    .foregroundStyle(CmuxTheme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(CmuxTheme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(stateTint(state).opacity(0.7), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(state.accessibilityIdentifier)
    }

    private func stateIcon(_ state: TerminalArtifactRowState) -> String {
        switch state {
        case .loading: return "arrow.clockwise"
        case .ready: return "checkmark"
        case .generic: return "doc"
        case .stale, .fileChanged: return "clock.badge.exclamationmark"
        case .unavailable: return "wifi.slash"
        case .corrupt: return "photo.badge.exclamationmark"
        case .oversized, .byteCap, .pixelCap: return "externaldrive.badge.exclamationmark"
        case .error: return "exclamationmark.triangle"
        }
    }

    private func stateTint(_ state: TerminalArtifactRowState) -> Color {
        switch state {
        case .ready: return CmuxTheme.accentGreen
        case .loading: return CmuxTheme.accentBlue
        case .generic: return CmuxTheme.inkDim
        case .stale, .fileChanged: return CmuxTheme.accentYellow
        case .unavailable: return CmuxTheme.muted
        case .corrupt, .oversized, .byteCap, .pixelCap, .error: return CmuxTheme.accentRed
        }
    }

    private var viewerPresentation: Binding<Bool> {
        Binding(
            get: { viewerURL != nil },
            set: { isPresented in
                if !isPresented { closeViewer() }
            }
        )
    }

    private func refresh() {
        guard let identity = store.identity else { return }
        viewerError = nil
        Task { await store.activate(identity: identity) }
    }

    private func openViewer(_ artifact: TerminalArtifact) {
        guard openingArtifactID == nil else { return }
        openingArtifactID = artifact.artifactId
        viewerError = nil
        Task { @MainActor in
            defer { openingArtifactID = nil }
            do {
                let url = try await store.openViewer(for: artifact)
                viewerFilename = artifact.filename
                viewerURL = url
            } catch is CancellationError {
                return
            } catch {
                viewerURL = nil
                viewerError = TerminalArtifactRowState(error: error)
            }
        }
    }

    private func closeViewer() {
        viewerURL = nil
        viewerFilename = ""
        Task { await store.dismissViewer() }
    }

    #if DEBUG
    private var failureFixturesEnabled: Bool {
        ProcessInfo.processInfo.environment["CMUX_UI_TEST_FILE_FEATURE_FIXTURES"] == "1"
            && ProcessInfo.processInfo.environment["CMUX_UI_TEST_ARTIFACT_SCENARIO"] == "failures"
    }

    private var failureFixtureStates: [TerminalArtifactRowState] {
        [.stale, .corrupt, .oversized, .byteCap, .pixelCap, .unavailable, .error]
    }
    #endif
}
