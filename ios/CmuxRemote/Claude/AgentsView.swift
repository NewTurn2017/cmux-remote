import SwiftUI

enum AgentsSection: String, CaseIterable, Hashable {
    case pending
    case history

    var title: String {
        switch self {
        case .pending: return String(localized: "agents.section.pending", defaultValue: "Pending")
        case .history: return String(localized: "agents.section.history", defaultValue: "History")
        }
    }
}

/// Root of the AGENTS tab: pending feed requests and, when the relay offers it, Claude history.
struct AgentsView: View {
    let feed: FeedStore
    let transcripts: ClaudeTranscriptStore
    let feedEnabled: Bool
    let transcriptEnabled: Bool
    let isConnected: Bool
    let hostGeneration: Int
    @Binding var section: AgentsSection

    var body: some View {
        VStack(spacing: 0) {
            if feedEnabled, transcriptEnabled, transcripts.openSession == nil {
                picker
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
            }
            switch shownSection {
            case .pending:
                FeedListView(store: feed, isConnected: isConnected)
            case .history:
                if let session = transcripts.openSession {
                    ClaudeTranscriptView(store: transcripts, session: session, isConnected: isConnected)
                } else {
                    ClaudeSessionListView(store: transcripts, isConnected: isConnected, hostGeneration: hostGeneration)
                }
            }
        }
        .background(CmuxTheme.canvas)
    }

    private var shownSection: AgentsSection {
        if !transcriptEnabled { return .pending }
        if !feedEnabled { return .history }
        return section
    }

    private var picker: some View {
        HStack(spacing: 4) {
            ForEach(AgentsSection.allCases, id: \.self) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 6) {
                        Text(item.title.uppercased())
                            .cmuxDisplay(11)
                        if item == .pending, feed.pendingCount > 0 {
                            Text(verbatim: "\(feed.pendingCount)")
                                .cmuxDisplay(10)
                                .foregroundStyle(CmuxTheme.canvas)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(CmuxTheme.accentRed)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                    }
                    .foregroundStyle(section == item ? CmuxTheme.accentGreen : CmuxTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background {
                        if section == item {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(CmuxTheme.surfaceRaised)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("AgentsSection-\(item.rawValue)")
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
        }
        .padding(4)
        .background(CmuxTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("AgentsSectionPicker")
    }
}
