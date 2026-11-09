import SharedKit
import SwiftUI

struct NonTerminalSurfaceCard: View {
    let surface: Surface
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0

    private var kind: SurfaceKind { SurfaceKind(surface) }

    var body: some View {
        ZStack {
            CmuxTheme.terminalViewportBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CmuxTheme.accentGreen)
                        .accessibilityHidden(true)
                    Text(kind.accessibilityName)
                        .cmuxDisplay(11)
                        .foregroundStyle(CmuxTheme.muted)
                }

                Text(surface.title)
                    .cmuxMono(14, weight: .medium)
                    .foregroundStyle(CmuxTheme.ink)
                    .lineLimit(2)

                Text(String(
                    localized: "surface.placeholder.message",
                    defaultValue: "This tab can't be shown on mobile yet."
                ))
                .cmuxMono(13)
                .foregroundStyle(CmuxTheme.inkDim)
                .fixedSize(horizontal: false, vertical: true)

                Text(String(
                    localized: "surface.placeholder.detail",
                    defaultValue: "Open it in cmux on your Mac."
                ))
                .cmuxMono(11)
                .foregroundStyle(CmuxTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: 420, alignment: .leading)
            .background(CmuxTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(CmuxTheme.divider, lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.top, max(0, topContentInset))
            .padding(.bottom, max(0, bottomContentInset))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("NonTerminalSurfaceCard")
        }
    }
}
