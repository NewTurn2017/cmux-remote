import SwiftUI

/// UI tests set `CMUX_UI_TEST_NARROW_WIDTH` to lay the app out at a smaller iPhone width on
/// the one simulator they run on. Release builds ignore it.
struct UITestWidthHarness: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if DEBUG
        if let width = ProcessInfo.processInfo.environment["CMUX_UI_TEST_NARROW_WIDTH"].flatMap(Double.init), width > 0 {
            content
                .frame(width: CGFloat(width))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CmuxTheme.canvas)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
