import Testing
import Foundation
@testable import SharedKit

@Suite("Models")
struct ModelsTests {
    @Test func workspaceRoundTrip() throws {
        let ws = Workspace(id: "ws-1", name: "frontend", surfaces: [
            Surface(id: "sf-1", title: "shell", cols: 120, rows: 30, lastActivity: 1000),
        ], lastActivity: 2000)
        let data = try JSONEncoder().encode(ws)
        let back = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(back == ws)
    }

    @Test func notificationRoundTrip() throws {
        let n = NotificationRecord(
            id: "n-1", workspaceId: "ws-1", surfaceId: "sf-1",
            title: "Build done", subtitle: "ws/frontend", body: "✅ tests green",
            ts: 1714000000, threadId: "ws-ws-1"
        )
        let data = try JSONEncoder().encode(n)
        let back = try JSONDecoder().decode(NotificationRecord.self, from: data)
        #expect(back == n)
    }

    @Test func bootInfoRoundTrip() throws {
        let b = BootInfo(bootId: "b-7", startedAt: 1714000000)
        let data = try JSONEncoder().encode(b)
        let back = try JSONDecoder().decode(BootInfo.self, from: data)
        #expect(back == b)
    }
}
