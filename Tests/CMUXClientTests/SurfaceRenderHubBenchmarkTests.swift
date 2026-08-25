import Foundation
import NIOCore
import SharedKit
import Testing
@testable import CMUXClient

@Suite("SurfaceRenderHubBenchmarkTests", .serialized)
struct SurfaceRenderHubBenchmarkTests {
    @Test func replayDecodeEncodePercentilesAndEffectiveCadence() async throws {
        try await Self.withFixture { fixture in
            async let warmup = fixture.client.terminalRead(
                workspaceId: "benchmark-workspace",
                surfaceId: "benchmark-surface",
                lines: 120
            )
            let capabilitiesRequest = try await Self.nextRequest(fixture)
            #expect(capabilitiesRequest.method == "system.capabilities")
            try await Self.send(
                result: .object([
                    "capabilities": .array([
                        .string("terminal.render_grid.v1"),
                        .string("terminal.render_grid.verified_replay.v1"),
                    ]),
                    "methods": .array([
                        .string("surface.read_text"),
                        .string("terminal.replay"),
                    ]),
                ]),
                request: capabilitiesRequest,
                fixture: fixture
            )
            let warmupRequest = try await Self.nextRequest(fixture)
            try await Self.send(
                result: Self.replayFixture(revision: 1),
                request: warmupRequest,
                fixture: fixture
            )
            _ = try await warmup

            var samples: [Double] = []
            var encodedRows = 0
            for revision in 2...41 {
                let started = ContinuousClock.now
                async let outcome = fixture.client.terminalRead(
                    workspaceId: "benchmark-workspace",
                    surfaceId: "benchmark-surface",
                    lines: 120
                )
                let replayRequest = try await Self.nextRequest(fixture)
                #expect(replayRequest.method == "terminal.replay")
                try await Self.send(
                    result: Self.replayFixture(revision: UInt64(revision)),
                    request: replayRequest,
                    fixture: fixture
                )
                guard case .updated(let update) = try await outcome else {
                    Issue.record("benchmark replay did not produce an updated screen")
                    continue
                }
                encodedRows += update.screen.rows.count
                samples.append(Self.milliseconds(ContinuousClock.now - started))
            }

            let ordered = samples.sorted()
            let p50 = try #require(Self.percentile(ordered, percentile: 0.50))
            let p95 = try #require(Self.percentile(ordered, percentile: 0.95))
            let totalMilliseconds = samples.reduce(0, +)
            let replayThroughputHz = Double(samples.count) / (totalMilliseconds / 1_000)
            let effectiveConfiguredCadenceHz = min(15, 1_000 / p95)

            print("benchmark.workload=loopbackRPC+responseEncode+replayDecode+ANSIEncode")
            print("benchmark.fixtureRowsPerReplay=120")
            print("benchmark.samples=\(samples.count)")
            print(String(format: "benchmark.replayDecodeEncodeP50Ms=%.3f", p50))
            print(String(format: "benchmark.replayDecodeEncodeP95Ms=%.3f", p95))
            print(String(format: "benchmark.sequentialReplayThroughputHz=%.2f", replayThroughputHz))
            print(String(format: "benchmark.effective15HzCadenceFromP95Hz=%.2f", effectiveConfiguredCadenceHz))
            print("benchmark.encodedRows=\(encodedRows)")

            #expect(samples.count == 40)
            #expect(p50 > 0)
            #expect(p95 >= p50)
            #expect(encodedRows == 4_800)
        }
    }

    private static func withFixture<T: Sendable>(
        _ body: @escaping @Sendable (MTELGCmuxFixture) async throws -> T
    ) async throws -> T {
        let fixture = try await MTELGCmuxFixture.make(requestTimeout: .seconds(2))
        do {
            let result = try await body(fixture)
            await fixture.shutdown()
            return result
        } catch {
            await fixture.shutdown()
            throw error
        }
    }

    private static func nextRequest(_ fixture: MTELGCmuxFixture) async throws -> RPCRequest {
        let line = try await fixture.awaitRequestLine()
        return try SharedKitJSON.snakeCaseDecoder.decode(
            RPCRequest.self,
            from: Data(line.utf8)
        )
    }

    private static func send(
        result: JSONValue,
        request: RPCRequest,
        fixture: MTELGCmuxFixture
    ) async throws {
        let response = RPCResponse(id: request.id, result: result)
        let data = try SharedKitJSON.deterministicEncoder.encode(response)
        let line = try #require(String(data: data, encoding: .utf8))
        try await fixture.sendToClient(line: line)
    }

    private static func replayFixture(revision: UInt64) -> JSONValue {
        let styles: [JSONValue] = [
            .object([
                "id": .int(0),
                "foreground": .string("#eaeaea"),
                "background": .string("#101820"),
                "foreground_source": .string("default"),
                "background_source": .string("default"),
            ]),
            .object([
                "id": .int(1),
                "foreground": .string("#7dcfff"),
                "background": .string("#283228"),
                "foreground_source": .string("rgb"),
                "background_source": .string("rgb"),
                "bold": .bool(true),
                "underline": .bool(true),
            ]),
        ]
        let spans: [JSONValue] = (0..<120).map { row in
            .object([
                "row": .int(Int64(row)),
                "column": .int(0),
                "style_id": .int(Int64(row % 2)),
                "text": .string("row \(row) deterministic terminal replay payload"),
            ])
        }
        let epoch = "00000000-0000-4000-8000-0000000000B7"
        return .object([
            "columns": .int(80),
            "rows": .int(120),
            "seq": .int(Int64(revision)),
            "surface_id": .string("benchmark-surface"),
            "workspace_id": .string("benchmark-workspace"),
            "render_grid": .object([
                "format": .string("cmux.render-grid.v1"),
                "surface_id": .string("benchmark-surface"),
                "state_seq": .int(Int64(revision)),
                "render_epoch": .string(epoch),
                "render_revision": .int(Int64(revision)),
                "columns": .int(80),
                "rows": .int(120),
                "cursor": .object([
                    "row": .int(119),
                    "column": .int(4),
                    "visible": .bool(true),
                    "blinking": .bool(false),
                    "style": .int(0),
                ]),
                "full": .bool(true),
                "styles": .array(styles),
                "row_spans": .array(spans),
                "scrollback_rows": .int(0),
                "scrollback_spans": .array([]),
                "terminal_foreground": .string("#eaeaea"),
                "terminal_background": .string("#101820"),
                "anchor": .string("viewport"),
            ]),
        ])
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func percentile(
        _ ordered: [Double],
        percentile: Double
    ) -> Double? {
        guard !ordered.isEmpty else { return nil }
        let rank = Int(ceil(percentile * Double(ordered.count))) - 1
        return ordered[min(max(0, rank), ordered.count - 1)]
    }
}
