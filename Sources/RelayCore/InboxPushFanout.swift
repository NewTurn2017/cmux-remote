import Foundation
import SharedKit

public final class InboxPushFanout: @unchecked Sendable {
    private let deviceStore: DeviceStore
    private let sender: any APNsSending
    private let config: @Sendable () -> RelayConfig.APNs

    public init(
        deviceStore: DeviceStore,
        sender: any APNsSending,
        config: @escaping @Sendable () -> RelayConfig.APNs
    ) {
        self.deviceStore = deviceStore
        self.sender = sender
        self.config = config
    }

    public func deliver(event: EventFrame) async {
        guard let notification = InboxNotification.record(from: event) else { return }
        let currentConfig = config()
        guard currentConfig.env == "sandbox" || currentConfig.env == "prod" else { return }

        for device in deviceStore.allDevices() {
            guard let token = device.apnsToken, !token.isEmpty,
                  let env = device.apnsEnv, env == currentConfig.env else { continue }
            do {
                let result = try await sender.send(APNsPushAlert(
                    deviceToken: token,
                    environment: env,
                    notification: notification
                ))
                if case .invalidToken = result {
                    try? deviceStore.clearAPNsToken(deviceId: device.deviceId)
                }
            } catch {
                continue
            }
        }
    }
}
