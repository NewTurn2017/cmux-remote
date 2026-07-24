import Foundation
import SharedKit
import UserNotifications
import os.log

@MainActor
protocol NotificationCenterFacade: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
private final class UserNotificationCenterAdapter: NotificationCenterFacade {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }
}

/// Posts cmux notifications as iOS local notifications so the user gets a
/// banner / lock-screen alert when the app is backgrounded.
@MainActor
public final class LocalNotificationPresenter {
    private let center: any NotificationCenterFacade
    private var authorized = false
    private var authorizationRequestInFlight = false
    private var authorizationWaiters: [CheckedContinuation<Bool, Never>] = []

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = UserNotificationCenterAdapter(center: center)
    }

    init(notificationCenter: any NotificationCenterFacade) {
        self.center = notificationCenter
    }

    /// Pre-warm authorization so the system dialog appears at app launch
    /// rather than only on the first inbound notification — which may
    /// never arrive if cmux isn't producing events.
    @discardableResult
    public func requestAuthorizationIfNeeded() async -> Bool {
        await ensureAuthorized()
    }

    public func present(_ record: NotificationRecord) {
        Task { await self.presentAsync(record) }
    }

    private func presentAsync(_ record: NotificationRecord) async {
        guard await ensureAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = record.title
        if let subtitle = record.subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = record.body
        content.sound = .default
        content.threadIdentifier = record.threadId
        content.userInfo = [
            "workspace_id": record.workspaceId,
            "surface_id": record.surfaceId ?? "",
            "notification_id": record.id,
        ]

        let request = UNNotificationRequest(
            identifier: "cmux.\(record.id)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            os_log("local notification post failed: %{public}@", String(describing: error))
        }
    }

    private func ensureAuthorized() async -> Bool {
        if authorized { return true }
        if authorizationRequestInFlight {
            return await waitForAuthorizationRequest()
        }
        switch await center.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            authorized = true
            return true
        case .denied:
            return false
        case .notDetermined:
            if authorizationRequestInFlight {
                return await waitForAuthorizationRequest()
            }
            authorizationRequestInFlight = true
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                completeAuthorizationRequest(with: granted)
                return granted
            } catch {
                os_log("notification auth request failed: %{public}@", String(describing: error))
                completeAuthorizationRequest(with: false)
                return false
            }
        @unknown default:
            return false
        }
    }

    private func waitForAuthorizationRequest() async -> Bool {
        await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
        }
    }

    private func completeAuthorizationRequest(with granted: Bool) {
        authorizationRequestInFlight = false
        authorized = granted
        let waiters = authorizationWaiters
        authorizationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: granted)
        }
    }
}
