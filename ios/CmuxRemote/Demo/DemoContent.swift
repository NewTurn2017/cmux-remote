import Foundation
import SharedKit

/// Static fixtures backing Demo Mode (the App Review reachable path —
/// reviewers can't bring their own Tailscale-connected Mac, so this gives
/// them a populated, navigable surface to evaluate the app against).
enum DemoContent {
    static let workspaces: [DemoWorkspace] = [
        DemoWorkspace(
            id: "WS-DEMO-SELECTION",
            title: String(
                localized: "demo.selection.workspace.title",
                defaultValue: "Selection Lab"
            ),
            surfaces: [
                DemoSurface(
                    id: "SF-DEMO-SELECTION",
                    title: String(
                        localized: "demo.selection.surface.title",
                        defaultValue: "Truecolor Copy"
                    ),
                    screen: terminalSelectionFixture
                ),
            ]
        ),
        DemoWorkspace(
            id: "WS-DEMO-1",
            title: "agent-lab",
            surfaces: [
                DemoSurface(id: "SF-DEMO-1A", title: "claude-code", screen: claudeCodeAgentLab),
                DemoSurface(id: "SF-DEMO-1B", title: "codex", screen: codexAgentLab),
                DemoSurface(id: "SF-DEMO-1C", title: "omx", screen: omxAgentLab),
            ]
        ),
        DemoWorkspace(
            id: "WS-DEMO-2",
            title: "study-bot",
            surfaces: [
                DemoSurface(id: "SF-DEMO-2A", title: "claude-code", screen: claudeCodeStudyBot),
                DemoSurface(id: "SF-DEMO-2B", title: "shell", screen: shellStudyBot),
                DemoSurface(id: "SF-DEMO-2C", title: "lazygit", screen: lazygitStudyBot),
            ]
        ),
        DemoWorkspace(
            id: "WS-DEMO-3",
            title: "cmux-remote",
            surfaces: [
                DemoSurface(id: "SF-DEMO-3A", title: "swift test", screen: swiftTestSession),
                DemoSurface(id: "SF-DEMO-3B", title: "relay log", screen: relayLogSession),
                DemoSurface(id: "SF-DEMO-3C", title: "vim", screen: vimSession),
            ]
        ),
        DemoWorkspace(
            id: "WS-DEMO-4",
            title: "next-app",
            surfaces: [
                DemoSurface(id: "SF-DEMO-4A", title: "codex", screen: codexNextApp),
                DemoSurface(id: "SF-DEMO-4B", title: "shell", screen: pnpmShell),
            ]
        ),
        DemoWorkspace(
            id: "WS-DEMO-5",
            title: "infra-ops",
            surfaces: [
                DemoSurface(id: "SF-DEMO-5A", title: "claude-code", screen: claudeCodeIncident),
                DemoSurface(id: "SF-DEMO-5B", title: "k9s", screen: k9sScreen),
            ]
        ),
        DemoWorkspace(
            id: "WS-DEMO-6",
            title: "inbox-zero",
            surfaces: [
                DemoSurface(id: "SF-DEMO-6A", title: "omx", screen: omxInbox),
                DemoSurface(id: "SF-DEMO-6B", title: "tmux", screen: tmuxSession),
            ]
        ),
    ]

    static func surface(for id: String) -> DemoSurface? {
        for ws in workspaces {
            if let match = ws.surfaces.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    static func screenFull(for surfaceId: String) -> ScreenFull? {
        guard let surface = surface(for: surfaceId) else { return nil }
        let rows = surface.screen
        let cols = rows.map(terminalColumns(in:)).max() ?? 80
        return ScreenFull(
            surfaceId: surfaceId,
            rev: 1,
            rows: rows,
            cols: cols,
            rowsCount: rows.count,
            cursor: CursorPos(x: 0, y: rows.count - 1)
        )
    }

    static func notifications() -> [NotificationRecord] {
        let now = Int64(Date().timeIntervalSince1970)
        return [
            NotificationRecord(
                id: "demo-notif-1",
                workspaceId: "WS-DEMO-3",
                surfaceId: "SF-DEMO-3A",
                title: "swift test passed",
                subtitle: "cmux-remote",
                body: "142 tests, 0 failures (0.481s)",
                ts: now - 30,
                threadId: "workspace-WS-DEMO-3"
            ),
            NotificationRecord(
                id: "demo-notif-2",
                workspaceId: "WS-DEMO-1",
                surfaceId: "SF-DEMO-1A",
                title: "Claude needs your decision",
                subtitle: "agent-lab · claude-code",
                body: "Apply RPCEnvelope refactor? (y/n)",
                ts: now - 12,
                threadId: "workspace-WS-DEMO-1"
            ),
            NotificationRecord(
                id: "demo-notif-3",
                workspaceId: "WS-DEMO-5",
                surfaceId: "SF-DEMO-5A",
                title: "P1 incident: api latency",
                subtitle: "infra-ops · claude-code",
                body: "Root cause found: gateway OOM, PR #2341",
                ts: now - 4,
                threadId: "workspace-WS-DEMO-5"
            ),
        ]
    }

    // MARK: - Screen content

    /// Stable ANSI surface used by Demo Mode and end-to-end interaction checks.
    /// The exact three-line copy target is initially visible; lower rows exist
    /// only to exercise terminal-owned vertical and horizontal scrolling.
    private static let terminalSelectionFixture: [String] = {
        let reset = "\u{1B}[0m"
        let greenBackground = "48;2;40;50;40"
        let scrollRow = String(
            localized: "demo.selection.terminal.scrollRow",
            defaultValue: "render pass %02d · scroll lane"
        )
        var rows = (0..<72).map { index in
            String(format: scrollRow, index)
        }

        rows[0] = String(
            localized: "demo.selection.terminal.command",
            defaultValue: "$ cmux palette --selection"
        )
        rows[1] = String(
            localized: "demo.selection.terminal.subtitle",
            defaultValue: "Truecolor, Unicode, and copy"
        )
        rows[2] = ""
        rows[3] = "\u{1B}[1;38;2;241;242;248;\(greenBackground)mBOLD TRUECOLOR\(reset)"
        rows[4] = "\u{1B}[4;38;2;158;206;106;48;2;53;47;68mUNDERLINE OLIVE\(reset)"
        rows[5] = "\u{1B}[48;2;40;50;40m                \(reset)"
        rows[6] = "e\u{301} · 한글界"
        rows[7] = "left  middle  right   "
        rows[8] = ""
        rows[9] = String(
            localized: "demo.selection.terminal.scrollHint",
            defaultValue: "Scroll lanes continue below"
        )
        rows[10] = ""
        rows[11] = ""

        let wideRule = String(repeating: "0123456789", count: 15)
        let wideRow = String(
            localized: "demo.selection.terminal.wideRow",
            defaultValue: "wide canvas %02d · %@"
        )
        for index in 36...56 {
            rows[index] = String(format: wideRow, index, wideRule)
        }

        rows[57] = String(
            localized: "demo.selection.terminal.complete",
            defaultValue: "Palette inspection complete"
        )
        rows[60] = "e\u{301} · 한글界"
        rows[61] = "\u{1B}[48;2;40;50;40m                \(reset)"
        rows[62] = "left  middle  right   "
        rows[63] = ""
        rows[64] = "e\u{301} · 한글界"
        rows[65] = "\u{1B}[48;2;40;50;40m                \(reset)"
        rows[66] = "left  middle  right   "
        rows[67] = ""
        rows[68] = "\u{1B}[1;38;2;125;207;255;\(greenBackground)m ┌ TRUECOLOR COPY FIXTURE ┐ \(reset)"
        rows[69] = "\u{1B}[38;2;125;207;255;\(greenBackground)mCOPY A  \(reset)"
        rows[70] = "\u{1B}[38;2;255;158;100;\(greenBackground)m한글界\(reset)"
        rows[71] = "\u{1B}[38;2;26;188;156;\(greenBackground)mCOPY B  \(reset)"
        return rows
    }()

    private static func terminalColumns(in row: String) -> Int {
        ANSIParser.parse(row, base: .default).reduce(into: 0) { columns, cell in
            columns += TerminalCellWidth.columns(for: cell.character)
        }
    }

    private static let claudeCodeAgentLab: [String] = [
        "$ claude code",
        "",
        "╭─ Project: agent-lab ─────────────────╮",
        "│ Model:  claude-opus-4-7              │",
        "│ Branch: feat/dispatcher-v2           │",
        "╰──────────────────────────────────────╯",
        "",
        "› Refactor the dispatcher to use the new",
        "  RPCEnvelope shape from shared/wire.ts",
        "",
        "I'll update the dispatcher. Let me first",
        "read the current implementation.",
        "",
        "● Read(src/dispatcher.ts)",
        "  ⎿  Read 218 lines",
        "",
        "● Read(shared/wire.ts)",
        "  ⎿  Read 91 lines",
        "",
        "● The dispatcher currently uses an inline",
        "  envelope. I'll extract RPCEnvelope as a",
        "  discriminated union with three cases:",
        "  request, response, error.",
        "",
        "● Edit(src/dispatcher.ts)",
        "  ⎿  Replaced 47 lines",
        "",
        "● Bash(npm run typecheck)",
        "  ⎿  ✓ tsc: no errors",
        "",
        "Tests pass locally. Want me to also add",
        "unit coverage for the new error branch?",
        "",
        "[1] Yes, add tests",
        "[2] Show me the diff first",
        "[3] Skip tests",
        "",
        "› ",
    ]

    private static let codexAgentLab: [String] = [
        "$ codex",
        "",
        "[Codex 2.4.1] connected → openai/codex",
        "Working dir: ~/dev/agent-lab",
        "",
        "▸ implement retry logic for the openai",
        "  rate-limit (429) responses",
        "",
        "Reading: src/client.ts",
        "Reading: src/retry.ts",
        "",
        "I'll add exponential backoff with jitter,",
        "capped at 30s, using AbortSignal-aware",
        "sleep. Let me apply the change.",
        "",
        "  src/retry.ts  | 38 ++++++++++++++++++--",
        "  src/client.ts |  6 ++--",
        "  tests/retry.spec.ts | 21 +++++++++",
        "  3 files changed, 57 insertions(+)",
        "",
        "Apply? [y/n] _",
    ]

    private static let omxAgentLab: [String] = [
        "$ omx run --plan plans/refactor-auth.md",
        "",
        "⠋ orchestrating 3 agents",
        "",
        "[1] explorer  · scanning auth/* (8 files)",
        "[2] critic    · waiting on explorer",
        "[3] writer    · waiting on critic",
        "",
        "▸ explorer reported: 4 auth strategies",
        "  identified. token-based looks viable.",
        "▸ critic dispatching: review token spec",
        "▸ writer queued: draft migration plan",
        "",
        "elapsed: 00:01:42",
        "tasks: 12 done, 3 active, 4 pending",
        "",
        "─ live trace ──────────────────────────",
        "16:42:08  explorer → critic: spec.md",
        "16:42:11  critic    summarized 4 risks",
        "16:42:16  writer    drafted §1 of 5",
        "",
    ]

    private static let claudeCodeStudyBot: [String] = [
        "$ claude code",
        "",
        "╭─ Project: study-bot ─────────────────╮",
        "│ Model:  claude-opus-4-7              │",
        "│ Branch: feat/quiz-engine             │",
        "╰──────────────────────────────────────╯",
        "",
        "› the ELO scoring is wrong for users",
        "  with <5 quizzes. fix it",
        "",
        "Let me reproduce. I'll write a quick",
        "test against the current implementation.",
        "",
        "● Write(tests/elo-cold-start.spec.ts)",
        "  ⎿  Wrote 32 lines",
        "",
        "● Bash(npm test elo-cold-start)",
        "  ⎿  FAIL: expected 1100, got 1500",
        "  ⎿  Confirms cold-start floor not capped",
        "",
        "Root cause: K-factor stays at 40 even for",
        "new users. Standard fix is to boost K for",
        "first 10 matches (provisional rating)",
        "then settle at 20.",
        "",
        "Apply this patch? [y/n] _",
    ]

    private static let shellStudyBot: [String] = [
        "genie@mac:~/dev/study-bot$ git status",
        "On branch feat/quiz-engine",
        "Your branch is up to date with origin.",
        "",
        "Changes not staged for commit:",
        "  modified: src/engine/scorer.ts",
        "  modified: tests/scorer.spec.ts",
        "",
        "genie@mac:~/dev/study-bot$ git diff --stat",
        " src/engine/scorer.ts | 23 +++++++++--",
        " tests/scorer.spec.ts | 12 ++++++",
        " 2 files changed, 31 insertions(+)",
        "",
        "genie@mac:~/dev/study-bot$ git log --oneline -5",
        "019e220 (HEAD) quiz scoring rubric v2",
        "8ba057a add daily-streak metric",
        "b9b8eda fix token refresh race",
        "9a45e7a chore: bump deps",
        "7c12048 wire up new ELO engine",
        "",
        "genie@mac:~/dev/study-bot$ ",
    ]

    private static let lazygitStudyBot: [String] = [
        "─ Files ───────────────────────────────",
        "   M  src/engine/scorer.ts",
        "   M  tests/scorer.spec.ts",
        "   ?  .codex/notes.md",
        "   ?  plans/quiz-v3.md",
        "",
        "─ Commits ─────────────────────────────",
        " ● 019e220 quiz scoring rubric v2",
        " ● 8ba057a add daily-streak metric",
        " ● b9b8eda fix token refresh race",
        " ● 9a45e7a chore: bump deps",
        " ● 7c12048 wire up new ELO engine",
        " ● 5e98a01 add quiz import endpoint",
        "",
        "─ Branches ────────────────────────────",
        " * feat/quiz-engine",
        "   main",
        "   feat/super-manage",
        "   chore/deps-update",
        "",
        "[?] menu  [c] commit  [P] push  [b] branch",
    ]

    private static let swiftTestSession: [String] = [
        "$ swift test",
        "Building for debugging...",
        "Build complete!",
        "",
        "Test Suite 'All tests' started",
        "",
        "Test Suite 'NotificationStoreTests'",
        "  testIngestNotificationEvent      passed",
        "  testFiresOnNewOnceForRepeatedId  passed",
        "  testCapsNewestFirst              passed",
        "  testWipesOnDemoModeToggle        passed",
        "",
        "Test Suite 'WireProtocolTests'",
        "  testEncodeFrameRoundTrip         passed",
        "  testEventCategorySerialization   passed",
        "  testEnvelopeCBOR                 passed",
        "",
        "Test Suite 'DemoDispatchTests'",
        "  testWorkspaceListShape           passed",
        "  testSurfaceListByWorkspace       passed",
        "  testSubscribeFiresOnSurface      passed",
        "",
        "Test Suite 'KeychainStoreTests'",
        "  testRoundTripBearerToken         passed",
        "  testWipeOnReset                  passed",
        "",
        "Executed 142 tests, with 0 failures (0.481s)",
        "$ ",
    ]

    private static let relayLogSession: [String] = [
        "[18:30:01] starting cmux-relay on :4399",
        "[18:30:01] HTTPServer listening :4399",
        "[18:30:06] cmux event stream attached",
        "[18:30:14] req GET /v1/ws 100.115.102.6",
        "[18:30:14] device registered: iphone",
        "[18:31:02] subscribe surface:5 fps=15",
        "[18:31:18] notification.create id=n-002",
        "[18:33:45] req POST /v1/register",
        "[18:33:45] device updated: ipad",
        "[18:34:11] subscribe surface:7 fps=15",
        "[18:35:20] surface.send_text s=5 b=12",
        "[18:35:20] surface.send_key s=5 k=enter",
        "[18:36:02] screen.diff s=5 rev=42",
        "[18:36:18] notification.create id=n-003",
        "[18:36:18] threadId=ws-2 silent=false",
        "[18:36:42] surface.send_key s=7 k=ctrl-c",
        "[18:37:01] subscribe surface:2 fps=15",
        "[18:37:18] screen.full s=2 rev=1",
        "[18:38:04] notification.create id=n-004",
        "",
    ]

    private static let vimSession: [String] = [
        "  1   import SwiftUI",
        "  2   import SharedKit",
        "  3   ",
        "  4   /// Workspace switcher chip bar",
        "  5   /// shown at the top of the home tab.",
        "  6   struct WorkspaceChipBar: View {",
        "  7     let workspaces: [Workspace]",
        "  8     @Binding var selectedId: String?",
        "  9   ",
        " 10     var body: some View {",
        " 11       ScrollView(.horizontal) {",
        " 12         HStack(spacing: 6) {",
        " 13           ForEach(workspaces) { ws in",
        " 14             chip(for: ws)",
        " 15           }",
        " 16         }",
        " 17         .padding(.horizontal, 12)",
        " 18       }",
        " 19     }",
        " 20   ",
        " 21     private func chip(for ws: Workspace)",
        " 22       -> some View {",
        " 23       Button { selectedId = ws.id } label:",
        " 24",
        "\"WorkspaceChipBar.swift\" 124L, 3.2K",
    ]

    private static let codexNextApp: [String] = [
        "$ codex",
        "",
        "[Codex 2.4.1] connected → openai/codex",
        "Working dir: ~/dev/next-app",
        "",
        "▸ migrate /api routes from pages router",
        "  to the app router (route handlers)",
        "",
        "Found 14 files to migrate. I'll do them",
        "in dependency order:",
        "",
        "  api/auth/*    (3 files)",
        "  api/users/*   (5 files)",
        "  api/billing/* (4 files)",
        "  api/admin/*   (2 files)",
        "",
        "Migrating api/auth/[...nextauth].ts...",
        "  ✓ moved to app/api/auth/route.ts",
        "  ✓ converted to Route Handler signature",
        "  ✓ updated 7 import sites",
        "",
        "3 of 14 done. Continue with users/*? [y/n] _",
    ]

    private static let pnpmShell: [String] = [
        "genie@mac:~/dev/next-app$ pnpm install",
        "",
        " WARN  17 deprecated subdependencies",
        "Packages: +247",
        "+++++++++++++++++++++++++++++++++++++++",
        "",
        "Progress: resolved 1247, reused 1108,",
        "downloaded 139, added 247, done",
        "",
        "genie@mac:~/dev/next-app$ pnpm dev",
        "",
        "> next-app@0.4.0 dev",
        "> next dev --turbo",
        "",
        "   ▲ Next.js 15.1.3 (Turbopack)",
        "   - Local:   http://localhost:3000",
        "",
        " ✓ Ready in 1.8s",
        " ✓ Compiled /page in 412ms",
        " ✓ Compiled /api/auth/[...] in 187ms",
        " ○ Compiling /dashboard ...",
        "",
    ]

    private static let claudeCodeIncident: [String] = [
        "$ claude code",
        "",
        "╭─ Project: infra-ops ─────────────────╮",
        "│ Model: claude-opus-4-7               │",
        "│ Mode:  incident-response             │",
        "╰──────────────────────────────────────╯",
        "",
        "› p1: api latency spiked to 4.2s p99,",
        "  alerts firing since 11:42. find why",
        "",
        "I'll start with the latency dashboard",
        "and the most recent deploys.",
        "",
        "● Bash(kubectl get pods -n api)",
        "  ⎿  gateway-77f6b9c-xz4k2  Running",
        "  ⎿  gateway-77f6b9c-pl8mn  CrashLoop",
        "",
        "● Read(prometheus/api-latency.yml)",
        "  ⎿  Read 64 lines",
        "",
        "Root cause: CrashLoop on api-gateway,",
        "restarting every 38s. Logs show OOM at",
        "2.1GB. Recent change: GraphQL persisted",
        "query cache uncapped (PR #2341).",
        "",
        "Suggested mitigation:",
        "  1. Roll back PR #2341 (90s rollback)",
        "  2. Cap cache at 500MB temporarily",
        "",
        "[1] Roll back  [2] Cap cache  [3] Both",
        "› ",
    ]

    private static let k9sScreen: [String] = [
        "─ Pods(api/all)[8] ────────────────────",
        "NAMESPACE  NAME            READY  RST",
        "api        gateway-xz4k2    1/1    0",
        "api        gateway-pl8mn    0/1    4",
        "api        users-svc-a      2/2    0",
        "api        users-svc-b      2/2    0",
        "api        billing-7c8      1/1    0",
        "api        billing-9f1      1/1    0",
        "api        admin-ui-x12     1/1    0",
        "api        graphql-mesh-77  1/1    0",
        "",
        "─ Events ──────────────────────────────",
        " ⨯ gateway-pl8mn  OOMKilled",
        " ⨯ gateway-pl8mn  BackOff",
        " ✓ users-svc-a    Started",
        " ✓ billing-7c8    Probe ok",
        " ⨯ gateway-pl8mn  OOMKilled",
        "",
        "<l>ogs <d>elete <r>estart <q>uit",
    ]

    private static let omxInbox: [String] = [
        "$ omx daemon status",
        "",
        "[OMX 1.2.0] running, pid=4892",
        "listening: /tmp/omx.sock",
        "",
        "agents:",
        "  inbox-curator    idle   (last: 03m)",
        "  thread-replier   active (3 drafts)",
        "  summary-writer   idle   (last: 11m)",
        "",
        "queue:",
        "  inbox/genie@*  → 47 unread → 6 hot",
        "  inbox/work     → 12 unread → 2 hot",
        "",
        "recent activity:",
        "  [16:42] curator: tagged 8 as marketing",
        "  [16:38] replier: drafted reply to #2241",
        "  [16:35] summary: posted weekly digest",
        "  [16:30] curator: archived 19 newsletters",
        "",
        "press q to quit, [a] approve drafts",
    ]

    private static let tmuxSession: [String] = [
        "─ tmux ─ session: inbox-zero ─ 1/3",
        " [0] reader   [1]* writer   [2] queue",
        "",
        "┌────────────────────────────────────┐",
        "│ Inbox · 47 unread                  │",
        "│                                    │",
        "│ ▸ Slack: design crit ready         │",
        "│   GitHub: 3 PRs need review        │",
        "│   Linear: INC-822 assigned         │",
        "│   Notion: weekly digest available  │",
        "│   Vercel: build succeeded          │",
        "│   Sentry: 2 new errors             │",
        "│   ...                              │",
        "│                                    │",
        "└────────────────────────────────────┘",
        "",
        "Press [enter] to open, [a] archive,",
        "[r] reply via omx, [g] go to GitHub",
    ]
}

struct DemoWorkspace {
    let id: String
    let title: String
    let surfaces: [DemoSurface]
}

struct DemoSurface {
    let id: String
    let title: String
    let screen: [String]
}
