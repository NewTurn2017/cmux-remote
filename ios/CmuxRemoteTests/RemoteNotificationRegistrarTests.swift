import Foundation
import XCTest
import UserNotifications
@testable import CmuxRemote

@MainActor
final class RemoteNotificationRegistrarTests: XCTestCase {
    func testDeviceTokenDataConvertsToLowercaseHex() {
        let data = Data([0x00, 0x0f, 0x10, 0xab, 0xff])

        XCTAssertEqual(RemoteNotificationRegistrar.tokenHex(from: data), "000f10abff")
    }

    func testRegisterForRemoteNotificationsContinuesWhenSettingsAreStillNotDetermined() async {
        let center = FakeRemoteNotificationAuthorizationCenter(status: .notDetermined)
        let application = FakeRemoteNotificationApplication()
        let registrar = RemoteNotificationRegistrar(notificationCenter: center, application: application)

        await registrar.registerForRemoteNotifications()

        XCTAssertEqual(application.registerCallCount, 1)
    }

    func testRegisterForRemoteNotificationsSkipsDeniedAuthorization() async {
        let center = FakeRemoteNotificationAuthorizationCenter(status: .denied)
        let application = FakeRemoteNotificationApplication()
        let registrar = RemoteNotificationRegistrar(notificationCenter: center, application: application)

        await registrar.registerForRemoteNotifications()

        XCTAssertEqual(application.registerCallCount, 0)
    }
}

@MainActor
private final class FakeRemoteNotificationAuthorizationCenter: RemoteNotificationAuthorizationCenter {
    var delegate: UNUserNotificationCenterDelegate?
    var status: UNAuthorizationStatus

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }
}

@MainActor
private final class FakeRemoteNotificationApplication: RemoteNotificationApplication {
    private(set) var registerCallCount = 0

    func registerForRemoteNotifications() {
        registerCallCount += 1
    }
}
