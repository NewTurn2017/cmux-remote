import Foundation
import UIKit
import UserNotifications
import os.log

public extension Notification.Name {
    static let cmuxRemoteNotificationResponse = Notification.Name("cmuxRemoteNotificationResponse")
}

@MainActor
protocol RemoteNotificationAuthorizationCenter: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func authorizationStatus() async -> UNAuthorizationStatus
}

@MainActor
protocol RemoteNotificationApplication: AnyObject {
    func registerForRemoteNotifications()
}

@MainActor
private final class RemoteNotificationCenterAdapter: RemoteNotificationAuthorizationCenter {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    var delegate: UNUserNotificationCenterDelegate? {
        get { center.delegate }
        set { center.delegate = newValue }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus
    }
}

@MainActor
private final class RemoteNotificationApplicationAdapter: RemoteNotificationApplication {
    private let application: UIApplication

    init(application: UIApplication) {
        self.application = application
    }

    func registerForRemoteNotifications() {
        application.registerForRemoteNotifications()
    }
}

@MainActor
public final class RemoteNotificationRegistrar: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let notificationCenter: any RemoteNotificationAuthorizationCenter
    private let application: any RemoteNotificationApplication
    private var authClient: AuthClient?
    private var pendingDeviceToken: Data?
    private var forwarding = false

    public override init() {
        self.notificationCenter = RemoteNotificationCenterAdapter(center: .current())
        self.application = RemoteNotificationApplicationAdapter(application: .shared)
        super.init()
    }

    init(
        notificationCenter: any RemoteNotificationAuthorizationCenter,
        application: any RemoteNotificationApplication
    ) {
        self.notificationCenter = notificationCenter
        self.application = application
        super.init()
    }

    public nonisolated static func tokenHex(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static var defaultEnvironment: APNsRegistrationEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .prod
        #endif
    }

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        notificationCenter.delegate = self
        return true
    }

    public func configure(authClient: AuthClient) {
        self.authClient = authClient
        if pendingDeviceToken != nil {
            Task { @MainActor in await forwardPendingTokenIfPossible() }
        }
    }

    public func registerForRemoteNotifications() async {
        switch await notificationCenter.authorizationStatus() {
        case .denied:
            return
        case .authorized, .provisional, .ephemeral, .notDetermined:
            application.registerForRemoteNotifications()
        @unknown default:
            return
        }
    }

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        pendingDeviceToken = deviceToken
        Task { @MainActor in await forwardPendingTokenIfPossible() }
    }

    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        os_log("remote notification registration failed: %{public}@", String(describing: error))
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        NotificationCenter.default.post(
            name: .cmuxRemoteNotificationResponse,
            object: nil,
            userInfo: response.notification.request.content.userInfo
        )
    }

    private func forwardPendingTokenIfPossible() async {
        guard !forwarding, let authClient, let token = pendingDeviceToken else { return }
        forwarding = true
        defer { forwarding = false }
        do {
            try await authClient.registerAPNsTokenHex(
                Self.tokenHex(from: token),
                environment: Self.defaultEnvironment
            )
            pendingDeviceToken = nil
        } catch {
            os_log("remote notification token forwarding failed: %{public}@", String(describing: error))
        }
    }
}
