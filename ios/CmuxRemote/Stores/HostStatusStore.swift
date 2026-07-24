import Foundation
import Observation
import SharedKit

@MainActor
@Observable
public final class HostStatusStore {
    public var battery: HostBatteryState = .unknown

    private let rpc: any RPCDispatch

    public init(rpc: any RPCDispatch) {
        self.rpc = rpc
    }

    public func refreshBattery() async {
        do {
            let response = try await rpc.call(method: "host.battery", params: .object([:]))
            let payload = try response.unwrapResult().decode(HostBatteryPayload.self)
            battery = HostBatteryState(payload: payload)
        } catch {
            battery = .unavailable
        }
    }

    public func reset() {
        battery = .unknown
    }
}

public struct HostBatteryState: Equatable, Sendable {
    public var available: Bool
    public var percent: Int?
    public var state: String?
    public var isCharging: Bool?
    public var powerSource: String?

    public static let unknown = HostBatteryState(
        available: false,
        percent: nil,
        state: nil,
        isCharging: nil,
        powerSource: nil
    )

    public static let unavailable = HostBatteryState(
        available: false,
        percent: nil,
        state: nil,
        isCharging: false,
        powerSource: nil
    )

    public init(
        available: Bool,
        percent: Int?,
        state: String?,
        isCharging: Bool?,
        powerSource: String?
    ) {
        self.available = available
        self.percent = percent
        self.state = state
        self.isCharging = isCharging
        self.powerSource = powerSource
    }

    init(payload: HostBatteryPayload) {
        available = payload.available
        percent = payload.percent.map { max(0, min(100, $0)) }
        state = payload.state
        isCharging = payload.isCharging
        powerSource = payload.powerSource
    }

    public var displayText: String {
        guard available, let percent else {
            if powerSource == "AC Power" { return "AC" }
            return "--"
        }
        let suffix = isCharging == true ? "↯" : "%"
        return isCharging == true ? "\(percent)% \(suffix)" : "\(percent)%"
    }

    public var accessibilityText: String {
        guard available, let percent else { return L10n.string("MacBook battery unavailable") }
        if isCharging == true { return L10n.format("MacBook battery %lld percent, charging", percent) }
        return L10n.format("MacBook battery %lld percent", percent)
    }
}

struct HostBatteryPayload: Decodable {
    let available: Bool
    let percent: Int?
    let state: String?
    let isCharging: Bool?
    let powerSource: String?
}
