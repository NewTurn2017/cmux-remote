import Foundation
import SharedKit
import Testing
@testable import RelayCore
@testable import RelayServer

@Suite("Todo8LoopbackDriverTests", .serialized)
struct Todo8LoopbackDriverTests {
    @Test func twoRealWebSocketsReceiveFullThenDiffFromOneSharedHub() async throws {
        let styledFirst = "\u{1B}[38;2;234;234;234;48;2;40;50;40mgreen\u{1B}[0m"
        let styledSecond = "\u{1B}[38;2;255;210;120;48;2;40;50;40mlatest\u{1B}[0m"
        let fixture = try await HTTPServerFixture.make(screens: [
            Screen(rev: 0, rows: [styledFirst], cols: 6, cursor: CursorPos(x: 5, y: 0)),
            Screen(rev: 0, rows: [styledSecond], cols: 6, cursor: CursorPos(x: 6, y: 0)),
        ])
        do {
            let deviceID = BearerSourceAuthorizer.deviceID(for: "nk-fixture")
            let token = try fixture.deviceStore.register(
                deviceId: deviceID,
                loginName: "a@b",
                hostname: "iPhone",
                apnsToken: nil
            )
            let first = try await LoopbackWebSocketClient.connect(
                group: fixture.group,
                host: fixture.host,
                port: fixture.port,
                token: token
            )
            let hello = "{\"deviceId\":\"\(deviceID)\",\"appVersion\":\"1\",\"protocolVersion\":1}"
            try await first.sendText(hello)
            print("loopback.stage=first-hello")
            let second = try await LoopbackWebSocketClient.connect(
                group: fixture.group,
                host: fixture.host,
                port: fixture.port,
                token: token
            )
            do {
                try await second.sendText(hello)
                print("loopback.stage=second-hello")
                var observedLoopbackFrames: [PushFrame] = []

                let subscribe = #"{"id":"subscribe","method":"surface.subscribe","params":{"workspace_id":"workspace","surface_id":"surface","lines":120,"fps":1}}"#
                let firstResponse = try await first.sendTextAwaitingResponse(subscribe)
                print("loopback.stage=first-subscribed")
                let secondResponse = try await second.sendTextAwaitingResponse(subscribe)
                print("loopback.stage=second-subscribed")
                #expect(try JSONDecoder().decode(RPCResponse.self, from: Data(firstResponse.utf8)).isOk)
                #expect(try JSONDecoder().decode(RPCResponse.self, from: Data(secondResponse.utf8)).isOk)

                let hub = try #require(await fixture.sessionManager.renderHub(surfaceId: "surface"))
                let firstInitial = first.prepareNextText()
                let secondInitial = second.prepareNextText()
                await hub.tick()
                let firstFull = try Self.decodePush(try await first.awaitText(firstInitial))
                let secondFull = try Self.decodePush(try await second.awaitText(secondInitial))
                print("loopback.stage=initial-fulls")

                guard case .screenFull(let firstSnapshot) = firstFull,
                      case .screenFull(let secondSnapshot) = secondFull
                else {
                    Issue.record("each loopback subscriber must start with screen.full")
                    await first.close()
                    await second.close()
                    await fixture.shutdown()
                    return
                }
                observedLoopbackFrames.append(contentsOf: [firstFull, secondFull])
                #expect(firstSnapshot.rows == [styledFirst])
                #expect(secondSnapshot.rows == [styledFirst])
                #expect(await fixture.reader.readCount(surfaceId: "surface") == 1)

                let initialRecoveryFrame = first.prepareNextText()
                let initialRecoveryResponse = first.prepareNextText()
                try await first.sendText(
                    #"{"id":"initial-read","method":"surface.read_text","params":{"workspace_id":"workspace","surface_id":"surface","lines":120}}"#
                )
                let initialRecoveredPush = try Self.decodePush(
                    try await first.awaitText(initialRecoveryFrame)
                )
                print("loopback.stage=initial-recovery-full")
                observedLoopbackFrames.append(initialRecoveredPush)
                guard case .screenFull(let initialRecoveredFull) = initialRecoveredPush else {
                    Issue.record("the first explicit recovery must immediately push screen.full")
                    await first.close()
                    await second.close()
                    await fixture.shutdown()
                    return
                }
                #expect(initialRecoveredFull.rows == [styledFirst])
                let initialResponse = try JSONDecoder().decode(
                    RPCResponse.self,
                    from: Data(try await first.awaitText(initialRecoveryResponse).utf8)
                )
                #expect(initialResponse.isOk)
                #expect(await fixture.reader.readCount(surfaceId: "surface") == 1)

                let firstChanged = first.prepareNextText()
                let secondChanged = second.prepareNextText()
                await hub.tick()
                let firstDiffFrame = try Self.decodePush(try await first.awaitText(firstChanged))
                let secondDiffFrame = try Self.decodePush(try await second.awaitText(secondChanged))
                print("loopback.stage=diffs")
                guard case .screenDiff(let firstDiff) = firstDiffFrame,
                      case .screenDiff(let secondDiff) = secondDiffFrame
                else {
                    Issue.record("stable loopback geometry must continue with screen.diff")
                    await first.close()
                    await second.close()
                    await fixture.shutdown()
                    return
                }
                observedLoopbackFrames.append(contentsOf: [firstDiffFrame, secondDiffFrame])
                #expect(firstDiff == secondDiff)
                #expect(firstDiff.ops == [
                    .row(y: 0, text: styledSecond),
                    .cursor(x: 6, y: 0),
                ])
                #expect(await fixture.reader.readCount(surfaceId: "surface") == 2)

                let recoveredFrame = first.prepareNextText()
                let recoveryResponse = first.prepareNextText()
                try await first.sendText(
                    #"{"id":"recover","method":"surface.read_text","params":{"workspace_id":"workspace","surface_id":"surface","lines":120}}"#
                )
                let recoveredPush = try Self.decodePush(try await first.awaitText(recoveredFrame))
                guard case .screenFull(let recoveredFull) = recoveredPush else {
                    Issue.record("explicit recovery must push the retained styled screen.full")
                    await first.close()
                    await second.close()
                    await fixture.shutdown()
                    return
                }
                let recoveredResponse = try JSONDecoder().decode(
                    RPCResponse.self,
                    from: Data(try await first.awaitText(recoveryResponse).utf8)
                )
                #expect(recoveredResponse.isOk)
                observedLoopbackFrames.append(recoveredPush)
                #expect(recoveredFull.rows == [styledSecond])
                #expect(recoveredFull.rev == firstDiff.rev)
                #expect(await fixture.reader.readCount(surfaceId: "surface") == 2)

                let firstEvent = first.prepareNextText()
                let secondEvent = first.prepareNextText()
                await fixture.sessionManager.broadcastToDevice(
                    deviceId: deviceID,
                    frame: .event(EventFrame(category: .system, name: "event-a", payload: .null))
                )
                await fixture.sessionManager.broadcastToDevice(
                    deviceId: deviceID,
                    frame: .event(EventFrame(category: .system, name: "event-b", payload: .null))
                )
                let eventFrames = [
                    try Self.decodePush(try await first.awaitText(firstEvent)),
                    try Self.decodePush(try await first.awaitText(secondEvent)),
                ]
                let loopbackOrder = eventFrames.compactMap { frame -> String? in
                    guard case .event(let event) = frame else { return nil }
                    return event.name
                }
                #expect(loopbackOrder == ["event-a", "event-b"])

                let loopbackFulls = observedLoopbackFrames.filter { frame in
                    if case .screenFull = frame { return true }
                    return false
                }.count
                let loopbackDiffs = observedLoopbackFrames.filter { frame in
                    if case .screenDiff = frame { return true }
                    return false
                }.count
                let readCount = await fixture.reader.readCount(surfaceId: "surface")
                print(
                    "loopback.fulls=\(loopbackFulls) loopback.diffs=\(loopbackDiffs) "
                    + "loopback.readCount=\(readCount) loopback.order=\(loopbackOrder.joined(separator: ","))"
                )

                try Self.exerciseBackpressureCounters(
                    firstFull: firstSnapshot,
                    latestDiff: firstDiff,
                    latestRow: styledSecond
                )
                await first.close()
                await second.close()
            } catch {
                await first.close()
                await second.close()
                throw error
            }
            await fixture.shutdown()
        } catch {
            await fixture.shutdown()
            throw error
        }
    }

    private static func exerciseBackpressureCounters(
        firstFull: ScreenFull,
        latestDiff: ScreenDiff,
        latestRow: String
    ) throws {
        let latestFull = ScreenFull(
            surfaceId: firstFull.surfaceId,
            rev: latestDiff.rev,
            rows: [latestRow],
            cols: firstFull.cols,
            rowsCount: firstFull.rowsCount,
            cursor: CursorPos(x: 6, y: 0)
        )
        let streamIdentity = UUID(
            uuidString: "00000000-0000-4000-8000-000000000008"
        )!
        let initialOutput = SessionOutboundFrame(
            frame: .screenFull(firstFull),
            recoveryFull: firstFull,
            streamIdentity: streamIdentity
        )
        let latestOutput = SessionOutboundFrame(
            frame: .screenDiff(latestDiff),
            recoveryFull: latestFull,
            streamIdentity: streamIdentity
        )
        let slowChannel = ControllableWebSocketOutputChannel()
        slowChannel.isWritable = false
        let fastChannel = ControllableWebSocketOutputChannel()
        let slowPump = WebSocketOutputPump(channel: slowChannel, maximumQueuedBytes: 2_048)
        let fastPump = WebSocketOutputPump(channel: fastChannel, maximumQueuedBytes: 2_048)

        slowPump.enqueue(initialOutput)
        fastPump.enqueue(initialOutput)
        slowPump.enqueueCritical("critical-a")
        slowPump.enqueue(latestOutput)
        slowPump.enqueueCritical("critical-b")
        fastPump.enqueue(latestOutput)

        fastChannel.completeNextWrite()
        fastChannel.completeNextWrite()
        slowChannel.isWritable = true
        slowPump.writabilityChanged()
        while slowChannel.pendingWriteCount == 1 {
            slowChannel.completeNextWrite()
        }

        let slowPushTexts = slowChannel.writtenTexts.filter { $0.hasPrefix("{") }
        let recovered = try #require(slowPushTexts.last)
        guard case .screenFull(let recoveredFull) = try decodePush(recovered) else {
            Issue.record("slow loopback driver must recover with latest full")
            return
        }
        #expect(recoveredFull.rev == latestDiff.rev)
        #expect(recoveredFull.rows == [latestRow])
        #expect(slowChannel.writtenTexts.filter { $0.hasPrefix("critical") } == [
            "critical-a",
            "critical-b",
        ])
        #expect(slowPump.metrics.maximumQueuedBytes <= 2_048)
        #expect(slowPump.metrics.maximumInFlightWrites == 1)
        #expect(fastPump.metrics.maximumInFlightWrites == 1)

        let maxQueue = slowPump.metrics.maximumQueuedBytes
        let maxInFlight = max(
            slowPump.metrics.maximumInFlightWrites,
            fastPump.metrics.maximumInFlightWrites
        )
        let order = slowChannel.writtenTexts
            .filter { $0.hasPrefix("critical") }
            .joined(separator: ",")
        print(
            "pump.maxRetainedFramedBytes=\(maxQueue) pump.maxInFlight=\(maxInFlight) "
            + "pump.order=\(order)"
        )
    }

    private static func decodePush(_ text: String) throws -> PushFrame {
        try JSONDecoder().decode(PushFrame.self, from: Data(text.utf8))
    }
}
