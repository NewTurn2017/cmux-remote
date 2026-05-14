import Foundation
import SharedKit

/// Static fixtures backing Demo Mode (the App Review reachable path —
/// reviewers can't bring their own Tailscale-connected Mac, so this gives
/// them a populated, navigable surface to evaluate the app against).
///
/// Kept intentionally small: 2 workspaces × 2 surfaces is enough to show
/// the chip bar, terminal mirror, notifications, and Settings without
/// faking arbitrary RPC depth.
enum DemoContent {
    static let workspaces: [DemoWorkspace] = [
        DemoWorkspace(
            id: "WS-DEMO-1",
            title: "mybest-edu-ai",
            surfaces: [
                DemoSurface(id: "SF-DEMO-1A", title: "claude", screen: claudeSession),
                DemoSurface(id: "SF-DEMO-1B", title: "shell", screen: shellSession),
            ]
        ),
        DemoWorkspace(
            id: "WS-DEMO-2",
            title: "cmux-remote",
            surfaces: [
                DemoSurface(id: "SF-DEMO-2A", title: "swift test", screen: swiftTestSession),
                DemoSurface(id: "SF-DEMO-2B", title: "relay log", screen: relayLogSession),
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
        let cols = rows.map(\.count).max() ?? 80
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
                workspaceId: "WS-DEMO-2",
                surfaceId: "SF-DEMO-2A",
                title: "swift test passed",
                subtitle: "cmux-remote",
                body: "87 tests, 0 failures (0.342s)",
                ts: now - 30,
                threadId: "workspace-WS-DEMO-2"
            ),
            NotificationRecord(
                id: "demo-notif-2",
                workspaceId: "WS-DEMO-1",
                surfaceId: "SF-DEMO-1A",
                title: "Claude needs your decision",
                subtitle: "mybest-edu-ai · claude",
                body: "Apply audit_log schema changes? (y/n)",
                ts: now - 10,
                threadId: "workspace-WS-DEMO-1"
            ),
        ]
    }

    // MARK: - Screen content

    private static let claudeSession: [String] = [
        "$ claude code",
        "Welcome to Claude Code v0.7.21",
        "Project: mybest-edu-ai",
        "",
        "› Help me add audit log for super-manage role",
        "",
        "I'll add an audit log. Let me first check the schema.",
        "",
        "● Read(schema/audit.ts)",
        "  ⎿  Read 142 lines",
        "",
        "● I'll add the audit_log table with these columns:",
        "    id, actor_id, action, target_id, timestamp",
        "",
        "[1] Apply changes  [2] Skip  [3] Modify",
        "› ",
    ]

    private static let shellSession: [String] = [
        "genie@mac:~/dev/active/mybest-edu-ai$ git status",
        "On branch feat/operating-account-roles",
        "Your branch is up to date with 'origin/feat/operating-account-roles'.",
        "",
        "Changes not staged for commit:",
        "  modified:   src/server/auth/roles.ts",
        "  modified:   src/client/components/RoleSelector.tsx",
        "",
        "genie@mac:~/dev/active/mybest-edu-ai$ git log --oneline -5",
        "019e220 (HEAD) Add audit_log table for super-manage actions",
        "8ba057a feat: scope-aware role hierarchy",
        "b9b8eda fix: token refresh race condition",
        "9a45e7a chore: bump deps",
        "",
        "genie@mac:~/dev/active/mybest-edu-ai$ ",
    ]

    private static let swiftTestSession: [String] = [
        "$ swift test",
        "Building for debugging...",
        "Build complete!",
        "",
        "Test Suite 'All tests' started",
        "",
        "Test Suite 'NotificationStoreTests' started",
        "  testIngestNotificationEvent           passed (0.001s)",
        "  testFiresOnNewOnceForRepeatedId       passed (0.001s)",
        "  testCapsNewestFirst                   passed (0.012s)",
        "",
        "Test Suite 'WireProtocolTests' started",
        "  testEncodeFrameRoundTrip              passed (0.000s)",
        "  testEventCategorySerialization        passed (0.000s)",
        "",
        "Executed 87 tests, with 0 failures (0.342s)",
        "$ ",
    ]

    private static let relayLogSession: [String] = [
        "[18:30:01] starting cmux-relay on 0.0.0.0:4399",
        "[18:30:01] HTTPServer listening on 0.0.0.0:4399",
        "[18:30:06] cmux event stream attached",
        "[18:30:14] req GET /v1/ws from 100.115.102.6",
        "[18:30:14] device registered: jaehyun-iphone",
        "[18:31:02] subscribe surface:5 fps=15",
        "[18:31:18] notification.create id=n-002",
        "[18:33:45] req POST /v1/register from 100.115.102.6",
        "[18:33:45] device updated: jaehyun-ipad",
        "[18:34:11] subscribe surface:7 fps=15",
        "[18:35:20] surface.send_text surface=5 bytes=12",
        "[18:35:20] surface.send_key surface=5 key=enter",
        "",
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
