import Foundation
import NIOCore
import SharedKit
import Testing
@testable import CMUXClient

@Suite("CMUXTerminalReplayTests")
struct CMUXTerminalReplayTests {
    @Test func capabilitiesDecodesCapabilityAndMethodArrays() async throws {
        try await Self.withFixture { fixture in
            async let pending = fixture.client.capabilities()
            let request = try await Self.nextRequest(from: fixture)
            #expect(request.method == "system.capabilities")
            #expect(request.params == .object([:]))
            try await Self.sendResult(
                .object([
                    "capabilities": .array(Self.supportedCapabilities.map(JSONValue.string)),
                    "methods": .array([.string("surface.read_text"), .string("terminal.replay")]),
                ]),
                for: request,
                through: fixture
            )

            let capabilities = try await pending
            #expect(capabilities.capabilities == Self.supportedCapabilities)
            #expect(capabilities.methods == ["surface.read_text", "terminal.replay"])
            #expect(capabilities.supportsVerifiedTerminalReplay)
        }
    }

    @Test(arguments: [
        "terminal.render_grid.v1",
        "terminal.render_grid.verified_replay.v1",
        "terminal.replay-method",
    ])
    func incompleteReplayContractIsUnsupported(missing: String) async throws {
        try await Self.withFixture { fixture in
            async let pending = fixture.client.terminalRead(
                workspaceId: "workspace-test",
                surfaceId: "surface-test",
                lines: 77
            )
            let capabilityRequest = try await Self.nextRequest(from: fixture)
            #expect(capabilityRequest.method == "system.capabilities")
            let capabilities = missing == "terminal.replay-method"
                ? Self.supportedCapabilities
                : Self.supportedCapabilities.filter { $0 != missing }
            let methods = missing == "terminal.replay-method" ? ["surface.read_text"] : ["terminal.replay"]
            try await Self.sendResult(
                .object([
                    "capabilities": .array(capabilities.map(JSONValue.string)),
                    "methods": .array(methods.map(JSONValue.string)),
                ]),
                for: capabilityRequest,
                through: fixture
            )

            let legacyRequest = try await Self.nextRequest(from: fixture)
            #expect(legacyRequest.method == "surface.read_text")
            #expect(legacyRequest.params == .object([
                "workspace_id": .string("workspace-test"),
                "surface_id": .string("surface-test"),
                "lines": .int(77),
            ]))
            try await Self.sendResult(
                .object(["text": .string("legacy")]),
                for: legacyRequest,
                through: fixture
            )
            guard case .updated(let update) = try await pending else {
                Issue.record("incomplete capability contract did not use legacy mode")
                return
            }
            #expect(update.sourceMode == .legacyText)
        }
    }

    @Test func supportedContractSelectsReplayWithExactViewportParamsAndNoEventSubscription() async throws {
        try await Self.withFixture { fixture in
            async let pending = fixture.client.terminalRead(
                workspaceId: "workspace-test",
                surfaceId: "surface-test",
                lines: 200
            )
            let capabilityMethod = try await Self.answerCapabilities(supported: true, through: fixture)
            let replayRequest = try await Self.nextRequest(from: fixture)
            #expect(replayRequest.method == "terminal.replay")
            #expect(replayRequest.params == .object([
                "surface_id": .string("surface-test"),
                "anchor": .string("viewport"),
            ]))
            #expect(replayRequest.params != .object([
                "surface_id": .string("surface-test"),
                "anchor": .string("screen"),
            ]))
            try await Self.sendResult(Self.replayResult(), for: replayRequest, through: fixture)

            let outcome = try await pending
            guard case .updated(let update) = outcome else {
                Issue.record("supported replay did not produce an update: \(outcome)")
                return
            }
            #expect(update.sourceMode == .renderGrid)
            #expect(update.replayIdentity == CMUXTerminalReplayIdentity(
                epoch: Self.firstEpoch,
                revision: 2
            ))
            #expect([capabilityMethod, replayRequest.method] == ["system.capabilities", "terminal.replay"])
            #expect(![capabilityMethod, replayRequest.method].contains("events.stream"))
        }
    }

    @Test func absentReplayCapabilityUsesExactLegacySurfaceReadText() async throws {
        try await Self.withFixture { fixture in
            async let pending = fixture.client.terminalRead(
                workspaceId: "workspace-test",
                surfaceId: "surface-test",
                lines: 120
            )
            _ = try await Self.answerCapabilities(supported: false, through: fixture)
            let request = try await Self.nextRequest(from: fixture)
            #expect(request.method == "surface.read_text")
            #expect(request.params == .object([
                "workspace_id": .string("workspace-test"),
                "surface_id": .string("surface-test"),
                "lines": .int(120),
            ]))
            try await Self.sendResult(
                .object(["text": .string("legacy\ntext")]),
                for: request,
                through: fixture
            )

            let outcome = try await pending
            guard case .updated(let update) = outcome else {
                Issue.record("legacy read did not produce an update: \(outcome)")
                return
            }
            #expect(update.sourceMode == .legacyText)
            #expect(update.replayIdentity == nil)
            #expect(update.screen.rows == ["legacy", "text"])
        }
    }

    @Test func sameEpochAndRevisionReturnsExplicitUnchangedWithoutReencoding() async throws {
        try await Self.withFixture { fixture in
            let first = try await Self.readSupported(Self.replayResult(), through: fixture, negotiates: true)
            guard case .updated(let update) = first else {
                Issue.record("first replay was not an update")
                return
            }

            let second = try await Self.readSupported(
                Self.replayResult(text: "different"),
                through: fixture,
                negotiates: false
            )
            #expect(second == .unchanged(try #require(update.replayIdentity)))
        }
    }

    @Test func changedRevisionProducesNewScreenAndStableEpochIdentity() async throws {
        try await Self.withFixture { fixture in
            _ = try await Self.readSupported(Self.replayResult(revision: 2, text: "first"), through: fixture, negotiates: true)
            let second = try await Self.readSupported(
                Self.replayResult(revision: 3, text: "second"),
                through: fixture,
                negotiates: false
            )

            guard case .updated(let update) = second else {
                Issue.record("changed revision did not produce an update: \(second)")
                return
            }
            #expect(update.replayIdentity == CMUXTerminalReplayIdentity(epoch: Self.firstEpoch, revision: 3))
            #expect(RenderGridTestSupport.visibleText(update.screen.rows[0]) == "second")
        }
    }

    @Test func newEpochProducesFullScreenIdentityAndRetiresPriorEpoch() async throws {
        try await Self.withFixture { fixture in
            _ = try await Self.readSupported(Self.replayResult(epoch: Self.firstEpoch, revision: 9), through: fixture, negotiates: true)
            let newEpoch = try await Self.readSupported(
                Self.replayResult(epoch: Self.secondEpoch, revision: 1, text: "new epoch"),
                through: fixture,
                negotiates: false
            )
            guard case .updated(let update) = newEpoch else {
                Issue.record("new epoch did not produce a full update: \(newEpoch)")
                return
            }
            #expect(update.replayIdentity == CMUXTerminalReplayIdentity(epoch: Self.secondEpoch, revision: 1))

            let retired = try await Self.readSupported(
                Self.replayResult(epoch: Self.firstEpoch, revision: 10),
                through: fixture,
                negotiates: false
            )
            #expect(retired == .ignored(.retiredEpoch(Self.firstEpoch)))
        }
    }

    @Test func staleRevisionReturnsTypedIgnoreOutcome() async throws {
        try await Self.withFixture { fixture in
            _ = try await Self.readSupported(Self.replayResult(revision: 4), through: fixture, negotiates: true)
            let stale = try await Self.readSupported(
                Self.replayResult(revision: 3),
                through: fixture,
                negotiates: false
            )
            #expect(stale == .ignored(.staleRevision(received: 3, current: 4)))
        }
    }

    @Test func reconnectRefreshesCapabilitiesAndReturnsFullReplayForSameIdentity() async throws {
        let first = try await Self.withFixture { fixture in
            try await Self.readSupported(Self.replayResult(), through: fixture, negotiates: true)
        }
        let reconnected = try await Self.withFixture { fixture in
            try await Self.readSupported(Self.replayResult(), through: fixture, negotiates: true)
        }

        guard case .updated(let firstUpdate) = first,
              case .updated(let reconnectUpdate) = reconnected else {
            Issue.record("each connection must return a full replay")
            return
        }
        #expect(firstUpdate.replayIdentity == reconnectUpdate.replayIdentity)
        #expect(firstUpdate.screen == reconnectUpdate.screen)
    }

    @Test func malformedCapabilitiesAndReplayPropagateTypedErrors() async throws {
        try await Self.withFixture { fixture in
            async let malformedCapabilities = fixture.client.terminalRead(
                workspaceId: "workspace-test",
                surfaceId: "surface-test",
                lines: 120
            )
            let request = try await Self.nextRequest(from: fixture)
            #expect(request.method == "system.capabilities")
            try await Self.sendResult(
                .object(["capabilities": .array([])]),
                for: request,
                through: fixture
            )
            do {
                _ = try await malformedCapabilities
                Issue.record("malformed capabilities unexpectedly succeeded")
            } catch let error as CMUXTerminalSourceError {
                guard case .malformedCapabilities = error else {
                    Issue.record("wrong capability error: \(error)")
                    return
                }
            }
        }

        try await Self.withFixture { fixture in
            async let malformedReplay = fixture.client.terminalRead(
                workspaceId: "workspace-test",
                surfaceId: "surface-test",
                lines: 120
            )
            _ = try await Self.answerCapabilities(supported: true, through: fixture)
            let request = try await Self.nextRequest(from: fixture)
            try await Self.sendResult(.object(["surface_id": .string("surface-test")]), for: request, through: fixture)
            do {
                _ = try await malformedReplay
                Issue.record("malformed replay unexpectedly succeeded")
            } catch let error as CMUXTerminalSourceError {
                guard case .malformedReplay = error else {
                    Issue.record("wrong replay error: \(error)")
                    return
                }
            }
        }
    }

    @Test(arguments: [
        ("surface", CMUXTerminalSourceError.surfaceMismatch(expected: "surface-test", received: "other-surface")),
        ("workspace", CMUXTerminalSourceError.workspaceMismatch(expected: "workspace-test", received: "other-workspace")),
        ("grid-surface", CMUXTerminalSourceError.renderGridSurfaceMismatch(envelope: "surface-test", renderGrid: "other-surface")),
        ("sequence", CMUXTerminalSourceError.sequenceMismatch(envelope: 2, renderGrid: 1)),
        ("dimensions", CMUXTerminalSourceError.dimensionsMismatch(
            envelopeColumns: 13,
            envelopeRows: 2,
            renderGridColumns: 12,
            renderGridRows: 2
        )),
        ("screen-anchor", CMUXTerminalSourceError.unexpectedAnchor("screen")),
        ("partial", CMUXTerminalSourceError.nonFullReplay),
        ("empty-epoch", CMUXTerminalSourceError.invalidEpoch("")),
    ])
    func replayValidationRejectsMismatchedSourceData(
        variant: String,
        expectedError: CMUXTerminalSourceError
    ) async throws {
        try await Self.withFixture { fixture in
            async let pending = fixture.client.terminalRead(
                workspaceId: "workspace-test",
                surfaceId: "surface-test",
                lines: 120
            )
            _ = try await Self.answerCapabilities(supported: true, through: fixture)
            let request = try await Self.nextRequest(from: fixture)
            let result: JSONValue
            switch variant {
            case "surface":
                result = Self.replayResult(surfaceID: "other-surface")
            case "workspace":
                result = Self.replayResult(workspaceID: "other-workspace")
            case "grid-surface":
                result = Self.replayResult(gridSurfaceID: "other-surface")
            case "sequence":
                result = Self.replayResult(sequence: 2)
            case "dimensions":
                result = Self.replayResult(columns: 13)
            case "screen-anchor":
                result = Self.replayResult(anchor: "screen")
            case "partial":
                result = Self.replayResult(full: false)
            default:
                result = Self.replayResult(epoch: "")
            }
            try await Self.sendResult(result, for: request, through: fixture)

            do {
                _ = try await pending
                Issue.record("\(variant) replay unexpectedly succeeded")
            } catch let error as CMUXTerminalSourceError {
                #expect(error == expectedError)
            }
        }
    }

    @Test func replayDispatchErrorPropagatesWithoutLegacyRetry() async throws {
        try await Self.withFixture { fixture in
            async let pending = fixture.client.terminalRead(
                workspaceId: "workspace-test",
                surfaceId: "surface-test",
                lines: 120
            )
            let capabilityMethod = try await Self.answerCapabilities(supported: true, through: fixture)
            let request = try await Self.nextRequest(from: fixture)
            #expect(request.method == "terminal.replay")
            try await Self.sendError(
                RPCError(code: "surface_not_found", message: "surface unavailable"),
                for: request,
                through: fixture
            )

            do {
                _ = try await pending
                Issue.record("dispatch error unexpectedly succeeded")
            } catch CMUXClientError.rpc(let error) {
                #expect(error.code == "surface_not_found")
            }
            #expect([capabilityMethod, request.method] == ["system.capabilities", "terminal.replay"])
        }
    }

    @Test func concurrentReadsShareOneCapabilityNegotiation() async throws {
        try await Self.withFixture { fixture in
            let readCount = 24
            let reads = (0..<readCount).map { index in
                Task {
                    try await fixture.client.terminalRead(
                        workspaceId: "workspace-test",
                        surfaceId: "surface-\(index)",
                        lines: 120
                    )
                }
            }

            let capabilityRequest = try await Self.nextRequest(from: fixture)
            #expect(capabilityRequest.method == "system.capabilities")
            try await Self.sendSupportedCapabilities(for: capabilityRequest, through: fixture)

            var replayRequestCount = 0
            for _ in 0..<readCount {
                let request = try await Self.nextRequest(from: fixture)
                try #require(request.method == "terminal.replay")
                let surfaceID = try Self.requestedSurfaceID(request)
                replayRequestCount += 1
                try await Self.sendResult(
                    Self.replayResult(surfaceID: surfaceID, gridSurfaceID: surfaceID),
                    for: request,
                    through: fixture
                )
            }

            for read in reads {
                guard case .updated(let update) = try await read.value else {
                    Issue.record("concurrent replay did not produce an update")
                    continue
                }
                #expect(update.sourceMode == .renderGrid)
            }
            #expect(replayRequestCount == readCount)
        }
    }

    @Test func cancelledWaitersDoNotCancelSharedNegotiationOrLeakWork() async throws {
        try await Self.withFixture { fixture in
            let readCount = 12
            let cancelledCount = 4
            let reads = (0..<readCount).map { index in
                Task {
                    try await fixture.client.terminalRead(
                        workspaceId: "workspace-test",
                        surfaceId: "cancel-surface-\(index)",
                        lines: 120
                    )
                }
            }

            let capabilityRequest = try await Self.nextRequest(from: fixture)
            #expect(capabilityRequest.method == "system.capabilities")
            for read in reads.prefix(cancelledCount) {
                read.cancel()
            }
            try await Self.sendSupportedCapabilities(for: capabilityRequest, through: fixture)

            for _ in cancelledCount..<readCount {
                let request = try await Self.nextRequest(from: fixture)
                try #require(request.method == "terminal.replay")
                let surfaceID = try Self.requestedSurfaceID(request)
                try await Self.sendResult(
                    Self.replayResult(surfaceID: surfaceID, gridSurfaceID: surfaceID),
                    for: request,
                    through: fixture
                )
            }

            for read in reads.prefix(cancelledCount) {
                do {
                    _ = try await read.value
                    Issue.record("cancelled negotiation waiter unexpectedly completed")
                } catch is CancellationError {
                    // Expected: cancellation detaches only this waiter.
                }
            }
            for read in reads.dropFirst(cancelledCount) {
                guard case .updated = try await read.value else {
                    Issue.record("remaining negotiation waiter did not complete")
                    continue
                }
            }
            let waiterCount = await fixture.client.terminalCapabilityNegotiationWaiters.count
            let hasNegotiationTask = await fixture.client.terminalCapabilityNegotiationTask != nil
            #expect(waiterCount == 0)
            #expect(!hasNegotiationTask)
        }
    }

    @Test func failedSharedNegotiationPropagatesAndNextReadRetriesOnce() async throws {
        try await Self.withFixture { fixture in
            let firstReads = (0..<2).map { index in
                Task {
                    try await fixture.client.terminalRead(
                        workspaceId: "workspace-test",
                        surfaceId: "retry-surface-\(index)",
                        lines: 120
                    )
                }
            }
            let failedRequest = try await Self.nextRequest(from: fixture)
            #expect(failedRequest.method == "system.capabilities")
            try await Self.sendError(
                RPCError(code: "temporarily_unavailable", message: "retry"),
                for: failedRequest,
                through: fixture
            )
            for read in firstReads {
                do {
                    _ = try await read.value
                    Issue.record("failed shared negotiation unexpectedly succeeded")
                } catch CMUXClientError.rpc(let error) {
                    #expect(error.code == "temporarily_unavailable")
                }
            }

            async let retried = fixture.client.terminalRead(
                workspaceId: "workspace-test",
                surfaceId: "retry-surface",
                lines: 120
            )
            let retryRequest = try await Self.nextRequest(from: fixture)
            #expect(retryRequest.method == "system.capabilities")
            try await Self.sendSupportedCapabilities(for: retryRequest, through: fixture)
            let replayRequest = try await Self.nextRequest(from: fixture)
            #expect(replayRequest.method == "terminal.replay")
            try await Self.sendResult(
                Self.replayResult(
                    surfaceID: "retry-surface",
                    gridSurfaceID: "retry-surface"
                ),
                for: replayRequest,
                through: fixture
            )
            guard case .updated = try await retried else {
                Issue.record("retry did not produce a replay update")
                return
            }
        }
    }

    @Test func lifecycleReleaseAndResetForgetAcceptedIdentity() async throws {
        try await Self.withFixture { fixture in
            _ = try await Self.readSupported(Self.replayResult(), through: fixture, negotiates: true)
            await fixture.client.releaseTerminalSource(
                workspaceId: "workspace-test",
                surfaceId: "surface-test"
            )
            let afterRelease = try await Self.readSupported(Self.replayResult(), through: fixture, negotiates: false)
            guard case .updated = afterRelease else {
                Issue.record("release did not forget replay identity")
                return
            }

            await fixture.client.resetTerminalSources()
            let afterReset = try await Self.readSupported(Self.replayResult(), through: fixture, negotiates: false)
            guard case .updated = afterReset else {
                Issue.record("reset did not forget replay identity")
                return
            }
        }
    }

    @Test func orphanedSurfaceStateUsesHardLRUBound() async throws {
        var state = CMUXTerminalContinuityState()
        for index in 0..<CMUXTerminalContinuityState.maximumTrackedSurfaces {
            #expect(state.classify(
                identity: CMUXTerminalReplayIdentity(epoch: Self.epoch(index), revision: 1),
                key: "surface-\(index)"
            ) == .accept)
        }
        #expect(state.count == CMUXTerminalContinuityState.maximumTrackedSurfaces)

        #expect(state.classify(
            identity: CMUXTerminalReplayIdentity(epoch: Self.epoch(0), revision: 1),
            key: "surface-0"
        ) == .unchanged)
        #expect(state.classify(
            identity: CMUXTerminalReplayIdentity(epoch: Self.epoch(999), revision: 1),
            key: "overflow"
        ) == .accept)
        #expect(state.count == CMUXTerminalContinuityState.maximumTrackedSurfaces)
        #expect(state.classify(
            identity: CMUXTerminalReplayIdentity(epoch: Self.epoch(1), revision: 1),
            key: "surface-1"
        ) == .accept)
        #expect(state.classify(
            identity: CMUXTerminalReplayIdentity(epoch: Self.epoch(0), revision: 1),
            key: "surface-0"
        ) == .unchanged)
    }

    @Test func retiredEpochHistoryIsBoundedButRejectsRecentFlipFlops() {
        var state = CMUXTerminalContinuityState()
        let key = "bounded-retired-epochs"
        for index in 0...(CMUXTerminalContinuityState.maximumRetiredEpochsPerSurface + 1) {
            #expect(state.classify(
                identity: CMUXTerminalReplayIdentity(epoch: Self.epoch(index), revision: 1),
                key: key
            ) == .accept)
        }

        let recentIndex = CMUXTerminalContinuityState.maximumRetiredEpochsPerSurface
        #expect(state.classify(
            identity: CMUXTerminalReplayIdentity(epoch: Self.epoch(recentIndex), revision: 2),
            key: key
        ) == .ignored(.retiredEpoch(Self.epoch(recentIndex))))
        #expect(state.classify(
            identity: CMUXTerminalReplayIdentity(epoch: Self.epoch(0), revision: 2),
            key: key
        ) == .accept)
    }

    @Test(arguments: ["render_revision", "full", "anchor"])
    func verifiedReplayRequiresExplicitBoundaryFields(missingField: String) async throws {
        try await Self.withFixture { fixture in
            async let pending = fixture.client.terminalRead(
                workspaceId: "workspace-test",
                surfaceId: "surface-test",
                lines: 120
            )
            _ = try await Self.answerCapabilities(supported: true, through: fixture)
            let request = try await Self.nextRequest(from: fixture)
            try await Self.sendResult(
                Self.replayResult(
                    includeRenderRevision: missingField != "render_revision",
                    includeFull: missingField != "full",
                    includeAnchor: missingField != "anchor"
                ),
                for: request,
                through: fixture
            )
            do {
                _ = try await pending
                Issue.record("missing \(missingField) unexpectedly decoded")
            } catch let error as CMUXTerminalSourceError {
                guard case .malformedReplay = error else {
                    Issue.record("missing \(missingField) returned wrong error: \(error)")
                    return
                }
            }
        }
    }

    @Test(arguments: [
        ("0", UInt64(0)),
        ("18446744073709551615", UInt64.max),
    ])
    func verifiedReplayAcceptsUInt64RevisionBounds(literal: String, expected: UInt64) throws {
        let raw = try SharedKitJSON.snakeCaseDecoder.decode(
            CMUXTerminalReplayRaw.self,
            from: Self.rawReplayData(revisionLiteral: literal)
        )
        #expect(raw.renderGrid.renderRevision.rawValue == expected)
    }

    @Test(arguments: ["-1", "18446744073709551616"])
    func verifiedReplayRejectsInvalidUInt64Revisions(literal: String) {
        do {
            _ = try SharedKitJSON.snakeCaseDecoder.decode(
                CMUXTerminalReplayRaw.self,
                from: Self.rawReplayData(revisionLiteral: literal)
            )
            Issue.record("invalid UInt64 revision \(literal) unexpectedly decoded")
        } catch {
            // Rejection is the asserted behavior for invalid UInt64 literals.
        }
    }

    @Test func productionUnixSocketAuthenticatesAndNegotiatesViewportReplay() async throws {
        try await Self.withUnixSocketFixture { fixture in
            async let authentication: Void = fixture.client.authenticate(
                password: "  production-secret  "
            )
            let authenticationRequest = try await Self.nextRequest(from: fixture)
            #expect(authenticationRequest.method == "auth.login")
            #expect(authenticationRequest.params == .object([
                "password": .string("production-secret"),
            ]))
            try await Self.sendResult(
                .object(["authenticated": .bool(true)]),
                for: authenticationRequest,
                through: fixture
            )
            try await authentication

            async let pending = fixture.client.terminalRead(
                workspaceId: "workspace-grid",
                surfaceId: "surface-grid",
                lines: 120
            )

            let capabilityRequest = try await Self.nextRequest(from: fixture)
            #expect(capabilityRequest.method == "system.capabilities")
            #expect(capabilityRequest.params == .object([:]))
            try await Self.sendSupportedCapabilities(
                for: capabilityRequest,
                through: fixture
            )

            let replayRequest = try await Self.nextRequest(from: fixture)
            #expect(replayRequest.method == "terminal.replay")
            #expect(replayRequest.params == .object([
                "surface_id": .string("surface-grid"),
                "anchor": .string("viewport"),
            ]))
            let replayPayload = try SharedKitJSON.snakeCaseDecoder.decode(
                JSONValue.self,
                from: RenderGridTestSupport.fixtureData()
            )
            try await Self.sendResult(
                replayPayload,
                for: replayRequest,
                through: fixture
            )

            let outcome = try await pending
            let update = try #require({
                if case .updated(let update) = outcome { return update }
                return nil
            }())
            #expect(update.sourceMode == .renderGrid)
            #expect(update.replayIdentity == CMUXTerminalReplayIdentity(
                epoch: "00000000-0000-4000-8000-000000000027",
                revision: 4
            ))
            #expect(update.screen.cols == 18)
            #expect(update.screen.rows.count == 5)
            #expect(update.screen.rows.contains {
                $0.contains(
                    "\u{1B}[38;2;234;234;234;48;2;40;50;40m" +
                        "\u{1B}[?2026;0;11;11zGREEN BLOCK"
                )
            })
        }
    }

    @Test func sourceModeManualDriver() async throws {
        try await Self.withFixture { fixture in
            let first = try await Self.readSupported(Self.replayResult(revision: 2), through: fixture, negotiates: true)
            let same = try await Self.readSupported(Self.replayResult(revision: 2), through: fixture, negotiates: false)
            let changed = try await Self.readSupported(Self.replayResult(revision: 3), through: fixture, negotiates: false)
            let newEpoch = try await Self.readSupported(
                Self.replayResult(epoch: Self.secondEpoch, revision: 1),
                through: fixture,
                negotiates: false
            )

            guard case .updated(let firstUpdate) = first,
                  case .unchanged = same,
                  case .updated(let changedUpdate) = changed,
                  case .updated(let epochUpdate) = newEpoch else {
                Issue.record("source-mode driver observed an unexpected transition")
                return
            }
            print(
                "sourceMode=\(firstUpdate.sourceMode) firstRevision=\(firstUpdate.replayIdentity?.revision ?? 0) "
                    + "sameRevisionSkipped=true changedRevision=\(changedUpdate.replayIdentity?.revision ?? 0) "
                    + "epochChanged=\(firstUpdate.replayIdentity?.epoch != epochUpdate.replayIdentity?.epoch)"
            )
        }
    }

    private static let supportedCapabilities = [
        "terminal.render_grid.v1",
        "terminal.render_grid.verified_replay.v1",
    ]
    private static let firstEpoch = "00000000-0000-4000-8000-000000000001"
    private static let secondEpoch = "00000000-0000-4000-8000-000000000002"

    private static func withFixture<T: Sendable>(
        _ body: @escaping @Sendable (MTELGCmuxFixture) async throws -> T
    ) async throws -> T {
        let fixture = try await MTELGCmuxFixture.make(requestTimeout: .seconds(1))
        do {
            let result = try await body(fixture)
            await fixture.shutdown()
            return result
        } catch {
            await fixture.shutdown()
            throw error
        }
    }

    private static func withUnixSocketFixture<T: Sendable>(
        _ body: @escaping @Sendable (MTELGCmuxFixture) async throws -> T
    ) async throws -> T {
        let fixture = try await MTELGCmuxFixture.makeUnixSocket(
            requestTimeout: .seconds(1)
        )
        do {
            let result = try await body(fixture)
            await fixture.shutdown()
            return result
        } catch {
            await fixture.shutdown()
            throw error
        }
    }

    private static func sendSupportedCapabilities(
        for request: RPCRequest,
        through fixture: MTELGCmuxFixture
    ) async throws {
        try await sendResult(
            .object([
                "capabilities": .array(supportedCapabilities.map(JSONValue.string)),
                "methods": .array([.string("surface.read_text"), .string("terminal.replay")]),
            ]),
            for: request,
            through: fixture
        )
    }

    private static func requestedSurfaceID(_ request: RPCRequest) throws -> String {
        guard case .object(let params) = request.params,
              case .string(let surfaceID) = params["surface_id"] else {
            throw CMUXTerminalSourceError.malformedReplay("terminal.replay request omitted surface_id")
        }
        return surfaceID
    }

    private static func epoch(_ index: Int) -> String {
        "00000000-0000-4000-8000-" + String(format: "%012d", index)
    }

    private static func rawReplayData(revisionLiteral: String) -> Data {
        Data(
            """
            {
              "columns":12,
              "rows":2,
              "seq":1,
              "surface_id":"surface-test",
              "workspace_id":"workspace-test",
              "render_grid":{
                "format":"cmux.render-grid.v1",
                "surface_id":"surface-test",
                "state_seq":1,
                "render_epoch":"00000000-0000-4000-8000-000000000001",
                "render_revision":\(revisionLiteral),
                "columns":12,
                "rows":2,
                "full":true,
                "styles":[{"id":0,"foreground_source":"default","background_source":"default"}],
                "row_spans":[{"row":0,"column":0,"style_id":0,"text":"x"}],
                "anchor":"viewport"
              }
            }
            """.utf8
        )
    }

    private static func answerCapabilities(
        supported: Bool,
        through fixture: MTELGCmuxFixture
    ) async throws -> String {
        let request = try await nextRequest(from: fixture)
        try #require(request.method == "system.capabilities")
        let capabilities = supported ? supportedCapabilities : ["terminal.render_grid.v1"]
        let methods = supported ? ["surface.read_text", "terminal.replay"] : ["surface.read_text"]
        try await sendResult(
            .object([
                "capabilities": .array(capabilities.map(JSONValue.string)),
                "methods": .array(methods.map(JSONValue.string)),
            ]),
            for: request,
            through: fixture
        )
        return request.method
    }

    private static func readSupported(
        _ result: JSONValue,
        through fixture: MTELGCmuxFixture,
        negotiates: Bool
    ) async throws -> CMUXTerminalReadOutcome {
        async let pending = fixture.client.terminalRead(
            workspaceId: "workspace-test",
            surfaceId: "surface-test",
            lines: 120
        )
        if negotiates {
            _ = try await answerCapabilities(supported: true, through: fixture)
        }
        let request = try await nextRequest(from: fixture)
        try #require(request.method == "terminal.replay")
        try await sendResult(result, for: request, through: fixture)
        return try await pending
    }

    private static func nextRequest(from fixture: MTELGCmuxFixture) async throws -> RPCRequest {
        let line = try await fixture.awaitRequestLine()
        return try SharedKitJSON.snakeCaseDecoder.decode(RPCRequest.self, from: Data(line.utf8))
    }

    private static func sendResult(
        _ result: JSONValue,
        for request: RPCRequest,
        through fixture: MTELGCmuxFixture
    ) async throws {
        let response = RPCResponse(id: request.id, result: result)
        let data = try SharedKitJSON.deterministicEncoder.encode(response)
        let line = try #require(String(data: data, encoding: .utf8))
        try await fixture.sendToClient(line: line)
    }

    private static func sendError(
        _ error: RPCError,
        for request: RPCRequest,
        through fixture: MTELGCmuxFixture
    ) async throws {
        let response = RPCResponse(id: request.id, ok: false, error: error)
        let data = try SharedKitJSON.deterministicEncoder.encode(response)
        let line = try #require(String(data: data, encoding: .utf8))
        try await fixture.sendToClient(line: line)
    }

    private static func replayResult(
        surfaceID: String = "surface-test",
        workspaceID: String = "workspace-test",
        gridSurfaceID: String = "surface-test",
        sequence: UInt64 = 1,
        gridSequence: UInt64 = 1,
        columns: Int = 12,
        epoch: String = firstEpoch,
        revision: UInt64 = 2,
        text: String = "styled",
        anchor: String = "viewport",
        full: Bool = true,
        includeRenderRevision: Bool = true,
        includeFull: Bool = true,
        includeAnchor: Bool = true
    ) -> JSONValue {
        var renderGrid: [String: JSONValue] = [
            "format": .string("cmux.render-grid.v1"),
            "surface_id": .string(gridSurfaceID),
            "state_seq": .int(Int64(gridSequence)),
            "render_epoch": .string(epoch),
            "columns": .int(12),
            "rows": .int(2),
            "cursor": .object([
                "row": .int(1),
                "column": .int(0),
                "visible": .bool(true),
                "blinking": .bool(false),
                "style": .int(0),
            ]),
            "styles": .array([.object([
                "id": .int(0),
                "foreground_source": .string("default"),
                "background_source": .string("default"),
            ])]),
            "row_spans": .array([.object([
                "row": .int(0),
                "column": .int(0),
                "style_id": .int(0),
                "text": .string(text),
            ])]),
            "scrollback_rows": .int(0),
            "scrollback_spans": .array([]),
            "terminal_foreground": .string("#eaeaea"),
            "terminal_background": .string("#101820"),
        ]
        if includeRenderRevision {
            renderGrid["render_revision"] = .int(Int64(revision))
        }
        if includeFull {
            renderGrid["full"] = .bool(full)
        }
        if includeAnchor {
            renderGrid["anchor"] = .string(anchor)
        }
        return .object([
            "columns": .int(Int64(columns)),
            "rows": .int(2),
            "seq": .int(Int64(sequence)),
            "surface_id": .string(surfaceID),
            "workspace_id": .string(workspaceID),
            "render_grid": .object(renderGrid),
        ])
    }
}
