import Testing
import Foundation
@testable import SharedKit

@Suite("WireProtocol")
struct WireProtocolTests {
    @Test func screenFullDecodes() throws {
        let raw = """
        {"type":"screen.full","surface_id":"sf","rev":0,"rows":["a","b"],"cols":2,"rowsCount":2,"cursor":{"x":0,"y":0}}
        """
        let frame = try JSONDecoder().decode(PushFrame.self, from: Data(raw.utf8))
        guard case .screenFull(let f) = frame else { Issue.record("not screen.full"); return }
        #expect(f.surfaceId == "sf")
        #expect(f.rev == 0)
        #expect(f.rows == ["a","b"])
        #expect(f.cursor.x == 0)
    }

    @Test func screenDiffDecodes() throws {
        let raw = """
        {"type":"screen.diff","surface_id":"sf","rev":42,
         "ops":[{"op":"row","y":7,"text":"$ ls"},{"op":"cursor","x":0,"y":9}]}
        """
        let frame = try JSONDecoder().decode(PushFrame.self, from: Data(raw.utf8))
        guard case .screenDiff(let f) = frame else { Issue.record("not screen.diff"); return }
        #expect(f.surfaceId == "sf")
        #expect(f.rev == 42)
        #expect(f.ops.count == 2)
    }

    @Test func screenChecksumDecodes() throws {
        let raw = #"{"type":"screen.checksum","surface_id":"sf","rev":42,"hash":"abc"}"#
        let frame = try JSONDecoder().decode(PushFrame.self, from: Data(raw.utf8))
        guard case .screenChecksum(let f) = frame else { Issue.record("wrong"); return }
        #expect(f.hash == "abc")
    }

    @Test func eventFrameDecodes() throws {
        let raw = """
        {"type":"event","category":"notification","name":"notification.created","payload":{"foo":"bar"}}
        """
        let frame = try JSONDecoder().decode(PushFrame.self, from: Data(raw.utf8))
        guard case .event(let f) = frame else { Issue.record("wrong"); return }
        #expect(f.category == .notification)
        #expect(f.name == "notification.created")
    }

    @Test func eventFrameDecodesAgentCategoryForNeedsInputEvents() throws {
        let raw = """
        {"type":"event","category":"agent","name":"claude.needs_input","payload":{"status":"needs input"}}
        """
        let frame = try JSONDecoder().decode(PushFrame.self, from: Data(raw.utf8))
        guard case .event(let f) = frame else { Issue.record("wrong"); return }
        #expect(f.category == .agent)
        #expect(f.name == "claude.needs_input")
        #expect(EventCategory.allCases.contains(.agent))
    }

    @Test func eventFrameDecodesHookCategoryForNeedsInputEvents() throws {
        let raw = """
        {"type":"event","category":"hook","name":"claude.hook.needs_input","payload":{"status":"needs input"}}
        """
        let frame = try JSONDecoder().decode(PushFrame.self, from: Data(raw.utf8))
        guard case .event(let f) = frame else { Issue.record("wrong"); return }
        #expect(f.category == .hook)
        #expect(f.name == "claude.hook.needs_input")
        #expect(EventCategory.allCases.contains(.hook))
    }

    @Test func eventFrameDecodesUnknownCategoryAsUnknown() throws {
        let raw = """
        {"type":"event","category":"mystery","name":"claude.needs_input","payload":{"status":"needs input"}}
        """
        let frame = try JSONDecoder().decode(PushFrame.self, from: Data(raw.utf8))
        guard case .event(let f) = frame else { Issue.record("wrong"); return }
        #expect(f.category == .unknown)
        #expect(f.name == "claude.needs_input")
        #expect(!EventCategory.allCases.contains(.unknown))
    }

    @Test func pingPongDecodes() throws {
        let ping = try JSONDecoder().decode(PushFrame.self, from: Data(#"{"type":"ping","ts":42}"#.utf8))
        guard case .ping(let p) = ping else { Issue.record("wrong"); return }
        #expect(p.ts == 42)
    }

    @Test func helloFrameRoundTrip() throws {
        let h = HelloFrame(deviceId: "dev-1", appVersion: "1.0.0", protocolVersion: 1)
        let data = try JSONEncoder().encode(h)
        let back = try JSONDecoder().decode(HelloFrame.self, from: data)
        #expect(back == h)
    }

    @Test func screenFullFromSnapshotCarriesGeometryAndStyledRows() throws {
        let styled = "\u{1B}[38;2;234;234;234;48;2;40;50;40mgreen\u{1B}[0m"
        let screen = Screen(
            rev: 9,
            rows: [styled, ""],
            cols: 12,
            cursor: CursorPos(x: 5, y: 0)
        )

        let full = ScreenFull(surfaceId: "surface", screen: screen)

        #expect(full.rev == 9)
        #expect(full.rows == [styled, ""])
        #expect(full.cols == 12)
        #expect(full.rowsCount == 2)
        #expect(full.cursor == CursorPos(x: 5, y: 0))
    }

    @Test func screenDiffEncodingNeverCarriesResizeGeometry() throws {
        let frame = PushFrame.screenDiff(ScreenDiff(
            surfaceId: "surface",
            rev: 10,
            ops: [.row(y: 0, text: "changed")]
        ))

        let data = try SharedKitJSON.deterministicEncoder.encode(frame)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["type"] as? String == "screen.diff")
        #expect(object["cols"] == nil)
        #expect(object["rowsCount"] == nil)
    }

    @Test func pushFrameEncodeRoundTrip() throws {
        let original = PushFrame.screenDiff(ScreenDiff(
            surfaceId: "s1",
            rev: 7,
            ops: [.row(y: 1, text: "hello"), .cursor(x: 0, y: 1)]
        ))
        let data = try JSONEncoder().encode(original)
        let json = try #require(String(data: data, encoding: .utf8))
        // Verify the discriminator and snake-cased key both made it onto the wire.
        #expect(json.contains("\"type\":\"screen.diff\""))
        #expect(json.contains("\"surface_id\":\"s1\""))
        // True round-trip: decode back and compare.
        let back = try JSONDecoder().decode(PushFrame.self, from: data)
        #expect(back == original)
    }
}
