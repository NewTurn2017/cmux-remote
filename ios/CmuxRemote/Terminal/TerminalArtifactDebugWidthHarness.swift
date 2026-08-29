import SwiftUI

/// DEBUG-only window-width harness for deterministic split-view/Stage Manager UI coverage.
struct TerminalArtifactDebugWidthHarness: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_ARTIFACT_SCENARIO"] == "constrained-width" {
            GeometryReader { proxy in
                let containerWidth = min(CGFloat(640), proxy.size.width)
                ZStack {
                    content
                }
                .frame(width: containerWidth, height: proxy.size.height)
                .clipped()
                .overlay(alignment: .topLeading) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("TerminalArtifactConstrainedWidthHarness")
                        .accessibilityValue(
                            "app=\(Int(proxy.size.width))|container=\(Int(containerWidth))"
                        )
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CmuxTheme.canvas)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
