import Foundation
import SharedKit
import UserNotifications
import os.log

/// Posts cmux notifications as iOS local notifications so the user gets a
/// banner / lock-screen alert when the app is backgrounded. Authorization
/// is requested lazily on first ingest — we don't want to nag the user at
/// launch before they've seen any value from the feature.
@MainActor
public final class LocalNotificationPresenter {
    private let center: UNUserNotificationCenter
    private var authorizationRequested = false
    private var authorized = false

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Pre-warm authorization so the system dialog appears at app launch
    /// rather than only on the first inbound notification — which may
    /// never arrive if cmux isn't producing events.
    public func requestAuthorizationIfNeeded() async {
        _ = await ensureAuthorized()
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
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorized = true
            return true
        case .denied:
            return false
        case .notDetermined:
            guard !authorizationRequested else { return false }
            authorizationRequested = true
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                authorized = granted
                return granted
            } catch {
                os_log("notification auth request failed: %{public}@", String(describing: error))
                return false
            }
        @unknown default:
            return false
        }
    }
}
