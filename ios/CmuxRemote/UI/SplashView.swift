import SwiftUI

/// Boot-sequence splash. Renders a fake terminal boot log in monospace,
/// then signals completion via `onFinish`. The host (`CmuxRemoteApp`) is
/// responsible for crossfading to the live UI.
struct SplashView: View {
    var onFinish: () -> Void

    @State private var revealedLineCount = 0
    @State private var caretOn = true
    @State private var prepareDissolve = false

    private static let lines: [SplashLine] = [
        .init(prefix: "▓▓▓▓▓▓", body: " CMUX REMOTE ", suffix: "▓▓▓▓▓▓", style: .banner),
        .init(prefix: "",  body: "v1.0.0  build 1",            suffix: "", style: .meta),
        .init(prefix: "",  body: "─────────────────────────",  suffix: "", style: .divider),
        .init(prefix: "[",  body: " ok ", suffix: "] swift runtime",        style: .stepOk),
        .init(prefix: "[",  body: " ok ", suffix: "] keychain",             style: .stepOk),
        .init(prefix: "[",  body: " ok ", suffix: "] tailscale resolver",   style: .stepOk),
        .init(prefix: "[",  body: " ok ", suffix: "] websocket",            style: .stepOk),
        .init(prefix: "[", body: " READY ", suffix: "]",                    style: .ready),
    ]

    private static let perLineDelay: Duration = .milliseconds(110)
    private static let postReadyDelay: Duration = .milliseconds(420)
    private static let crossfadeDelay: Duration = .milliseconds(180)

    var body: some View {
        ZStack(alignment: .topLeading) {
            CmuxTheme.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(Self.lines.prefix(revealedLineCount).enumerated()), id: \.offset) { _, line in
                    line.view(caretOn: caretOn && line.style == .ready)
                }
                if revealedLineCount < Self.lines.count {
                    Text(caretOn ? "█" : " ")
                        .cmuxDisplay(13)
                        .foregroundStyle(CmuxTheme.accentGreen)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 80)
            .opacity(prepareDissolve ? 0 : 1)
            .animation(.easeOut(duration: 0.18), value: prepareDissolve)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("CmuxBootSplash")
        .task { await runBootSequence() }
        .onAppear { startCaret() }
    }

    @MainActor
    private func runBootSequence() async {
        for index in Self.lines.indices {
            revealedLineCount = index + 1
            try? await Task.sleep(for: Self.perLineDelay)
        }
        try? await Task.sleep(for: Self.postReadyDelay)
        prepareDissolve = true
        try? await Task.sleep(for: Self.crossfadeDelay)
        onFinish()
    }

    private func startCaret() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(380))
                caretOn.toggle()
            }
        }
    }
}

private struct SplashLine {
    enum Style { case banner, meta, divider, stepOk, ready }
    let prefix: String
    let body: String
    let suffix: String
    let style: Style

    @ViewBuilder
    func view(caretOn: Bool) -> some View {
        switch style {
        case .banner:
            HStack(spacing: 0) {
                Text(prefix).foregroundStyle(CmuxTheme.muted)
                Text(body).foregroundStyle(CmuxTheme.accentGreen)
                Text(suffix).foregroundStyle(CmuxTheme.muted)
            }
            .cmuxDisplay(14)
        case .meta:
            Text(body)
                .cmuxMono(11)
                .foregroundStyle(CmuxTheme.muted)
        case .divider:
            Text(body)
                .cmuxDisplay(12)
                .foregroundStyle(CmuxTheme.divider)
        case .stepOk:
            HStack(spacing: 0) {
                Text(prefix).foregroundStyle(CmuxTheme.muted)
                Text(body.uppercased()).foregroundStyle(CmuxTheme.accentGreen)
                Text(suffix).foregroundStyle(CmuxTheme.ink)
            }
            .cmuxDisplay(12)
        case .ready:
            HStack(spacing: 4) {
                Text(prefix + body + suffix)
                    .foregroundStyle(CmuxTheme.canvas)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(CmuxTheme.accentGreen)
                if caretOn {
                    Text("█")
                        .foregroundStyle(CmuxTheme.accentGreen)
                }
            }
            .cmuxDisplay(13)
        }
    }
}
