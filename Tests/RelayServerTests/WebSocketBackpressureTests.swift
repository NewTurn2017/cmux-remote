import Foundation
import SharedKit
import Testing
@testable import RelayCore
@testable import RelayServer

@Suite("WebSocketBackpressureTests")
struct WebSocketBackpressureTests {
    @Test func unwritableChannelQueuesThenResumesOnWritability() throws {
        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 1_024)

        pump.enqueue(Self.fullOutput(revision: 1, row: "first"))

        #expect(channel.writtenTexts.isEmpty)
        #expect(pump.queuedFrameCount == 1)
        #expect(pump.queuedBytes > 0)
        #expect(pump.queuedBytes <= 1_024)

        channel.isWritable = true
        pump.writabilityChanged()

        #expect(channel.pendingWriteCount == 1)
        #expect(pump.hasWriteInFlight)
        #expect(pump.queuedFrameCount == 0)
        channel.completeNextWrite()
        #expect(!pump.hasWriteInFlight)
        #expect(pump.metrics.writesCompleted == 1)
    }

    @Test func writeCompletionSerializesAtMostOneInFlight() {
        let channel = ControllableWebSocketOutputChannel()
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 1_024)

        pump.enqueueCritical("control-a")
        pump.enqueueCritical("control-b")
        pump.enqueueCritical("control-c")

        #expect(channel.writtenTexts == ["control-a"])
        #expect(channel.pendingWriteCount == 1)
        #expect(pump.queuedFrameCount == 2)
        #expect(channel.maximumInFlightWrites == 1)

        channel.completeNextWrite()
        #expect(channel.writtenTexts == ["control-a", "control-b"])
        #expect(channel.pendingWriteCount == 1)
        #expect(channel.maximumInFlightWrites == 1)

        channel.completeNextWrite()
        #expect(channel.writtenTexts == ["control-a", "control-b", "control-c"])
        #expect(channel.pendingWriteCount == 1)
        channel.completeNextWrite()

        #expect(channel.maximumInFlightWrites == 1)
        #expect(pump.metrics.maximumInFlightWrites == 1)
        #expect(pump.metrics.writesCompleted == 3)
    }

    @Test func slowTerminalOutputCoalescesToLatestFullAndPreservesCriticalOrder() throws {
        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 1_024)

        pump.enqueue(Self.fullOutput(revision: 1, row: "one"))
        pump.enqueueCritical("control-a")
        pump.enqueue(Self.diffOutput(revision: 2, row: "two"))
        pump.enqueueCritical("control-b")
        pump.enqueue(Self.diffOutput(revision: 3, row: "\u{1B}[48;2;40;50;40mthree\u{1B}[0m"))

        #expect(pump.queuedFrameCount == 3)
        #expect(pump.queuedBytes <= 1_024)
        #expect(pump.metrics.maximumQueuedBytes <= 1_024)
        #expect(pump.metrics.coalescedTerminalFrames == 2)

        channel.isWritable = true
        pump.writabilityChanged()
        while channel.pendingWriteCount == 1 {
            channel.completeNextWrite()
        }

        #expect(channel.writtenTexts.count == 3)
        #expect(Array(channel.writtenTexts.prefix(2)) == ["control-a", "control-b"])
        let frame = try JSONDecoder().decode(
            PushFrame.self,
            from: Data(try #require(channel.writtenTexts.last).utf8)
        )
        guard case .screenFull(let full) = frame else {
            Issue.record("coalesced terminal output must recover with screen.full")
            return
        }
        #expect(full.rev == 3)
        #expect(full.rows == ["\u{1B}[48;2;40;50;40mthree\u{1B}[0m"])
        #expect(pump.metrics.fullWrites == 1)
        #expect(pump.metrics.diffWrites == 0)
    }

    @Test func oneBlockedPumpDoesNotDelayAnIndependentWritablePump() {
        let slowChannel = ControllableWebSocketOutputChannel()
        slowChannel.isWritable = false
        let fastChannel = ControllableWebSocketOutputChannel()
        let slowPump = WebSocketOutputPump(channel: slowChannel, maximumQueuedBytes: 1_024)
        let fastPump = WebSocketOutputPump(channel: fastChannel, maximumQueuedBytes: 1_024)

        let full = Self.fullOutput(revision: 1, row: "one")
        let diff = Self.diffOutput(revision: 2, row: "two")
        slowPump.enqueue(full)
        fastPump.enqueue(full)
        slowPump.enqueue(diff)
        fastPump.enqueue(diff)

        #expect(slowChannel.writtenTexts.isEmpty)
        #expect(slowPump.queuedFrameCount == 1)
        #expect(fastChannel.writtenTexts.count == 1)
        #expect(fastChannel.pendingWriteCount == 1)
        fastChannel.completeNextWrite()
        #expect(fastChannel.writtenTexts.count == 2)
        #expect(fastPump.metrics.fullWrites == 1)
        #expect(fastPump.metrics.diffWrites == 1)
        #expect(slowPump.metrics.writesStarted == 0)
        fastChannel.completeNextWrite()
        slowPump.channelClosed()
    }

    @Test func writeFailureClosesAndDiscardsPendingOutput() {
        let channel = ControllableWebSocketOutputChannel()
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 1_024)
        pump.enqueueCritical("first")
        pump.enqueueCritical("second")

        channel.failNextWrite()

        #expect(pump.isClosed)
        #expect(pump.queuedFrameCount == 0)
        #expect(pump.queuedBytes == 0)
        #expect(!pump.hasWriteInFlight)
        #expect(pump.metrics.writeFailures == 1)
        #expect(channel.closeCount == 1)
        pump.close()
        #expect(channel.closeCount == 1)
    }

    @Test func closeIgnoresHungWriteCompletionAndNeverRestartsPump() {
        let channel = ControllableWebSocketOutputChannel()
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 1_024)
        pump.enqueueCritical("hung")
        pump.enqueueCritical("must-discard")

        pump.close()
        #expect(pump.isClosed)
        #expect(pump.queuedFrameCount == 0)
        #expect(!pump.hasWriteInFlight)
        #expect(channel.closeCount == 1)

        channel.completeNextWrite()
        #expect(channel.writtenTexts == ["hung"])
        #expect(pump.metrics.writesCompleted == 0)
        #expect(pump.metrics.discardedFrames == 1)
    }

    @Test func unresolvedWritePromiseDoesNotRetainClosedPumpOrRestartWrites() {
        let channel = ControllableWebSocketOutputChannel()
        weak var releasedPump: WebSocketOutputPump?
        var pump: WebSocketOutputPump? = WebSocketOutputPump(
            channel: channel,
            maximumQueuedBytes: 1_024
        )
        releasedPump = pump
        pump?.enqueueCritical("unresolved")
        pump?.enqueueCritical("discard")
        #expect(channel.pendingWriteCount == 1)

        pump?.close()
        pump = nil

        #expect(releasedPump == nil)
        #expect(channel.closeCount == 1)
        channel.completeNextWrite()
        #expect(channel.writtenTexts == ["unresolved"])
    }

    @Test func unrecoverableCriticalOverflowClosesWithinByteBound() {
        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 10)

        pump.enqueueCritical("12345678")
        #expect(pump.queuedBytes == 10)
        pump.enqueueCritical("x")

        #expect(pump.isClosed)
        #expect(pump.queuedBytes == 0)
        #expect(pump.metrics.maximumQueuedBytes == 10)
        #expect(channel.closeCount == 1)
    }

    @Test func zeroByteCriticalFramesRemainCountBounded() {
        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let pump = WebSocketOutputPump(
            channel: channel,
            maximumQueuedBytes: 8,
            maximumQueuedFrames: 2
        )

        pump.enqueueCritical("")
        pump.enqueueCritical("")
        #expect(pump.queuedFrameCount == 2)
        pump.enqueueCritical("")

        #expect(pump.isClosed)
        #expect(pump.queuedFrameCount == 0)
        #expect(pump.metrics.maximumQueuedFrames == 2)
        #expect(pump.metrics.maximumQueuedBytes == 4)
        #expect(channel.closeCount == 1)
    }

    @Test func queuedBytesCountExactUnmaskedWebSocketFrameSizeBoundaries() {
        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 200_000)

        pump.enqueueCritical("한")
        #expect(pump.queuedBytes == 5)
        pump.enqueueCritical(String(repeating: "a", count: 125))
        #expect(pump.queuedBytes == 5 + 127)
        pump.enqueueCritical(String(repeating: "b", count: 126))
        #expect(pump.queuedBytes == 5 + 127 + 130)
        pump.enqueueCritical(String(repeating: "c", count: 65_535))
        #expect(pump.queuedBytes == 5 + 127 + 130 + 65_539)
        pump.enqueueCritical(String(repeating: "d", count: 65_536))
        #expect(pump.queuedBytes == 5 + 127 + 130 + 65_539 + 65_546)
        #expect(pump.metrics.maximumQueuedBytes == pump.queuedBytes)
        pump.channelClosed()
    }

    @Test func oversizedRecoveryBufferRejectsTinyDiffWithoutUnderstatingQueue() throws {
        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 256)
        let output = Self.terminalOutput(
            surfaceId: "s",
            revision: 1,
            diffRow: "xxxxx",
            recoveryRow: String(repeating: "R", count: 20_000)
        )
        let diffData = try SharedKitJSON.deterministicEncoder.encode(output.frame)
        #expect(try WebSocketFramedSize(payloadBytes: diffData.count).totalBytes == 91)

        pump.enqueue(output)

        #expect(pump.isClosed)
        #expect(pump.queuedFrameCount == 0)
        #expect(pump.queuedBytes == 0)
        #expect(pump.metrics.maximumQueuedBytes == 0)
        #expect(channel.closeCount == 1)
    }

    @Test func withinCapTerminalEntryCountsCurrentAndRecoveryBuffers() throws {
        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let output = Self.terminalOutput(
            surfaceId: "s",
            revision: 1,
            diffRow: "xxxxx",
            recoveryRow: "recovery"
        )
        let currentData = try SharedKitJSON.deterministicEncoder.encode(output.frame)
        let recoveryData = try SharedKitJSON.deterministicEncoder.encode(
            PushFrame.screenFull(try #require(output.recoveryFull))
        )
        let currentBytes = try WebSocketFramedSize(payloadBytes: currentData.count).totalBytes
        let recoveryBytes = try WebSocketFramedSize(payloadBytes: recoveryData.count).totalBytes
        let expectedRetainedBytes = currentBytes + recoveryBytes
        let pump = WebSocketOutputPump(
            channel: channel,
            maximumQueuedBytes: expectedRetainedBytes
        )

        pump.enqueue(output)

        #expect(!pump.isClosed)
        #expect(pump.queuedFrameCount == 1)
        #expect(pump.queuedBytes == expectedRetainedBytes)
        #expect(pump.metrics.maximumQueuedBytes == expectedRetainedBytes)
        pump.channelClosed()
    }

    @Test func equalCurrentAndRecoveryRepresentationsAreConservativelyDoubleCounted() throws {
        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let output = Self.fullOutput(revision: 1, row: "same")
        let data = try SharedKitJSON.deterministicEncoder.encode(output.frame)
        let framedBytes = try WebSocketFramedSize(payloadBytes: data.count).totalBytes
        let pump = WebSocketOutputPump(
            channel: channel,
            maximumQueuedBytes: framedBytes * 2
        )

        pump.enqueue(output)

        #expect(pump.queuedBytes == framedBytes * 2)
        #expect(pump.metrics.maximumQueuedBytes == framedBytes * 2)
        pump.channelClosed()
    }

    @Test func coalescingReplacesCurrentAndRecoveryAccountingExactly() throws {
        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 4_096)
        let first = Self.terminalOutput(
            surfaceId: "replace",
            revision: 1,
            diffRow: "first-diff",
            recoveryRow: "first-recovery"
        )
        let second = Self.terminalOutput(
            surfaceId: "replace",
            revision: 2,
            diffRow: "second-diff",
            recoveryRow: "second-recovery"
        )
        let firstCurrent = try SharedKitJSON.deterministicEncoder.encode(first.frame)
        let firstRecovery = try SharedKitJSON.deterministicEncoder.encode(
            PushFrame.screenFull(try #require(first.recoveryFull))
        )
        let firstRetained = try WebSocketFramedSize(payloadBytes: firstCurrent.count).totalBytes
            + WebSocketFramedSize(payloadBytes: firstRecovery.count).totalBytes
        let secondRecovery = try SharedKitJSON.deterministicEncoder.encode(
            PushFrame.screenFull(try #require(second.recoveryFull))
        )
        let selectedFullBytes = try WebSocketFramedSize(payloadBytes: secondRecovery.count).totalBytes
        let criticalBytes = try WebSocketFramedSize(text: "critical").totalBytes

        pump.enqueue(first)
        #expect(pump.queuedBytes == firstRetained)
        pump.enqueueCritical("critical")
        #expect(pump.queuedBytes == firstRetained + criticalBytes)
        pump.enqueue(second)

        let expectedAfterReplacement = criticalBytes + selectedFullBytes * 2
        #expect(pump.queuedFrameCount == 2)
        #expect(pump.queuedBytes == expectedAfterReplacement)
        #expect(pump.metrics.maximumQueuedBytes == max(
            firstRetained + criticalBytes,
            expectedAfterReplacement
        ))
        pump.channelClosed()
    }

    @Test func sequentialImmediateDrainSurfacesDoNotAccumulateRevisionState() {
        let channel = ControllableWebSocketOutputChannel()
        channel.automaticallyCompletesWrites = true
        let pump = WebSocketOutputPump(
            channel: channel,
            maximumQueuedBytes: 1_000_000,
            maximumQueuedFrames: 1_024
        )

        for index in 0..<2_048 {
            pump.enqueue(Self.terminalOutput(
                surfaceId: "retired-\(index)",
                revision: 1,
                diffRow: "",
                recoveryRow: ""
            ))
            pump.retire(
                surfaceId: "retired-\(index)",
                streamIdentity: Self.streamIdentity
            )
            channel.run()
        }

        #expect(pump.queuedFrameCount == 0)
        #expect(pump.queuedBytes == 0)
        #expect(pump.terminalRevisionStateCount == 0)
        #expect(pump.pendingRetirementCount == 0)
        #expect(pump.metrics.maximumTerminalRevisionStates == 1)
        #expect(!pump.isClosed)
    }

    @Test func inFlightRetirementWaitsThenClearsAndRejectsLateOldFrame() {
        let channel = ControllableWebSocketOutputChannel()
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 4_096)
        let identity = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!

        pump.enqueue(Self.terminalOutput(
            surfaceId: "surface",
            revision: 1,
            diffRow: "first",
            recoveryRow: "first",
            streamIdentity: identity
        ))
        #expect(pump.terminalRevisionStateCount == 1)
        pump.retire(surfaceId: "surface", streamIdentity: identity)
        pump.retire(surfaceId: "surface", streamIdentity: identity)
        #expect(pump.pendingRetirementCount == 1)
        #expect(pump.terminalRevisionStateCount == 1)

        pump.enqueue(Self.terminalOutput(
            surfaceId: "surface",
            revision: 2,
            diffRow: "late",
            recoveryRow: "late",
            streamIdentity: identity
        ))
        #expect(pump.queuedFrameCount == 0)
        #expect(pump.metrics.staleTerminalFrames == 1)

        channel.completeNextWrite()
        #expect(pump.pendingRetirementCount == 0)
        #expect(pump.terminalRevisionStateCount == 0)
        #expect(channel.writtenTexts.count == 1)
    }

    @Test func staleRetirementCannotRemoveNewStreamAndOtherSurfaceIsPreserved() {
        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 4_096)
        let oldIdentity = UUID(uuidString: "00000000-0000-4000-8000-000000000012")!
        let newIdentity = UUID(uuidString: "00000000-0000-4000-8000-000000000013")!
        let otherIdentity = UUID(uuidString: "00000000-0000-4000-8000-000000000014")!

        pump.enqueue(Self.terminalOutput(
            surfaceId: "surface",
            revision: 9,
            diffRow: "old",
            recoveryRow: "old",
            streamIdentity: oldIdentity
        ))
        pump.enqueue(Self.terminalOutput(
            surfaceId: "other",
            revision: 1,
            diffRow: "other",
            recoveryRow: "other",
            streamIdentity: otherIdentity
        ))
        pump.enqueue(Self.terminalOutput(
            surfaceId: "surface",
            revision: 1,
            diffRow: "new",
            recoveryRow: "new",
            streamIdentity: newIdentity
        ))

        pump.retire(surfaceId: "surface", streamIdentity: oldIdentity)
        #expect(pump.terminalRevisionStateCount == 2)
        #expect(pump.queuedFrameCount == 2)
        pump.retire(surfaceId: "other", streamIdentity: otherIdentity)
        #expect(pump.terminalRevisionStateCount == 1)
        #expect(pump.queuedFrameCount == 1)
        pump.retire(surfaceId: "surface", streamIdentity: newIdentity)
        #expect(pump.terminalRevisionStateCount == 0)
        #expect(pump.queuedFrameCount == 0)
        #expect(pump.queuedBytes == 0)
        #expect(!pump.isClosed)
    }

    @Test func framedSizeOverflowAndManySurfaceFrameBoundAreDeterministic() throws {
        #expect(throws: WebSocketFramedSizeError.overflow) {
            _ = try WebSocketFramedSize(payloadBytes: Int.max)
        }

        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let pump = WebSocketOutputPump(
            channel: channel,
            maximumQueuedBytes: 1_000_000,
            maximumQueuedFrames: 1_024
        )
        var expectedRetainedBytes = 0
        for index in 0..<1_024 {
            let output = Self.terminalOutput(
                surfaceId: "surface-\(index)",
                revision: 1,
                diffRow: "",
                recoveryRow: ""
            )
            let current = try SharedKitJSON.deterministicEncoder.encode(output.frame)
            let recovery = try SharedKitJSON.deterministicEncoder.encode(
                PushFrame.screenFull(try #require(output.recoveryFull))
            )
            expectedRetainedBytes += try WebSocketFramedSize(payloadBytes: current.count).totalBytes
            expectedRetainedBytes += try WebSocketFramedSize(payloadBytes: recovery.count).totalBytes
            pump.enqueue(output)
        }

        #expect(pump.queuedFrameCount == 1_024)
        #expect(pump.queuedBytes == expectedRetainedBytes)
        #expect(pump.metrics.maximumQueuedBytes == expectedRetainedBytes)
        pump.enqueue(Self.terminalOutput(
            surfaceId: "surface-overflow",
            revision: 1,
            diffRow: "",
            recoveryRow: ""
        ))
        #expect(pump.isClosed)
        #expect(pump.queuedFrameCount == 0)
        #expect(pump.metrics.maximumQueuedBytes == expectedRetainedBytes)
    }

    @Test func framedByteLimitAcceptsExactBoundaryAndRejectsOneByteUnder() {
        let exactChannel = ControllableWebSocketOutputChannel()
        exactChannel.isWritable = false
        let exactPump = WebSocketOutputPump(channel: exactChannel, maximumQueuedBytes: 5)
        exactPump.enqueueCritical("한")
        #expect(!exactPump.isClosed)
        #expect(exactPump.queuedBytes == 5)
        exactPump.channelClosed()

        let overChannel = ControllableWebSocketOutputChannel()
        overChannel.isWritable = false
        let overPump = WebSocketOutputPump(channel: overChannel, maximumQueuedBytes: 4)
        overPump.enqueueCritical("한")
        #expect(overPump.isClosed)
        #expect(overPump.metrics.maximumQueuedBytes == 0)
        #expect(overChannel.closeCount == 1)

        let hugeExactChannel = ControllableWebSocketOutputChannel()
        hugeExactChannel.isWritable = false
        let hugeExactPump = WebSocketOutputPump(
            channel: hugeExactChannel,
            maximumQueuedBytes: 65_546
        )
        hugeExactPump.enqueueCritical(String(repeating: "x", count: 65_536))
        #expect(!hugeExactPump.isClosed)
        #expect(hugeExactPump.queuedBytes == 65_546)
        hugeExactPump.channelClosed()

        let hugeOverChannel = ControllableWebSocketOutputChannel()
        hugeOverChannel.isWritable = false
        let hugeOverPump = WebSocketOutputPump(
            channel: hugeOverChannel,
            maximumQueuedBytes: 65_545
        )
        hugeOverPump.enqueueCritical(String(repeating: "x", count: 65_536))
        #expect(hugeOverPump.isClosed)
        #expect(hugeOverChannel.closeCount == 1)
    }

    @Test func manyTinyFramesIncludeHeaderOverhead() {
        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let pump = WebSocketOutputPump(
            channel: channel,
            maximumQueuedBytes: 20,
            maximumQueuedFrames: 10
        )

        for _ in 0..<10 {
            pump.enqueueCritical("")
        }

        #expect(pump.queuedFrameCount == 10)
        #expect(pump.queuedBytes == 20)
        pump.enqueueCritical("")
        #expect(pump.isClosed)
        #expect(pump.metrics.maximumQueuedBytes == 20)
    }

    @Test func staleTerminalRevisionCannotReplaceNewerQueuedState() throws {
        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 2_048)

        pump.enqueue(Self.fullOutput(revision: 3, row: "newest"))
        pump.enqueueCritical("critical-a")
        pump.enqueue(Self.diffOutput(revision: 2, row: "stale"))
        pump.enqueueCritical("critical-b")

        channel.isWritable = true
        pump.writabilityChanged()
        while channel.pendingWriteCount == 1 {
            channel.completeNextWrite()
        }

        let critical = channel.writtenTexts.filter { $0.hasPrefix("critical") }
        #expect(critical == ["critical-a", "critical-b"])
        let terminalText = try #require(channel.writtenTexts.first { $0.hasPrefix("{") })
        guard case .screenFull(let full) = try JSONDecoder().decode(
            PushFrame.self,
            from: Data(terminalText.utf8)
        ) else {
            Issue.record("queued terminal state must remain a baseline-safe full")
            return
        }
        #expect(full.rev == 3)
        #expect(full.rows == ["newest"])
    }

    @Test func freshStreamIdentityResetsRevisionAndRejectsRetiredCallbacks() throws {
        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 2_048)
        let oldIdentity = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let newIdentity = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

        pump.enqueue(Self.fullOutput(
            revision: 9,
            row: "old-stream",
            streamIdentity: oldIdentity
        ))
        pump.enqueue(Self.fullOutput(
            revision: 1,
            row: "new-stream",
            streamIdentity: newIdentity
        ))
        pump.enqueue(Self.fullOutput(
            revision: 10,
            row: "retired-callback",
            streamIdentity: oldIdentity
        ))

        channel.isWritable = true
        pump.writabilityChanged()
        let text = try #require(channel.writtenTexts.first)
        guard case .screenFull(let full) = try JSONDecoder().decode(
            PushFrame.self,
            from: Data(text.utf8)
        ) else {
            Issue.record("a fresh stream identity must establish a full baseline")
            return
        }
        #expect(full.rev == 1)
        #expect(full.rows == ["new-stream"])
        #expect(pump.metrics.staleTerminalFrames == 1)
        channel.completeNextWrite()
    }

    @Test func equalTerminalRevisionUsesLatestAuthoritativeRecoveryFull() throws {
        let channel = ControllableWebSocketOutputChannel()
        channel.isWritable = false
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 2_048)

        pump.enqueue(Self.fullOutput(revision: 3, row: "before-reset"))
        pump.enqueue(Self.diffOutput(revision: 3, row: "after-reset"))

        channel.isWritable = true
        pump.writabilityChanged()
        let text = try #require(channel.writtenTexts.first)
        guard case .screenFull(let full) = try JSONDecoder().decode(
            PushFrame.self,
            from: Data(text.utf8)
        ) else {
            Issue.record("equal revision replacement must remain a full baseline")
            return
        }
        #expect(full.rev == 3)
        #expect(full.rows == ["after-reset"])
        channel.completeNextWrite()
    }

    @Test func deterministicEncodingRetainsEstablishedWireKeys() throws {
        let channel = ControllableWebSocketOutputChannel()
        let pump = WebSocketOutputPump(channel: channel, maximumQueuedBytes: 1_024)

        pump.enqueue(Self.fullOutput(revision: 7, row: "styled"))

        let text = try #require(channel.writtenTexts.first)
        #expect(text == #"{"cols":10,"cursor":{"x":0,"y":0},"rev":7,"rows":["styled"],"rowsCount":1,"surface_id":"surface","type":"screen.full"}"#)
        channel.completeNextWrite()
    }

    private static func terminalOutput(
        surfaceId: String,
        revision: Int,
        diffRow: String,
        recoveryRow: String,
        streamIdentity: UUID = Self.streamIdentity
    ) -> SessionOutboundFrame {
        let full = ScreenFull(
            surfaceId: surfaceId,
            rev: revision,
            rows: [recoveryRow],
            cols: recoveryRow.count,
            rowsCount: 1,
            cursor: CursorPos(x: 0, y: 0)
        )
        return SessionOutboundFrame(
            frame: .screenDiff(ScreenDiff(
                surfaceId: surfaceId,
                rev: revision,
                ops: [.row(y: 0, text: diffRow)]
            )),
            recoveryFull: full,
            streamIdentity: streamIdentity
        )
    }

    private static func fullOutput(
        revision: Int,
        row: String,
        streamIdentity: UUID = Self.streamIdentity
    ) -> SessionOutboundFrame {
        let full = ScreenFull(
            surfaceId: "surface",
            rev: revision,
            rows: [row],
            cols: 10,
            rowsCount: 1,
            cursor: CursorPos(x: 0, y: 0)
        )
        return SessionOutboundFrame(
            frame: .screenFull(full),
            recoveryFull: full,
            streamIdentity: streamIdentity
        )
    }

    private static func diffOutput(revision: Int, row: String) -> SessionOutboundFrame {
        let full = ScreenFull(
            surfaceId: "surface",
            rev: revision,
            rows: [row],
            cols: 10,
            rowsCount: 1,
            cursor: CursorPos(x: 0, y: 0)
        )
        return SessionOutboundFrame(
            frame: .screenDiff(ScreenDiff(
                surfaceId: "surface",
                rev: revision,
                ops: [.row(y: 0, text: row)]
            )),
            recoveryFull: full,
            streamIdentity: Self.streamIdentity
        )
    }

    private static let streamIdentity = UUID(
        uuidString: "00000000-0000-4000-8000-000000000008"
    )!
}
