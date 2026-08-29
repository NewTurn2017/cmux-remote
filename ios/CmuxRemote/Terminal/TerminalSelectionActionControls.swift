import SwiftUI

/// Presents fixed, accessible actions for an explicit terminal selection.
struct TerminalSelectionActionControls: View {
    static let controlSize = CGSize(width: 44, height: 44)
    static let symbolSizeRange: ClosedRange<CGFloat> = 15...22

    @ScaledMetric(relativeTo: .body) private var scaledSymbolSize: CGFloat = 15

    let copy: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: copy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: boundedSymbolSize, weight: .bold))
                    .foregroundStyle(CmuxTheme.canvas)
                    .frame(width: Self.controlSize.width, height: Self.controlSize.height)
                    .background(CmuxTheme.terminalSelectionControl)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("TerminalCopySelectionButton")
            .accessibilityLabel(String(
                localized: "terminal.selection.copy",
                defaultValue: "Copy terminal selection"
            ))

            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: boundedSymbolSize, weight: .bold))
                    .foregroundStyle(CmuxTheme.ink)
                    .frame(width: Self.controlSize.width, height: Self.controlSize.height)
                    .background(CmuxTheme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("TerminalCancelSelectionButton")
            .accessibilityLabel(String(
                localized: "terminal.selection.cancel",
                defaultValue: "Cancel terminal selection"
            ))
        }
        .padding(8)
        .background(CmuxTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        }
        .shadow(color: CmuxTheme.hardShadow, radius: 12, x: 0, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("TerminalSelectionActionControls")
    }

    static func boundedSymbolSize(_ proposedSize: CGFloat) -> CGFloat {
        min(max(proposedSize, symbolSizeRange.lowerBound), symbolSizeRange.upperBound)
    }

    private var boundedSymbolSize: CGFloat {
        Self.boundedSymbolSize(scaledSymbolSize)
    }
}
