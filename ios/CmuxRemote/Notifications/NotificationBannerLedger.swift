import Foundation
import UserNotifications

/// Remembers which cmux notification ids already raised a banner, so the relay's local
/// banner and the APNs push for the same notification never both show.
@MainActor
public final class NotificationBannerLedger {
    public nonisolated static let shared = NotificationBannerLedger()

    private let capacity: Int
    private var claimed: Set<String> = []
    private var order: [String] = []

    public nonisolated init(capacity: Int = 512) {
        self.capacity = capacity
    }

    public func claim(_ id: String) -> Bool {
        guard claimed.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity {
            claimed.remove(order.removeFirst())
        }
        return true
    }

    /// Foreground presentation: local banners always show (the presenter already claimed
    /// them); a remote push shows only when no banner for its notification id came first.
    public func presentationOptions(isRemote: Bool, notificationId: String?) -> UNNotificationPresentationOptions {
        guard isRemote, let notificationId, !notificationId.isEmpty else { return [.banner, .sound, .badge] }
        return claim(notificationId) ? [.banner, .sound, .badge] : []
    }
}
