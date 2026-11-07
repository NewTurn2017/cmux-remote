import Foundation
import Testing
@testable import RelayServer

@Suite("InboundRPCTraceTests")
struct InboundRPCTraceTests {
    private static let start = ContinuousClock.now

    @Test func readsOnlyTheMethodName() {
        let text = #"{"id":"1","method":"surface.send_text","params":{"text":"secret command"}}"#
        let trace = InboundRPCTrace(text: text, deviceId: "abcdef0123456789", receivedAt: Self.start)

        let line = trace.line(startedAt: Self.start, finishedAt: Self.start, traceAll: true)

        #expect(line == "rpc method=surface.send_text device=abcdef01 queued_ms=0 run_ms=0")
        #expect(line?.contains("secret") == false)
    }

    @Test func labelsHelloAndUnparsedFrames() {
        #expect(InboundRPCTrace.method(of: #"{"deviceId":"d","appVersion":"1.1.4","protocolVersion":1}"#) == "hello")
        #expect(InboundRPCTrace.method(of: "not json") == "<unparsed>")
        #expect(InboundRPCTrace.method(of: #"{"id":"1"}"#) == "<no-method>")
        let large = String(repeating: "a", count: InboundRPCTrace.maximumParsedBytes + 1)
        #expect(InboundRPCTrace.method(of: large) == "<large-frame>")
    }

    @Test func logsFastFramesOnlyWhenTracingEverything() {
        let trace = InboundRPCTrace(text: #"{"id":"1","method":"host.battery"}"#, deviceId: "d", receivedAt: Self.start)
        let finished = Self.start + .milliseconds(30)

        #expect(trace.line(startedAt: Self.start, finishedAt: finished, traceAll: false) == nil)
        #expect(trace.line(startedAt: Self.start, finishedAt: finished, traceAll: true) != nil)
    }

    @Test func alwaysLogsSlowFramesWithQueueAndRunTime() {
        let trace = InboundRPCTrace(text: #"{"id":"1","method":"surface.send_key"}"#, deviceId: "d", receivedAt: Self.start)
        let started = Self.start + .milliseconds(1_500)
        let finished = started + .milliseconds(600)

        let line = trace.line(startedAt: started, finishedAt: finished, traceAll: false)

        #expect(line == "rpc method=surface.send_key device=d queued_ms=1500 run_ms=600")
    }

    @Test func tracingSwitchReadsOnlyTheExactValue() {
        #expect(InboundRPCTrace.isEnabled([InboundRPCTrace.environmentKey: "1"]))
        #expect(!InboundRPCTrace.isEnabled([InboundRPCTrace.environmentKey: "true"]))
        #expect(!InboundRPCTrace.isEnabled([:]))
    }
}
