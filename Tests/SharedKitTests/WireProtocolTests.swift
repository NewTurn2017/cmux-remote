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
}
