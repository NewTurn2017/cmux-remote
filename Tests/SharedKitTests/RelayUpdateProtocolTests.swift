import Foundation
import Testing
@testable import SharedKit

@Suite("Relay update protocol")
struct RelayUpdateProtocolTests {
    private let states: [(RelayUpdateState, String)] = [
        (.idle, "idle"), (.checking, "checking"), (.downloading, "downloading"), (.building, "building"),
        (.staged, "staged"), (.applying, "applying"), (.failed, "failed"), (.disabled, "disabled"),
        (.unavailable, "unavailable"),
    ]

    private let failures: [(RelayUpdateFailureCode, String)] = [
        (.networkFailed, "network_failed"), (.tagVerificationFailed, "tag_verification_failed"),
        (.buildFailed, "build_failed"), (.versionMismatch, "version_mismatch"), (.signFailed, "sign_failed"),
        (.installFailed, "install_failed"), (.startFailed, "start_failed"), (.insufficientDisk, "insufficient_disk"),
        (.toolchainMissing, "toolchain_missing"), (.versionUnknown, "version_unknown"), (.interrupted, "interrupted"),
    ]

    private func keys<Value: Encodable>(_ value: Value) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: SharedKitJSON.snakeCaseEncoder.encode(value)) as? [String: Any]
        return Set(object?.keys.map { $0 } ?? [])
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try SharedKitJSON.snakeCaseDecoder.decode(type, from: Data(json.utf8))
    }

    /// Encodes a response the way the relay does: a snake_case result inside a deterministic envelope.
    private func relayWire(_ response: RPCResponse) throws -> String {
        String(decoding: try SharedKitJSON.deterministicEncoder.encode(response), as: UTF8.self)
    }

    private func success<Value: Encodable>(id: String, _ value: Value) throws -> RPCResponse {
        let result = try JSONDecoder().decode(JSONValue.self, from: SharedKitJSON.snakeCaseEncoder.encode(value))
        return RPCResponse(id: id, ok: true, result: result, error: nil)
    }

    @Test func newIdentifiersHaveExactWireValues() throws {
        #expect(RemoteRPCMethod.relayInfo.rawValue == "relay.info")
        #expect(RemoteRPCMethod.relayUpdateStart.rawValue == "relay.update.start")
        #expect(RemoteRPCMethod(rawValue: "relay.info") == .relayInfo)
        #expect(RemoteRPCMethod(rawValue: "relay.update.start") == .relayUpdateStart)

        #expect(HostCapabilities.relayInfoV1 == "relay.info.v1")
        #expect(HostCapabilities.relayUpdateV1 == "relay.update.v1")
        #expect(HostCapabilitiesResult.relayInfoV1Capability == "relay.info.v1")
        #expect(HostCapabilitiesResult.relayUpdateV1Capability == "relay.update.v1")
        #expect(HostCapabilitiesResult(capabilities: ["relay.info.v1"]).supportsRelayInfoV1)
        #expect(!HostCapabilitiesResult(capabilities: ["relay.info.v1"]).supportsRelayUpdateV1)
        #expect(HostCapabilitiesResult(capabilities: ["relay.update.v1"]).supportsRelayUpdateV1)
        #expect(!HostCapabilitiesResult(capabilities: ["feed.v1"]).supportsRelayInfoV1)

        for (code, raw) in [(RemoteErrorCode.updateDisabled, "update_disabled"), (.updateUnavailable, "update_unavailable")] {
            #expect(code.rawValue == raw)
            #expect(RemoteErrorCode(rawValue: raw) == code)
            let encoded = try JSONEncoder().encode(code)
            #expect(String(decoding: encoded, as: UTF8.self) == "\"\(raw)\"")
            #expect(try JSONDecoder().decode(RemoteErrorCode.self, from: encoded) == code)
        }
        #expect(RemoteErrorCode(rawValue: "update_in_progress") == .unknown("update_in_progress"))
        #expect(RemoteErrorCode(rawValue: "update_up_to_date") == .unknown("update_up_to_date"))
    }

    @Test func statesAndFailureCodesRoundTripAndKeepUnknownValues() throws {
        for (state, raw) in states {
            #expect(state.rawValue == raw)
            #expect(RelayUpdateState(rawValue: raw) == state)
            let encoded = try JSONEncoder().encode(state)
            #expect(String(decoding: encoded, as: UTF8.self) == "\"\(raw)\"")
            #expect(try JSONDecoder().decode(RelayUpdateState.self, from: encoded) == state)
        }
        for (code, raw) in failures {
            #expect(code.rawValue == raw)
            #expect(RelayUpdateFailureCode(rawValue: raw) == code)
            let encoded = try JSONEncoder().encode(code)
            #expect(String(decoding: encoded, as: UTF8.self) == "\"\(raw)\"")
            #expect(try JSONDecoder().decode(RelayUpdateFailureCode.self, from: encoded) == code)
        }

        let future = try decode(RelayInfoResult.self, #"""
        {"version":"2.1.0","future_field":1,"update":{"auto_update_enabled":true,"state":"verifying","last_error_code":"quota_exceeded"}}
        """#)
        #expect(future.update?.state == .unknown("verifying"))
        #expect(future.update?.lastErrorCode == .unknown("quota_exceeded"))
        let reencoded = try relayWire(success(id: "u", future))
        #expect(reencoded.contains(#""state":"verifying""#))
        #expect(reencoded.contains(#""last_error_code":"quota_exceeded""#))
    }

    @Test func requestsSendEmptyParams() throws {
        let info = try RPCRequest(id: "r-1", method: RemoteRPCMethod.relayInfo.rawValue, payload: RelayInfoRequest())
        #expect(info.params == .object([:]))
        let start = try RPCRequest(id: "r-2", method: RemoteRPCMethod.relayUpdateStart.rawValue, payload: RelayUpdateStartRequest())
        #expect(start.params == .object([:]))
        #expect(try decode(RelayInfoRequest.self, "{}") == RelayInfoRequest())
        #expect(try decode(RelayUpdateStartRequest.self, "{}") == RelayUpdateStartRequest())
    }

    @Test func statusUsesSnakeCaseKeysAndOmitsNilAndFalseFlags() throws {
        let full = RelayUpdateStatus(
            autoUpdateEnabled: true,
            state: .failed,
            latestVersion: "2.0.1",
            lastCheckedAt: 1_794_218_403_000,
            lastErrorCode: .startFailed,
            restartPending: true,
            adhocSigning: true
        )
        #expect(try keys(full) == [
            "auto_update_enabled", "state", "latest_version", "last_checked_at", "last_error_code",
            "restart_pending", "adhoc_signing",
        ])
        #expect(try keys(RelayUpdateStatus(autoUpdateEnabled: false, state: .unavailable)) == ["auto_update_enabled", "state"])

        let falseFlags = RelayUpdateStatus(autoUpdateEnabled: true, state: .idle, restartPending: false, adhocSigning: false)
        #expect(falseFlags.restartPending == nil)
        #expect(falseFlags.adhocSigning == nil)
        #expect(try keys(falseFlags) == ["auto_update_enabled", "state"])
        let decodedFalse = try decode(RelayUpdateStatus.self, #"{"auto_update_enabled":true,"state":"idle","restart_pending":false,"adhoc_signing":false}"#)
        #expect(decodedFalse == falseFlags)
    }

    @Test func malformedStatusAndInfoReportTheField() {
        #expect(throws: RemoteProtocolError.missingField("state")) {
            try decode(RelayUpdateStatus.self, #"{"auto_update_enabled":true}"#)
        }
        #expect(throws: RemoteProtocolError.missingField("auto_update_enabled")) {
            try decode(RelayUpdateStatus.self, #"{"state":"idle"}"#)
        }
        #expect(throws: RemoteProtocolError.invalidField("last_checked_at")) {
            try decode(RelayUpdateStatus.self, #"{"auto_update_enabled":true,"state":"idle","last_checked_at":"soon"}"#)
        }
        #expect(throws: RemoteProtocolError.invalidField("state")) {
            try decode(RelayUpdateStatus.self, #"{"auto_update_enabled":true,"state":3}"#)
        }
        #expect(throws: RemoteProtocolError.missingField("version")) {
            try decode(RelayInfoResult.self, #"{"update":{"auto_update_enabled":true,"state":"idle"}}"#)
        }
    }

    @Test func relayEncodedResponsesMatchTheContract() throws {
        let staged = RelayInfoResult(version: "2.0.0", update: RelayUpdateStatus(
            autoUpdateEnabled: true,
            state: .staged,
            latestVersion: "2.0.1",
            lastCheckedAt: 1_794_218_403_000,
            restartPending: true
        ))
        let unavailable = RelayInfoResult(version: "2.0.0", update: RelayUpdateStatus(autoUpdateEnabled: false, state: .unavailable))
        let failed = RelayInfoResult(version: "2.0.0", update: RelayUpdateStatus(
            autoUpdateEnabled: true,
            state: .failed,
            latestVersion: "2.0.1",
            lastCheckedAt: 1_794_218_403_000,
            lastErrorCode: .buildFailed,
            adhocSigning: true
        ))
        let started = RelayUpdateStatus(
            autoUpdateEnabled: true,
            state: .checking,
            latestVersion: "2.0.0",
            lastCheckedAt: 1_794_218_403_000
        )
        let samples: [(String, RPCResponse, String)] = [
            ("relay-info-staged", try success(id: "r-1", staged),
             #"{"id":"r-1","ok":true,"result":{"update":{"auto_update_enabled":true,"last_checked_at":1794218403000,"latest_version":"2.0.1","restart_pending":true,"state":"staged"},"version":"2.0.0"}}"#),
            ("relay-info-unavailable", try success(id: "r-2", unavailable),
             #"{"id":"r-2","ok":true,"result":{"update":{"auto_update_enabled":false,"state":"unavailable"},"version":"2.0.0"}}"#),
            ("relay-info-failed-adhoc", try success(id: "r-3", failed),
             #"{"id":"r-3","ok":true,"result":{"update":{"adhoc_signing":true,"auto_update_enabled":true,"last_checked_at":1794218403000,"last_error_code":"build_failed","latest_version":"2.0.1","state":"failed"},"version":"2.0.0"}}"#),
            ("relay-update-start-checking", try success(id: "r-4", started),
             #"{"id":"r-4","ok":true,"result":{"auto_update_enabled":true,"last_checked_at":1794218403000,"latest_version":"2.0.0","state":"checking"}}"#),
            ("relay-update-start-disabled", RPCResponse(id: "r-5", ok: false, result: nil, error: RPCError(
                code: RemoteErrorCode.updateDisabled.rawValue,
                message: "Relay auto-update is turned off on the Mac"
            )),
             #"{"error":{"code":"update_disabled","message":"Relay auto-update is turned off on the Mac"},"id":"r-5","ok":false}"#),
        ]
        for (label, response, expected) in samples {
            let wire = try relayWire(response)
            print("RELAY_UPDATE_WIRE_SAMPLE \(label) \(wire)")
            #expect(wire == expected, "\(label)")
        }

        let decodedStaged = try JSONDecoder().decode(RPCResponse.self, from: Data(samples[0].2.utf8))
        #expect(try decodedStaged.decodeResult(RelayInfoResult.self) == staged)
        let decodedStart = try JSONDecoder().decode(RPCResponse.self, from: Data(samples[3].2.utf8))
        #expect(try decodedStart.decodeResult(RelayUpdateStatus.self) == started)
        let decodedError = try JSONDecoder().decode(RPCResponse.self, from: Data(samples[4].2.utf8))
        #expect(RemoteErrorCode(rawValue: try #require(decodedError.error).code) == .updateDisabled)
    }
}
