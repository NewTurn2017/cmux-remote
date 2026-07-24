import XCTest
import UserNotifications
@testable import CmuxRemote

@MainActor
final class LocalNotificationPresenterTests: XCTestCase {
    func testConcurrentAuthorizationCallsShareInFlightPromptResult() async {
        let notificationCenter = FakeNotificationCenter()
        let presenter = LocalNotificationPresenter(notificationCenter: notificationCenter)

        async let first = presenter.requestAuthorizationIfNeeded()
        await notificationCenter.waitUntilRequestStarted()

        async let second = presenter.requestAuthorizationIfNeeded()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(notificationCenter.requestCount, 1)
        notificationCenter.grantAuthorization()

        let results = await (first, second)
        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        XCTAssertEqual(notificationCenter.requestCount, 1)
    }
}

@MainActor
private final class FakeNotificationCenter: NotificationCenterFacade {
    var status: UNAuthorizationStatus = .notDetermined
    private(set) var requestCount = 0
    private var requestStartedContinuation: CheckedContinuation<Void, Never>?
    private var authorizationContinuation: CheckedContinuation<Bool, Never>?
    private(set) var addedRequests: [UNNotificationRequest] = []

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestCount += 1
        requestStartedContinuation?.resume()
        requestStartedContinuation = nil
        return await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
    }

    func waitUntilRequestStarted() async {
        if requestCount > 0 { return }
        await withCheckedContinuation { continuation in
            requestStartedContinuation = continuation
        }
    }

    func grantAuthorization() {
        status = .authorized
        authorizationContinuation?.resume(returning: true)
        authorizationContinuation = nil
    }
}
