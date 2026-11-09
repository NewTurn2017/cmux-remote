import SharedKit
import SwiftUI

struct FeedListView: View {
    @Bindable var store: FeedStore
    let isConnected: Bool

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                page(now: context.date)
            }
        }
        .refreshable { await store.refresh(fresh: true) }
        .background(CmuxTheme.canvas)
        .task(id: store.noticeID) {
            guard store.notice == .alreadyHandled else { return }
            let id = store.noticeID
            try? await Task.sleep(for: .seconds(4))
            store.dismissNotice(id: id)
        }
        .accessibilityIdentifier("FeedListView")
    }

    private func page(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(liveCount: store.liveCount(at: now))
            if let notice = store.notice {
                noticeBanner(notice)
            }
            if let failure = visibleFailure {
                statusBanner(failure.message, color: failure == .disconnected ? CmuxTheme.muted : CmuxTheme.accentYellow)
                    .accessibilityIdentifier(failure == .disconnected ? "FeedDisconnectedBanner" : "FeedErrorBanner")
            }
            CmuxRule(title: "pending")
            content(now: now)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 40)
    }

    private func header(liveCount: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "agents")
                .cmuxDisplay(28)
                .foregroundStyle(CmuxTheme.ink)
            Text(verbatim: "[\(liveCount)]")
                .cmuxDisplay(14)
                .foregroundStyle(CmuxTheme.muted)
                .accessibilityIdentifier("FeedPendingCount")
            Spacer()
        }
    }

    private var visibleFailure: FeedListFailure? {
        if !isConnected { return .disconnected }
        if case .failed(let failure) = store.state { return failure }
        return nil
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let entries = store.entries(at: now)
        if entries.isEmpty {
            emptyCard
        } else {
            LazyVStack(spacing: 12) {
                ForEach(entries) { entry in
                    switch entry {
                    case .live(let item):
                        FeedItemCard(item: item, store: store, isConnected: isConnected, now: now)
                    case .departed(let departed):
                        FeedDepartedCard(departed: departed)
                    }
                }
                if store.omittedCount > 0 {
                    Text(String(
                        format: String(localized: "feed.list.omitted", defaultValue: "%d older requests aren't shown. Answer them on the Mac."),
                        store.omittedCount
                    ))
                    .cmuxMono(11)
                    .foregroundStyle(CmuxTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("FeedOmittedNotice")
                }
            }
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Text(emptyTitle)
                .cmuxDisplay(13)
                .foregroundStyle(CmuxTheme.muted)
            Text(String(localized: "feed.list.empty_detail", defaultValue: "Questions, permission requests and plans from your agents appear here."))
                .cmuxMono(11)
                .foregroundStyle(CmuxTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 16)
        .background(CmuxTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("FeedEmptyState")
    }

    private var emptyTitle: String {
        switch store.state {
        case .idle, .loading:
            return String(localized: "feed.list.loading", defaultValue: "[ loading… ]")
        default:
            return String(localized: "feed.list.empty", defaultValue: "[ no pending requests ]")
        }
    }

    private func noticeBanner(_ notice: FeedNotice) -> some View {
        switch notice {
        case .alreadyHandled:
            return statusBanner(
                String(localized: "feed.notice.already_handled", defaultValue: "Already answered on the Mac or another device."),
                color: CmuxTheme.accentBlue
            )
            .accessibilityIdentifier("FeedAlreadyHandledNotice")
        case .verifying:
            return statusBanner(
                String(localized: "feed.notice.verifying", defaultValue: "Checking whether the answer arrived…"),
                color: CmuxTheme.accentYellow
            )
            .accessibilityIdentifier("FeedVerifyingNotice")
        }
    }

    private func statusBanner(_ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(color)
                .frame(width: 3)
                .accessibilityHidden(true)
            Text(text)
                .cmuxMono(12)
                .foregroundStyle(CmuxTheme.inkDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .padding(.trailing, 10)
        .background(CmuxTheme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
