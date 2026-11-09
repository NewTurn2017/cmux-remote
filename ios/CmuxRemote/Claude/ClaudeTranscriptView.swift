import SharedKit
import SwiftUI

struct ClaudeTranscriptView: View {
    @Bindable var store: ClaudeTranscriptStore
    let session: ClaudeSessionSummary
    let isConnected: Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var isNearBottom = true
    @State private var initialScrollDone = false
    @State private var olderLoadArmed = true
    /// Row at the top of the visible area, kept by SwiftUI while older rows are inserted above.
    @State private var topRowID: String?
    @State private var restoreRowID: String?
    @State private var viewportHeight: CGFloat = 0

    private static let bottomID = "TranscriptBottom"
    private static let scrollSpace = "ClaudeTranscriptScrollSpace"
    static let stackSpace = "ClaudeTranscriptStackSpace"
    /// How close the end of the transcript must be to the visible bottom to count as "at the bottom".
    private static let nearBottomSlack: CGFloat = 120
    /// Older pages start loading while this many rows are still above the top row, so the scroll
    /// view is not pinned to its top edge when they are inserted.
    private static let olderPrefetchRows = 2

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(CmuxTheme.canvas)
        .task(id: liveLoopKey) {
            await store.runLiveLoop(
                isConnected: isConnected,
                isActive: scenePhase == .active,
                isNearBottom: isNearBottom
            )
        }
    }

    private var liveLoopKey: String {
        [
            session.sessionId,
            isConnected ? "connected" : "offline",
            scenePhase == .active ? "active" : "inactive",
            isNearBottom ? "bottom" : "scrolled",
            store.transcriptState == .loaded ? "loaded" : "not-loaded",
        ].joined(separator: "|")
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    store.close()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text(String(localized: "transcript.back", defaultValue: "Sessions").uppercased())
                            .cmuxDisplay(11)
                    }
                    .foregroundStyle(CmuxTheme.accentBlue)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("TranscriptBack")
                Spacer(minLength: 4)
                if session.status == "live" {
                    Text(verbatim: "● LIVE")
                        .cmuxDisplay(10)
                        .foregroundStyle(CmuxTheme.accentGreen)
                        .accessibilityIdentifier("TranscriptLive")
                }
                Button {
                    Task { await store.refreshLatest() }
                } label: {
                    Group {
                        if store.isRefreshingLatest {
                            ProgressView().controlSize(.small).tint(CmuxTheme.muted)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .foregroundStyle(CmuxTheme.inkDim)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isConnected || store.transcriptState != .loaded)
                .accessibilityLabel(String(localized: "transcript.refresh", defaultValue: "Check for new messages"))
                .accessibilityIdentifier("TranscriptRefresh")
            }
            Text(verbatim: session.title?.isEmpty == false ? session.title! : String(localized: "transcript.session.untitled", defaultValue: "(untitled)"))
                .cmuxMono(15, weight: .medium)
                .foregroundStyle(CmuxTheme.ink)
                .lineLimit(2)
                .accessibilityIdentifier("TranscriptTitle")
            if let place = ClaudeTranscriptFormatting.place(cwd: session.cwd, branch: session.gitBranch) {
                Text(verbatim: place)
                    .cmuxMono(11)
                    .foregroundStyle(CmuxTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(CmuxTheme.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CmuxTheme.divider).frame(height: 1).accessibilityHidden(true)
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        switch store.transcriptState {
        case .failed(let failure):
            failureCard(failure)
        case .idle, .loading:
            if store.timeline.rows.isEmpty {
                placeholder(String(localized: "transcript.loading", defaultValue: "[ loading… ]"))
            } else {
                transcript
            }
        case .loaded:
            if store.timeline.rows.isEmpty, store.timeline.olderBefore == nil, !store.isLoadingOlder {
                placeholder(String(localized: "transcript.empty", defaultValue: "[ no messages yet ]"))
            } else {
                transcript
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if #available(iOS 18.0, *) {
            ClaudeTranscriptOffsetKeepingScroll(store: store, isNearBottom: $isNearBottom) {
                transcriptStack
            }
        } else {
            legacyTranscript
        }
    }

    private var transcriptStack: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) { top }
                .frame(maxWidth: .infinity)
            ForEach(store.timeline.rows) { row in
                ClaudeTranscriptEntryView(row: row, store: store)
                    .id(row.id)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(
                            key: TranscriptRowTopsKey.self,
                            value: [row.id: proxy.frame(in: .named(Self.stackSpace)).minY]
                        )
                    })
            }
            bottom
            Color.clear
                .frame(height: 1)
                .id(Self.bottomID)
                .background(edgeReader(TranscriptBottomEdgeKey.self) { $0.minY })
        }
        .coordinateSpace(name: Self.stackSpace)
        .scrollTargetLayout()
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// iOS 17: older pages load a little before the top and the previous top row is scrolled back
    /// into place. iOS 18 and later use ``ClaudeTranscriptOffsetKeepingScroll`` instead.
    private var legacyTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                transcriptStack
            }
            .scrollPosition(id: $topRowID, anchor: .top)
            .coordinateSpace(name: Self.scrollSpace)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: TranscriptViewportKey.self, value: proxy.size.height)
            })
            .defaultScrollAnchor(.bottom)
            .accessibilityIdentifier("ClaudeTranscriptScroll")
            .onPreferenceChange(TranscriptViewportKey.self) { height in
                viewportHeight = height
            }
            .onPreferenceChange(TranscriptBottomEdgeKey.self) { minY in
                let near = minY <= viewportHeight + Self.nearBottomSlack
                if near != isNearBottom { isNearBottom = near }
            }
            .onChange(of: topRowID) { _, _ in
                loadOlderIfOldestRowIsOnTop()
            }
            .task(id: store.latestSequence) {
                guard store.latestSequence > 0 else { return }
                if !initialScrollDone || isNearBottom {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
                guard !initialScrollDone else { return }
                await Task.yield()
                initialScrollDone = true
                loadOlderIfOldestRowIsOnTop()
            }
            .onChange(of: store.prependSequence) { _, _ in
                let anchor = restoreRowID ?? store.prependAnchorID
                restoreRowID = nil
                guard !isNearBottom, let anchor else { return }
                proxy.scrollTo(anchor, anchor: .top)
                DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
    }

    /// Older pages load on their own when one of the oldest rows reaches the top. Loading then
    /// waits until the top row has moved away from the start again, so pages never chain.
    private func loadOlderIfOldestRowIsOnTop() {
        guard initialScrollDone, let topRowID,
              let index = store.timeline.rows.firstIndex(where: { $0.id == topRowID })
        else { return }
        guard index < Self.olderPrefetchRows else {
            if !olderLoadArmed, restoreRowID == nil { olderLoadArmed = true }
            return
        }
        guard olderLoadArmed, store.timeline.olderBefore != nil else { return }
        olderLoadArmed = false
        restoreRowID = topRowID
        let attachedBefore = store.prependSequence
        Task {
            await store.loadOlder()
            if store.prependSequence == attachedBefore { restoreRowID = nil }
        }
    }

    /// Reports one edge of a marker view in the scroll view's visible coordinates. When the lazy
    /// stack unloads the marker, the key falls back to its default, which reads as off screen.
    private func edgeReader<Key: PreferenceKey>(_ key: Key.Type, _ edge: @escaping (CGRect) -> CGFloat) -> some View where Key.Value == CGFloat {
        GeometryReader { proxy in
            Color.clear.preference(key: key, value: edge(proxy.frame(in: .named(Self.scrollSpace))))
        }
    }

    @ViewBuilder
    private var top: some View {
        VStack(spacing: 0) {
            if store.timeline.reachedStart {
                Text(String(localized: "transcript.start", defaultValue: "— start of conversation —"))
                    .cmuxMono(11)
                    .foregroundStyle(CmuxTheme.muted)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("TranscriptStart")
            } else if store.isLoadingOlder {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(CmuxTheme.muted)
                    Text(String(localized: "transcript.loading_older", defaultValue: "Loading earlier messages…"))
                        .cmuxMono(11)
                        .foregroundStyle(CmuxTheme.muted)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("TranscriptLoadingOlder")
            } else if let failure = store.olderFailure {
                VStack(spacing: 8) {
                    ClaudeStatusBanner(text: failure.message, color: CmuxTheme.accentYellow)
                    retryButton(id: "TranscriptRetryOlder") { await store.loadOlder() }
                }
            } else if store.timeline.olderBefore != nil {
                Button {
                    Task { await store.loadOlder() }
                } label: {
                    Text(String(localized: "transcript.load_older", defaultValue: "Load earlier messages"))
                        .cmuxDisplay(11)
                        .foregroundStyle(CmuxTheme.accentBlue)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("TranscriptLoadOlder")
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var bottom: some View {
        if let failure = store.latestFailure {
            VStack(spacing: 8) {
                ClaudeStatusBanner(text: failure.message, color: CmuxTheme.accentYellow)
                retryButton(id: "TranscriptRetryLatest") { await store.refreshLatest() }
            }
        }
        if store.timeline.newerTrimmed {
            Button {
                Task { await store.reloadLatest() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 12, weight: .semibold))
                    Text(String(localized: "transcript.jump_latest", defaultValue: "Newer messages were unloaded · Jump to latest"))
                        .cmuxDisplay(11)
                }
                .foregroundStyle(CmuxTheme.accentBlue)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(CmuxTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("TranscriptJumpLatest")
        }
    }

    private func failureCard(_ failure: ClaudeTranscriptFailure) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(failure.message)
                    .cmuxMono(13)
                    .foregroundStyle(failure == .sessionNotFound ? CmuxTheme.accentRed : CmuxTheme.inkDim)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(failure == .sessionNotFound ? "TranscriptSessionNotFound" : "TranscriptError")
                if failure.canRetry {
                    retryButton(id: "TranscriptRetry") { await store.reloadLatest() }
                } else {
                    Button {
                        store.close()
                        Task { await store.loadSessions() }
                    } label: {
                        Text(String(localized: "transcript.back_to_sessions", defaultValue: "Back to sessions").uppercased())
                            .cmuxDisplay(11)
                            .foregroundStyle(CmuxTheme.accentBlue)
                            .frame(minHeight: 40)
                            .padding(.horizontal, 16)
                            .background(CmuxTheme.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("TranscriptBackToSessions")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, 18)
        }
    }

    private func retryButton(id: String, action: @escaping @MainActor () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text(String(localized: "transcript.retry", defaultValue: "Retry").uppercased())
                .cmuxDisplay(11)
                .foregroundStyle(CmuxTheme.accentBlue)
                .frame(minHeight: 40)
                .padding(.horizontal, 16)
                .background(CmuxTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isConnected)
        .accessibilityIdentifier(id)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .cmuxDisplay(13)
            .foregroundStyle(CmuxTheme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("TranscriptPlaceholder")
    }
}

/// iOS 18 and later: keeps the reading position exactly when an older page is attached above.
///
/// The page waits until scrolling has settled. The offset is first moved by the height the new
/// rows added, then a row that was on screen is pinned: whenever its position in the stack changes
/// (estimated heights of the new rows becoming real), the visible top is set again to its old
/// value plus the row's movement. The target never depends on the current offset, so it holds at
/// the very top edge too and cannot oscillate. Touching the scroll view releases the pin.
@available(iOS 18.0, *)
private struct ClaudeTranscriptOffsetKeepingScroll<Content: View>: View {
    @Bindable var store: ClaudeTranscriptStore
    @Binding var isNearBottom: Bool
    @ViewBuilder let content: () -> Content

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var metrics: TranscriptScrollMetrics?
    @State private var restoreFrom: TranscriptScrollMetrics?
    @State private var initialScrollDone = false
    @State private var olderLoadArmed = true
    @State private var idleGate = TranscriptScrollIdleGate()
    @State private var rowTops: [String: CGFloat] = [:]
    /// The store's attach count when ``rowTops`` was last reported, so a pin only uses positions
    /// measured after the older rows were inserted.
    @State private var rowTopsSequence = 0
    @State private var pin: TranscriptReadingPin?

    /// Older pages start loading when the visible top is this close to the start of the content.
    private static var olderPrefetchDistance: CGFloat { 400 }
    private static var nearBottomSlack: CGFloat { 120 }

    var body: some View {
        ScrollView {
            content()
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .accessibilityIdentifier("ClaudeTranscriptScroll")
        .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geometry in
            TranscriptScrollMetrics(geometry: geometry, prependSequence: store.prependSequence)
        } action: { old, new in
            apply(old: old, new: new)
        }
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting { pin = nil }
            idleGate.setIdle(phase == .idle)
        }
        .onPreferenceChange(TranscriptRowTopsKey.self) { tops in
            rowTops = tops
            rowTopsSequence = store.prependSequence
            applyPin()
        }
        .onDisappear { idleGate.setIdle(true) }
        .task(id: store.latestSequence) {
            guard store.latestSequence > 0 else { return }
            pin = nil
            if !initialScrollDone || isNearBottom {
                position.scrollTo(edge: .bottom)
            }
            guard !initialScrollDone else { return }
            await Task.yield()
            initialScrollDone = true
            if let metrics { loadOlderIfNearTop(metrics) }
        }
    }

    private func apply(old: TranscriptScrollMetrics, new: TranscriptScrollMetrics) {
        if new.prependSequence != old.prependSequence {
            restoreFrom = old
        }
        if let from = restoreFrom, new.contentHeight != from.contentHeight {
            restoreFrom = nil
            position.scrollTo(y: from.offsetY + new.contentHeight - from.contentHeight)
        }
        metrics = new
        applyPin()
        let near = new.distanceFromBottom <= Self.nearBottomSlack
        if near != isNearBottom { isNearBottom = near }
        loadOlderIfNearTop(new)
    }

    /// Picks the first row starting inside the visible area, other than the oldest row, which may
    /// absorb the end of a message from the page being attached.
    private func pinReadingPosition() {
        guard let metrics, let oldest = store.timeline.rows.first?.id else {
            pin = nil
            return
        }
        let visibleTop = metrics.distanceFromTop
        let candidate = rowTops
            .filter { $0.key != oldest && $0.value >= visibleTop }
            .min { $0.value < $1.value }
        pin = candidate.map {
            TranscriptReadingPin(rowID: $0.key, rowTop: $0.value, visibleTop: visibleTop, sequence: store.prependSequence)
        }
    }

    private func applyPin() {
        guard let pin, restoreFrom == nil, rowTopsSequence > pin.sequence,
              let metrics, let rowTop = rowTops[pin.rowID]
        else { return }
        let targetTop = pin.visibleTop + (rowTop - pin.rowTop)
        guard abs(targetTop - metrics.distanceFromTop) > 0.5 else { return }
        position.scrollTo(y: targetTop - metrics.visibleTopShift)
    }

    /// Loads one older page when the top comes close, then waits until the top has moved away
    /// again before another automatic load, so pages never chain.
    private func loadOlderIfNearTop(_ metrics: TranscriptScrollMetrics) {
        guard metrics.distanceFromTop < Self.olderPrefetchDistance else {
            if !olderLoadArmed, restoreFrom == nil, !store.isLoadingOlder { olderLoadArmed = true }
            return
        }
        guard initialScrollDone, olderLoadArmed, restoreFrom == nil,
              store.timeline.olderBefore != nil, !store.isLoadingOlder
        else { return }
        olderLoadArmed = false
        let gate = idleGate
        Task {
            await store.loadOlder(attachWhen: {
                await gate.waitUntilIdle()
                pinReadingPosition()
            })
        }
    }
}

private struct TranscriptReadingPin: Equatable {
    let rowID: String
    /// Row top in the stack's coordinates when the pin was taken.
    let rowTop: CGFloat
    /// Visible top in content coordinates when the pin was taken.
    let visibleTop: CGFloat
    /// The store's attach count when the pin was taken, before the older rows were inserted.
    let sequence: Int
}

private struct TranscriptRowTopsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Lets an older page wait while a finger is on the scroll view or it is still moving: the
/// scroll view does not take a programmatic position until scrolling has settled.
@MainActor
private final class TranscriptScrollIdleGate {
    private var isIdle = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func setIdle(_ idle: Bool) {
        isIdle = idle
        guard idle else { return }
        let ready = waiters
        waiters = []
        for waiter in ready { waiter.resume() }
    }

    func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct TranscriptScrollMetrics: Equatable {
    var offsetY: CGFloat
    var contentHeight: CGFloat
    var distanceFromTop: CGFloat
    var distanceFromBottom: CGFloat
    /// Visible top minus content offset; constant for a given set of content insets.
    var visibleTopShift: CGFloat
    var prependSequence: Int

    @available(iOS 18.0, *)
    init(geometry: ScrollGeometry, prependSequence: Int) {
        offsetY = geometry.contentOffset.y
        contentHeight = geometry.contentSize.height
        distanceFromTop = geometry.visibleRect.minY
        distanceFromBottom = geometry.contentSize.height - geometry.visibleRect.maxY
        visibleTopShift = geometry.visibleRect.minY - geometry.contentOffset.y
        self.prependSequence = prependSequence
    }
}

private struct TranscriptBottomEdgeKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

private struct TranscriptViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
