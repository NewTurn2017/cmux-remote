import SharedKit
import SwiftUI

struct ClaudeSessionListView: View {
    @Bindable var store: ClaudeTranscriptStore
    let isConnected: Bool
    let hostGeneration: Int

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                page(now: context.date)
            }
        }
        .refreshable { await store.loadSessions() }
        .background(CmuxTheme.canvas)
        .task(id: "\(hostGeneration)|\(isConnected)") {
            guard isConnected else { return }
            await store.loadSessions()
        }
        .accessibilityIdentifier("ClaudeSessionList")
    }

    private func page(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "history")
                    .cmuxDisplay(28)
                    .foregroundStyle(CmuxTheme.ink)
                Text(verbatim: "[\(store.sessions.count)]")
                    .cmuxDisplay(14)
                    .foregroundStyle(CmuxTheme.muted)
                    .accessibilityIdentifier("ClaudeSessionCount")
                Spacer()
            }
            if let failure = visibleFailure {
                ClaudeStatusBanner(text: failure.message, color: failure == .disconnected ? CmuxTheme.muted : CmuxTheme.accentYellow)
                    .accessibilityIdentifier("ClaudeSessionListError")
            }
            CmuxRule(title: "claude sessions")
            if store.sessions.isEmpty {
                emptyCard
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(store.sessions, id: \.sessionId) { session in
                        row(session, now: now)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 40)
    }

    private var visibleFailure: ClaudeTranscriptFailure? {
        if !isConnected { return .disconnected }
        if case .failed(let failure) = store.sessionsState { return failure }
        return nil
    }

    private func row(_ session: ClaudeSessionSummary, now: Date) -> some View {
        Button {
            Task { await store.open(session) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    statusBadge(session)
                    Spacer(minLength: 4)
                    if let modifiedAt = session.modifiedAt {
                        Text(verbatim: ClaudeTranscriptFormatting.relative(milliseconds: modifiedAt, now: now))
                            .cmuxMono(11)
                            .foregroundStyle(CmuxTheme.muted)
                            .lineLimit(1)
                            .accessibilityIdentifier("ClaudeSession-\(session.sessionId)-Modified")
                    }
                }
                Text(verbatim: session.title?.isEmpty == false ? session.title! : String(localized: "transcript.session.untitled", defaultValue: "(untitled)"))
                    .cmuxMono(14, weight: .medium)
                    .foregroundStyle(CmuxTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let place = ClaudeTranscriptFormatting.place(cwd: session.cwd, branch: session.gitBranch) {
                    Text(verbatim: place)
                        .cmuxMono(11)
                        .foregroundStyle(CmuxTheme.inkDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(14)
            .background(CmuxTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(session.status == "live" ? CmuxTheme.accentGreen.opacity(0.6) : CmuxTheme.divider, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ClaudeSession-\(session.sessionId)")
    }

    @ViewBuilder
    private func statusBadge(_ session: ClaudeSessionSummary) -> some View {
        if session.status == "live" {
            HStack(spacing: 4) {
                Circle()
                    .fill(CmuxTheme.accentGreen)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(verbatim: "LIVE")
                    .cmuxDisplay(10)
                    .foregroundStyle(CmuxTheme.accentGreen)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ClaudeSession-\(session.sessionId)-Live")
        } else if let status = session.status, !status.isEmpty {
            Text(verbatim: status.uppercased())
                .cmuxDisplay(10)
                .foregroundStyle(CmuxTheme.muted)
        }
    }

    private var emptyCard: some View {
        Text(emptyTitle)
            .cmuxDisplay(13)
            .foregroundStyle(CmuxTheme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(CmuxTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(CmuxTheme.divider, lineWidth: 1)
            )
            .accessibilityIdentifier("ClaudeSessionListEmpty")
    }

    private var emptyTitle: String {
        switch store.sessionsState {
        case .idle, .loading:
            return String(localized: "transcript.sessions.loading", defaultValue: "[ loading… ]")
        default:
            return String(localized: "transcript.sessions.empty", defaultValue: "[ no claude sessions ]")
        }
    }
}

enum ClaudeTranscriptFormatting {
    static func relative(milliseconds: Int64, now: Date) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    /// Last folder of the working directory and the branch, such as `agent-lab · main`.
    static func place(cwd: String?, branch: String?) -> String? {
        let folder = cwd.flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent }
        let parts = [folder, branch?.isEmpty == false ? branch : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func time(milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000).formatted(date: .omitted, time: .shortened)
    }
}

struct ClaudeStatusBanner: View {
    let text: String
    let color: Color

    var body: some View {
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
