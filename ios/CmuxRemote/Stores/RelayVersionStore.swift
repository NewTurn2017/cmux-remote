import Foundation
import Observation
import SharedKit

/// Why `relay.update.start` could not start an update.
enum RelayUpdateRequestFailure: Equatable, Sendable {
    /// `update_disabled`: auto-update is turned off on the Mac.
    case disabled
    /// `update_unavailable`: the relay has no working updater.
    case unavailable
    /// Any other error, including a dropped connection.
    case failed
}

/// How a user-requested update ended, as seen from the phone.
enum RelayUpdateOutcome: Equatable, Sendable {
    case updated(from: String, to: String)
    case upToDate
    case timedOut
}

/// Reads `relay.info`, starts `relay.update.start`, and polls while an update runs.
///
/// The last known info survives disconnects so a relay restart can be reported as
/// "updated A → B" once the phone reconnects to the same host.
@MainActor
@Observable
final class RelayVersionStore {
    typealias Sleeper = @MainActor (Double) async throws -> Void

    /// Poll interval while an update is in progress (APP-CONTRACT-NOTES `polling`).
    static let pollIntervalSeconds: Double = 2
    /// Longest a single polling run lasts, measured from the user's request when there is one.
    static let maxPollSeconds: TimeInterval = 20 * 60

    private(set) var info: RelayInfoResult?
    private(set) var isLoading = false
    private(set) var isRequesting = false
    private(set) var requestFailure: RelayUpdateRequestFailure?
    private(set) var outcome: RelayUpdateOutcome?
    /// Bumped on every accepted request so a view can restart its polling task.
    private(set) var requestCount = 0
    private(set) var requestedAt: Date?

    @ObservationIgnored private let rpc: any RPCDispatch
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: Sleeper
    @ObservationIgnored private var hostID: String?
    @ObservationIgnored private var requestedFromVersion: String?
    @ObservationIgnored private var token = 0

    init(
        rpc: any RPCDispatch,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping Sleeper = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.rpc = rpc
        self.now = now
        self.sleep = sleep
    }

    var hasPendingRequest: Bool { requestedAt != nil }

    /// Whether the current state calls for another `relay.info` in ``pollIntervalSeconds``.
    /// An auto-update that is merely staged waits for the phones to leave, so it is not polled.
    var shouldPoll: Bool {
        guard let state = info?.update?.state else { return false }
        switch state {
        case .checking, .downloading, .building, .applying:
            return true
        case .staged:
            return hasPendingRequest
        case .idle, .failed, .disabled, .unavailable, .unknown:
            return false
        }
    }

    /// Calls `relay.info` once. Only call it when the relay advertises `relay.info.v1`.
    func refresh(hostID: String) async {
        if self.hostID != hostID {
            reset()
            self.hostID = hostID
        }
        token &+= 1
        let current = token
        isLoading = true
        defer { if current == token { isLoading = false } }
        do {
            let response = try await rpc.call(method: RemoteRPCMethod.relayInfo.rawValue, params: .object([:]))
            let next = try response.unwrapResult().decode(RelayInfoResult.self)
            guard current == token else { return }
            info = next
            settleRequest(version: next.version, state: next.update?.state)
        } catch {
            // Keep the last known info; a restart in progress looks exactly like this.
        }
    }

    /// Calls `relay.update.start`. Only call it when the relay advertises `relay.update.v1`.
    func startUpdate() async {
        guard !isRequesting, let current = info else { return }
        token &+= 1
        isRequesting = true
        requestFailure = nil
        outcome = nil
        defer { isRequesting = false }
        do {
            let response = try await rpc.call(method: RemoteRPCMethod.relayUpdateStart.rawValue, params: .object([:]))
            let status = try response.unwrapResult().decode(RelayUpdateStatus.self)
            info = RelayInfoResult(version: current.version, update: status)
            requestedFromVersion = current.version
            requestedAt = now()
            requestCount &+= 1
            settleRequest(version: current.version, state: status.state)
        } catch CmuxRemoteRPCError.rpc(let code, _) where code == RemoteErrorCode.updateDisabled.rawValue {
            requestFailure = .disabled
        } catch CmuxRemoteRPCError.rpc(let code, _) where code == RemoteErrorCode.updateUnavailable.rawValue {
            requestFailure = .unavailable
        } catch {
            requestFailure = .failed
        }
    }

    /// Polls `relay.info` every ``pollIntervalSeconds`` while ``shouldPoll`` holds,
    /// for at most ``maxPollSeconds``. Ends when the calling task is cancelled.
    func pollWhileInProgress(hostID: String) async {
        let startedAt = requestedAt ?? now()
        while shouldPoll, !Task.isCancelled {
            if now().timeIntervalSince(startedAt) >= Self.maxPollSeconds {
                outcome = .timedOut
                clearRequest()
                return
            }
            do {
                try await sleep(Self.pollIntervalSeconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await refresh(hostID: hostID)
        }
    }

    func reset() {
        token &+= 1
        hostID = nil
        info = nil
        isLoading = false
        requestFailure = nil
        outcome = nil
        clearRequest()
    }

    private func settleRequest(version: String, state: RelayUpdateState?) {
        guard let from = requestedFromVersion else { return }
        if version != from {
            outcome = .updated(from: from, to: version)
            clearRequest()
            return
        }
        switch state {
        case .idle:
            outcome = .upToDate
            clearRequest()
        case .failed, .disabled, .unavailable, .unknown, nil:
            clearRequest()
        case .checking, .downloading, .building, .staged, .applying:
            break
        }
    }

    private func clearRequest() {
        requestedAt = nil
        requestedFromVersion = nil
    }
}
