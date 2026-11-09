import XCTest
import SharedKit
@testable import CmuxRemote

@MainActor
final class RelayVersionStoreTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var sleeps: [Double] = []

    func testRefreshDecodesRelayInfo() async {
        let rpc = RelayRPCScript(info: [
            ok(RelayInfoResult(version: "2.0.0", update: status(.staged, latest: "2.0.1", restartPending: true))),
        ])
        let store = makeStore(rpc)

        await store.refresh(hostID: "mac")

        XCTAssertEqual(store.info?.version, "2.0.0")
        XCTAssertEqual(store.info?.update?.state, .staged)
        XCTAssertEqual(store.info?.update?.latestVersion, "2.0.1")
        XCTAssertFalse(store.isLoading)
        let calls = await rpc.calls
        XCTAssertEqual(calls, ["relay.info"])
    }

    func testRelayInfoIsQueriedOnlyWhenTheCapabilityIsAdvertised() {
        XCTAssertTrue(RelaySettingsPresentation.shouldQueryInfo(isConnected: true, capabilitiesResolved: true, supportsInfo: true))
        XCTAssertFalse(RelaySettingsPresentation.shouldQueryInfo(isConnected: true, capabilitiesResolved: true, supportsInfo: false))
        XCTAssertFalse(RelaySettingsPresentation.shouldQueryInfo(isConnected: true, capabilitiesResolved: false, supportsInfo: false))
        XCTAssertFalse(RelaySettingsPresentation.shouldQueryInfo(isConnected: false, capabilitiesResolved: true, supportsInfo: true))
    }

    func testStartUpdateMapsRelayErrorCodes() async {
        let cases: [(RPCResponse, RelayUpdateRequestFailure)] = [
            (failure(RemoteErrorCode.updateDisabled.rawValue), .disabled),
            (failure(RemoteErrorCode.updateUnavailable.rawValue), .unavailable),
            (failure("temporarily_unavailable"), .failed),
        ]
        for (response, expected) in cases {
            let rpc = RelayRPCScript(info: [ok(RelayInfoResult(version: "2.0.0", update: status(.idle, latest: "2.0.0")))], start: response)
            let store = makeStore(rpc)
            await store.refresh(hostID: "mac")

            await store.startUpdate()

            XCTAssertEqual(store.requestFailure, expected)
            XCTAssertFalse(store.hasPendingRequest)
            XCTAssertEqual(store.requestCount, 0)
            XCTAssertFalse(store.isRequesting)
        }
    }

    func testPollingStopsWhenTheCheckReturnsToIdle() async {
        let rpc = RelayRPCScript(
            info: [
                ok(RelayInfoResult(version: "2.0.0", update: status(.idle, latest: "2.0.0"))),
                ok(RelayInfoResult(version: "2.0.0", update: status(.checking, latest: "2.0.0"))),
                ok(RelayInfoResult(version: "2.0.0", update: status(.idle, latest: "2.0.0"))),
            ],
            start: ok(status(.checking, latest: "2.0.0"))
        )
        let store = makeStore(rpc)
        await store.refresh(hostID: "mac")

        await store.startUpdate()
        XCTAssertTrue(store.hasPendingRequest)
        XCTAssertEqual(store.requestCount, 1)
        await store.pollWhileInProgress(hostID: "mac")

        XCTAssertEqual(sleeps, [2, 2])
        XCTAssertEqual(store.outcome, .upToDate)
        XCTAssertFalse(store.hasPendingRequest)
        XCTAssertFalse(store.shouldPoll)
        let calls = await rpc.calls
        XCTAssertEqual(calls, ["relay.info", "relay.update.start", "relay.info", "relay.info"])
    }

    func testPollingStopsAfterTwentyMinutes() async {
        let rpc = RelayRPCScript(
            info: [
                ok(RelayInfoResult(version: "2.0.0", update: status(.idle, latest: "2.0.0"))),
                ok(RelayInfoResult(version: "2.0.0", update: status(.building, latest: "2.0.1"))),
            ],
            start: ok(status(.building, latest: "2.0.1"))
        )
        let store = makeStore(rpc)
        await store.refresh(hostID: "mac")
        await store.startUpdate()
        let requestedAt = clock

        await store.pollWhileInProgress(hostID: "mac")

        XCTAssertEqual(store.outcome, .timedOut)
        XCTAssertFalse(store.hasPendingRequest)
        XCTAssertEqual(sleeps.count, Int(RelayVersionStore.maxPollSeconds / RelayVersionStore.pollIntervalSeconds))
        XCTAssertEqual(clock.timeIntervalSince(requestedAt), 20 * 60)
        XCTAssertEqual(RelayVersionStore.pollIntervalSeconds, 2)
    }

    func testAutomaticStagedUpdateIsNotPolledUntilTheUserAsks() async {
        let staged = ok(RelayInfoResult(version: "2.0.0", update: status(.staged, latest: "2.0.1", restartPending: true)))
        let rpc = RelayRPCScript(info: [staged], start: ok(status(.staged, latest: "2.0.1", restartPending: true)))
        let store = makeStore(rpc)
        await store.refresh(hostID: "mac")

        XCTAssertFalse(store.shouldPoll)
        await store.pollWhileInProgress(hostID: "mac")
        XCTAssertEqual(sleeps, [])

        await store.startUpdate()
        XCTAssertTrue(store.shouldPoll)
    }

    func testNewVersionAfterRestartReportsUpdated() async {
        let rpc = RelayRPCScript(
            info: [
                ok(RelayInfoResult(version: "2.0.0", update: status(.staged, latest: "2.0.1", restartPending: true))),
                failure("offline"),
                ok(RelayInfoResult(version: "2.0.1", update: status(.idle, latest: "2.0.1"))),
            ],
            start: ok(status(.applying, latest: "2.0.1", restartPending: true))
        )
        let store = makeStore(rpc)
        await store.refresh(hostID: "mac")
        await store.startUpdate()

        await store.refresh(hostID: "mac")
        XCTAssertEqual(store.info?.update?.state, .applying, "a dropped connection keeps the last known state")
        XCTAssertNil(store.outcome)

        await store.refresh(hostID: "mac")
        XCTAssertEqual(store.outcome, .updated(from: "2.0.0", to: "2.0.1"))
        XCTAssertFalse(store.hasPendingRequest)
    }

    func testNewVersionWhileApplyingIsNotSettledUntilIdle() async {
        let rpc = RelayRPCScript(
            info: [
                ok(RelayInfoResult(version: "2.0.0", update: status(.staged, latest: "2.0.1", restartPending: true))),
                ok(RelayInfoResult(version: "2.0.1", update: status(.applying, latest: "2.0.1", restartPending: true))),
                ok(RelayInfoResult(version: "2.0.1", update: status(.idle, latest: "2.0.1"))),
            ],
            start: ok(status(.applying, latest: "2.0.1", restartPending: true))
        )
        let store = makeStore(rpc)
        await store.refresh(hostID: "mac")
        await store.startUpdate()

        await store.refresh(hostID: "mac")
        XCTAssertNil(store.outcome, "the new relay may still be rolled back while the updater applies")
        XCTAssertTrue(store.hasPendingRequest)
        XCTAssertTrue(store.shouldPoll)

        await store.refresh(hostID: "mac")
        XCTAssertEqual(store.outcome, .updated(from: "2.0.0", to: "2.0.1"))
        XCTAssertFalse(store.hasPendingRequest)
    }

    func testRollbackAfterApplyingIsNotReportedAsUpdated() async {
        let rpc = RelayRPCScript(
            info: [
                ok(RelayInfoResult(version: "2.0.0", update: status(.staged, latest: "2.0.1", restartPending: true))),
                ok(RelayInfoResult(version: "2.0.1", update: status(.applying, latest: "2.0.1", restartPending: true))),
                ok(RelayInfoResult(version: "2.0.0", update: status(.failed, latest: "2.0.1", error: .startFailed))),
            ],
            start: ok(status(.applying, latest: "2.0.1", restartPending: true))
        )
        let store = makeStore(rpc)
        await store.refresh(hostID: "mac")
        await store.startUpdate()
        await store.refresh(hostID: "mac")

        await store.refresh(hostID: "mac")

        XCTAssertNil(store.outcome)
        XCTAssertFalse(store.hasPendingRequest)
        XCTAssertEqual(store.info?.update?.lastErrorCode, .startFailed)
    }

    func testFailedRollbackClearsAnEarlierUpdatedResult() async {
        let rpc = RelayRPCScript(
            info: [
                ok(RelayInfoResult(version: "2.0.0", update: status(.idle, latest: "2.0.1"))),
                ok(RelayInfoResult(version: "2.0.1", update: status(.idle, latest: "2.0.1"))),
                ok(RelayInfoResult(version: "2.0.0", update: status(.failed, latest: "2.0.1", error: .startFailed))),
            ],
            start: ok(status(.checking, latest: "2.0.1"))
        )
        let store = makeStore(rpc)
        await store.refresh(hostID: "mac")
        await store.startUpdate()
        await store.refresh(hostID: "mac")
        XCTAssertEqual(store.outcome, .updated(from: "2.0.0", to: "2.0.1"))

        await store.refresh(hostID: "mac")

        XCTAssertNil(store.outcome, "back on the old version with a failure is not an update")
    }

    func testConnectingToAnotherMacForgetsTheRelayVersion() async {
        let coordinator = makeCoordinator()
        await coordinator.connect(rpc: DemoRPCDispatch(), hostID: "mac-a", accountScope: "account")
        await coordinator.relayVersion.refresh(hostID: "mac-a")
        XCTAssertEqual(coordinator.relayVersion.info?.version, CmuxRemoteVersion.marketing)

        await coordinator.deactivate(purgeAccountCache: false)
        coordinator.prepareHost("mac-a")
        XCTAssertNotNil(coordinator.relayVersion.info, "the same Mac keeps its last known version")

        coordinator.prepareHost("mac-b")
        XCTAssertNil(coordinator.relayVersion.info)

        await coordinator.connect(rpc: DemoRPCDispatch(relayScenario: "legacy"), hostID: "mac-b", accountScope: "account")
        XCTAssertNil(coordinator.relayVersion.info)
        XCTAssertTrue(coordinator.capabilitiesResolved)
        XCTAssertFalse(coordinator.capabilities.supportsRelayInfoV1)
    }

    func testCapabilityTimeoutStaysUnresolvedAndIsRetried() async {
        let rpc = CapabilityRPCScript(answers: [
            .timeout,
            .response(ok(HostCapabilitiesResult(capabilities: [HostCapabilities.relayInfoV1, HostCapabilities.relayUpdateV1]))),
        ])
        let coordinator = makeCoordinator()

        await coordinator.connect(rpc: rpc, hostID: "mac", accountScope: "account")
        XCTAssertFalse(coordinator.capabilitiesResolved, "a timeout is not a relay from before 2.0")
        XCTAssertFalse(RelaySettingsPresentation(
            isConnected: true, capabilitiesResolved: coordinator.capabilitiesResolved, supportsInfo: false,
            supportsUpdate: false, info: nil, isLoading: false, isRequesting: false, hasPendingRequest: false
        ).showsManualGuide)

        await coordinator.retryCapabilitiesIfUnresolved()

        XCTAssertTrue(coordinator.capabilitiesResolved)
        XCTAssertTrue(coordinator.capabilities.supportsRelayInfoV1)
        let calls = await rpc.capabilityCalls
        XCTAssertEqual(calls, 2)
    }

    func testCapabilityMethodNotFoundResolvesAsRelayBeforeTwo() async {
        let rpc = CapabilityRPCScript(answers: [.response(failure(RemoteErrorCode.methodNotFound.rawValue))])
        let coordinator = makeCoordinator()

        await coordinator.connect(rpc: rpc, hostID: "mac", accountScope: "account")
        await coordinator.retryCapabilitiesIfUnresolved()

        XCTAssertTrue(coordinator.capabilitiesResolved)
        XCTAssertFalse(coordinator.capabilities.supportsRelayInfoV1)
        let calls = await rpc.capabilityCalls
        XCTAssertEqual(calls, 1)
    }

    func testAnotherHostForgetsThePendingRequest() async {
        let rpc = RelayRPCScript(
            info: [
                ok(RelayInfoResult(version: "2.0.0", update: status(.idle, latest: "2.0.0"))),
                ok(RelayInfoResult(version: "2.1.0", update: status(.idle, latest: "2.1.0"))),
            ],
            start: ok(status(.checking, latest: "2.0.0"))
        )
        let store = makeStore(rpc)
        await store.refresh(hostID: "mac-a")
        await store.startUpdate()

        await store.refresh(hostID: "mac-b")

        XCTAssertEqual(store.info?.version, "2.1.0")
        XCTAssertNil(store.outcome)
        XCTAssertFalse(store.hasPendingRequest)
    }

    func testPresentationMapsStatesToStatusAndButton() {
        typealias P = RelaySettingsPresentation
        let rows: [(String, RelayUpdateStatus, Bool, P.Status, P.UpdateButton)] = [
            ("idle latest", status(.idle, latest: "2.0.0"), false, .upToDate, .enabled),
            ("idle newer", status(.idle, latest: "2.0.1"), false, .available("2.0.1"), .enabled),
            ("idle older", status(.idle, latest: "1.9.0"), false, .upToDate, .enabled),
            ("checking", status(.checking), false, .checking, .disabled),
            ("downloading", status(.downloading), false, .downloading, .disabled),
            ("building", status(.building), false, .building, .disabled),
            ("staged auto", status(.staged, latest: "2.0.1", restartPending: true), false, .staged("2.0.1"), .enabled),
            ("staged requested", status(.staged, latest: "2.0.1", restartPending: true), true, .staged("2.0.1"), .disabled),
            ("applying", status(.applying, restartPending: true), true, .applying, .disabled),
            ("failed", status(.failed, error: .buildFailed), false, .failed(.buildFailed), .enabled),
            ("disabled", status(.disabled, autoUpdate: false), false, .disabled, .hidden),
            ("unavailable", status(.unavailable, autoUpdate: false), false, .unavailable, .hidden),
            ("unknown", status(.unknown("paused")), false, .unknownState("paused"), .enabled),
        ]
        for (name, update, pending, expectedStatus, expectedButton) in rows {
            let presentation = P(
                isConnected: true,
                capabilitiesResolved: true,
                supportsInfo: true,
                supportsUpdate: true,
                info: RelayInfoResult(version: "2.0.0", update: update),
                isLoading: false,
                isRequesting: false,
                hasPendingRequest: pending
            )
            XCTAssertEqual(presentation.version, .known("2.0.0"), name)
            XCTAssertEqual(presentation.status, expectedStatus, name)
            XCTAssertEqual(presentation.updateButton, expectedButton, name)
            XCTAssertEqual(presentation.stateRawValue, update.state.rawValue, name)
            XCTAssertFalse(presentation.showsManualGuide, name)
        }
    }

    func testPresentationHidesUpdateNowWithoutTheCapabilityOrConnection() {
        let info = RelayInfoResult(version: "2.0.0", update: status(.idle, latest: "2.0.0"))
        let withoutUpdate = RelaySettingsPresentation(
            isConnected: true, capabilitiesResolved: true, supportsInfo: true, supportsUpdate: false,
            info: info, isLoading: false, isRequesting: false, hasPendingRequest: false
        )
        XCTAssertEqual(withoutUpdate.updateButton, .hidden)
        XCTAssertEqual(withoutUpdate.status, .upToDate)

        let requesting = RelaySettingsPresentation(
            isConnected: true, capabilitiesResolved: true, supportsInfo: true, supportsUpdate: true,
            info: info, isLoading: false, isRequesting: true, hasPendingRequest: false
        )
        XCTAssertEqual(requesting.updateButton, .disabled)

        let restarting = RelaySettingsPresentation(
            isConnected: false, capabilitiesResolved: false, supportsInfo: false, supportsUpdate: false,
            info: RelayInfoResult(version: "2.0.0", update: status(.applying, restartPending: true)),
            isLoading: false, isRequesting: false, hasPendingRequest: true
        )
        XCTAssertEqual(restarting.status, .restarting)
        XCTAssertEqual(restarting.version, .known("2.0.0"))
        XCTAssertEqual(restarting.updateButton, .hidden)

        let disconnected = RelaySettingsPresentation(
            isConnected: false, capabilitiesResolved: false, supportsInfo: false, supportsUpdate: false,
            info: info, isLoading: false, isRequesting: false, hasPendingRequest: false
        )
        XCTAssertEqual(disconnected.status, .disconnected)
    }

    func testPresentationShowsLegacyRelayWithManualGuide() {
        let legacy = RelaySettingsPresentation(
            isConnected: true, capabilitiesResolved: true, supportsInfo: false, supportsUpdate: false,
            info: RelayInfoResult(version: "2.0.0", update: status(.idle, adhoc: true)),
            isLoading: false, isRequesting: false, hasPendingRequest: false
        )
        XCTAssertEqual(legacy.version, .legacy)
        XCTAssertEqual(legacy.versionAccessibilityValue, "relay=legacy")
        XCTAssertNil(legacy.status)
        XCTAssertTrue(legacy.showsManualGuide)
        XCTAssertFalse(legacy.showsAdhocWarning)
        XCTAssertEqual(legacy.updateButton, .hidden)

        let loading = RelaySettingsPresentation(
            isConnected: true, capabilitiesResolved: false, supportsInfo: false, supportsUpdate: false,
            info: nil, isLoading: false, isRequesting: false, hasPendingRequest: false
        )
        XCTAssertEqual(loading.version, .loading)
        XCTAssertFalse(loading.showsManualGuide)
    }

    func testPresentationCarriesAdhocWarningAndLastChecked() {
        let presentation = RelaySettingsPresentation(
            isConnected: true, capabilitiesResolved: true, supportsInfo: true, supportsUpdate: true,
            info: RelayInfoResult(version: "2.0.0", update: status(.idle, latest: "2.0.0", checkedAt: 1_794_218_403_000, adhoc: true)),
            isLoading: false, isRequesting: false, hasPendingRequest: false
        )
        XCTAssertTrue(presentation.showsAdhocWarning)
        XCTAssertEqual(presentation.autoUpdateEnabled, true)
        XCTAssertEqual(presentation.lastCheckedAt, Date(timeIntervalSince1970: 1_794_218_403))
    }

    func testEveryFailureCodeHasItsOwnReason() {
        let codes: [RelayUpdateFailureCode?] = [
            .networkFailed, .tagVerificationFailed, .buildFailed, .versionMismatch, .signFailed,
            .installFailed, .startFailed, .insufficientDisk, .toolchainMissing, .versionUnknown,
            .interrupted, .unknown("future_code"),
        ]
        let reasons = codes.map(RelaySettingsText.failureReason)
        XCTAssertEqual(Set(reasons).count, codes.count)
        XCTAssertEqual(RelaySettingsText.failureReason(nil), RelaySettingsText.failureReason(.unknown("x")))
        XCTAssertFalse(reasons.contains(where: \.isEmpty))
        XCTAssertTrue(RelaySettingsText.status(.failed(.buildFailed)).contains(RelaySettingsText.failureReason(.buildFailed)))
    }

    func testOutcomeTextNamesBothVersions() throws {
        let text = RelaySettingsText.outcome(.updated(from: "2.0.0", to: "2.0.1"))
        let from = try XCTUnwrap(text.range(of: "2.0.0"), text)
        let to = try XCTUnwrap(text.range(of: "2.0.1"), text)
        XCTAssertLessThan(from.lowerBound, to.lowerBound)
    }

    private func makeCoordinator() -> RemoteFileFeatureCoordinator {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-version-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cacheRoot) }
        let routingRPC = OfflineRPCDispatch()
        return RemoteFileFeatureCoordinator(
            routingRPC: routingRPC,
            attachments: AttachmentCoordinator(store: AttachmentStore(rpc: routingRPC), photoStager: FoundationAttachmentPhotoStager()),
            terminalArtifacts: TerminalArtifactStore(rpc: routingRPC, cache: TerminalArtifactCache(rootURL: cacheRoot))
        )
    }

    private func makeStore(_ rpc: RelayRPCScript) -> RelayVersionStore {
        RelayVersionStore(
            rpc: rpc,
            now: { [unowned self] in self.clock },
            sleep: { [unowned self] seconds in
                self.sleeps.append(seconds)
                self.clock.addTimeInterval(seconds)
            }
        )
    }

    private func status(
        _ state: RelayUpdateState,
        latest: String? = nil,
        checkedAt: Int64? = nil,
        error: RelayUpdateFailureCode? = nil,
        restartPending: Bool = false,
        adhoc: Bool = false,
        autoUpdate: Bool = true
    ) -> RelayUpdateStatus {
        RelayUpdateStatus(
            autoUpdateEnabled: autoUpdate,
            state: state,
            latestVersion: latest,
            lastCheckedAt: checkedAt,
            lastErrorCode: error,
            restartPending: restartPending,
            adhocSigning: adhoc
        )
    }

    private func ok<Value: Encodable>(_ value: Value) -> RPCResponse {
        let data = try! SharedKitJSON.snakeCaseEncoder.encode(value)
        return RPCResponse(id: "r", ok: true, result: try! JSONDecoder().decode(JSONValue.self, from: data))
    }

    private func failure(_ code: String) -> RPCResponse {
        RPCResponse(id: "r", ok: false, error: RPCError(code: code, message: "scripted"))
    }
}

/// Answers `host.capabilities` with one scripted result per call; every other method is not found.
private actor CapabilityRPCScript: RPCDispatch {
    enum Answer: Sendable {
        case response(RPCResponse)
        case timeout
    }

    private var answers: [Answer]
    private(set) var capabilityCalls = 0

    init(answers: [Answer]) {
        self.answers = answers
    }

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        guard method == RemoteRPCMethod.hostCapabilities.rawValue else {
            return RPCResponse(id: "r", ok: false, error: RPCError(code: "method_not_found", message: "scripted"))
        }
        capabilityCalls += 1
        switch answers.removeFirst() {
        case .response(let response): return response
        case .timeout: throw URLError(.timedOut)
        }
    }
}

/// Answers `relay.info` from a list whose last entry repeats, and `relay.update.start` with one response.
private actor RelayRPCScript: RPCDispatch {
    private var infoResponses: [RPCResponse]
    private let startResponse: RPCResponse
    private(set) var calls: [String] = []

    init(info: [RPCResponse], start: RPCResponse = RPCResponse(
        id: "r",
        ok: false,
        error: RPCError(code: "method_not_found", message: "scripted")
    )) {
        infoResponses = info
        startResponse = start
    }

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        calls.append(method)
        switch method {
        case RemoteRPCMethod.relayInfo.rawValue:
            return infoResponses.count > 1 ? infoResponses.removeFirst() : infoResponses[0]
        case RemoteRPCMethod.relayUpdateStart.rawValue:
            return startResponse
        default:
            return RPCResponse(id: "r", ok: false, error: RPCError(code: "method_not_found", message: "scripted"))
        }
    }
}
