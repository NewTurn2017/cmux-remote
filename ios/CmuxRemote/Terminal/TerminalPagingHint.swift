import SwiftUI

struct TerminalPagingHint: View {
    let edge: TerminalOverscrollPagingPolicy.Edge
    let sent: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: edge == .top ? "chevron.up.2" : "chevron.down.2")
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .cmuxDisplay(10)
        }
        .foregroundStyle(sent ? CmuxTheme.accentGreen : CmuxTheme.ink)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(CmuxTheme.surfaceRaised)
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(sent ? CmuxTheme.accentGreen : CmuxTheme.divider, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("TerminalPagingHint")
        .accessibilityValue(sent ? "sent" : "pulling")
    }

    private var label: String {
        switch edge {
        case .top:
            return String(localized: "terminal.paging.page_up", defaultValue: "Page Up")
        case .bottom:
            return String(localized: "terminal.paging.page_down", defaultValue: "Page Down")
        }
    }
}
