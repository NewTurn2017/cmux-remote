import XCTest
import UserNotifications
import SharedKit
@testable import CmuxRemote

@MainActor
final class NotificationBannerLedgerTests: XCTestCase {
    private let fullBanner: UNNotificationPresentationOptions = [.banner, .sound, .badge]

    func testClaimSucceedsOncePerIdAndForgetsTheOldestPastCapacity() {
        let ledger = NotificationBannerLedger(capacity: 2)

        XCTAssertTrue(ledger.claim("a"))
        XCTAssertFalse(ledger.claim("a"))
        XCTAssertTrue(ledger.claim("b"))
        XCTAssertTrue(ledger.claim("c"))
        XCTAssertTrue(ledger.claim("a"))
        XCTAssertFalse(ledger.claim("c"))
    }

    func testForegroundRemotePushShowsOnlyWhenItComesFirst() {
        let ledger = NotificationBannerLedger()

        XCTAssertEqual(ledger.presentationOptions(isRemote: true, notificationId: "N-0001"), fullBanner)
        XCTAssertEqual(ledger.presentationOptions(isRemote: true, notificationId: "N-0001"), [])
        XCTAssertEqual(ledger.presentationOptions(isRemote: false, notificationId: "N-0001"), fullBanner)
        XCTAssertEqual(ledger.presentationOptions(isRemote: true, notificationId: nil), fullBanner)
    }

    func testRemotePushAfterLocalBannerIsSilenced() async {
        let ledger = NotificationBannerLedger()
        let center = BannerRecordingCenter()
        let presenter = LocalNotificationPresenter(notificationCenter: center, ledger: ledger)

        await presenter.presentAsync(Self.record("N-0001"))

        XCTAssertEqual(center.addedIdentifiers, ["cmux.N-0001"])
        XCTAssertEqual(ledger.presentationOptions(isRemote: true, notificationId: "N-0001"), [])
    }

    func testLocalBannerAfterForegroundRemotePushIsSkipped() async {
        let ledger = NotificationBannerLedger()
        let center = BannerRecordingCenter()
        let presenter = LocalNotificationPresenter(notificationCenter: center, ledger: ledger)
        XCTAssertEqual(ledger.presentationOptions(isRemote: true, notificationId: "N-0001"), fullBanner)

        await presenter.presentAsync(Self.record("N-0001"))

        XCTAssertTrue(center.addedIdentifiers.isEmpty)
    }

    func testLocalBannerIsSkippedWhenAPushForTheIdWasAlreadyDelivered() async {
        let center = BannerRecordingCenter()
        center.deliveredIds = ["N-0001"]
        let presenter = LocalNotificationPresenter(notificationCenter: center, ledger: NotificationBannerLedger())

        await presenter.presentAsync(Self.record("N-0001"))
        await presenter.presentAsync(Self.record("N-0002"))

        XCTAssertEqual(center.addedIdentifiers, ["cmux.N-0002"])
    }

    func testLocalBannerCarriesTitleSubtitleAndBodyOncePerId() async {
        let center = BannerRecordingCenter()
        let presenter = LocalNotificationPresenter(notificationCenter: center, ledger: NotificationBannerLedger())

        await presenter.presentAsync(Self.record("N-0001"))
        await presenter.presentAsync(Self.record("N-0001"))

        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(center.added.first?.content.title, "Claude Code")
        XCTAssertEqual(center.added.first?.content.subtitle, "agent-lab")
        XCTAssertEqual(center.added.first?.content.body, "Claude is waiting for your input")
    }

    private static func record(_ id: String) -> NotificationRecord {
        NotificationRecord(
            id: id, workspaceId: "WS-AAAA", surfaceId: "SF-1111", title: "Claude Code",
            subtitle: "agent-lab", body: "Claude is waiting for your input", ts: 42,
            threadId: "workspace-WS-AAAA"
        )
    }
}

@MainActor
private final class BannerRecordingCenter: NotificationCenterFacade {
    var deliveredIds: Set<String> = []
    private(set) var added: [UNNotificationRequest] = []

    var addedIdentifiers: [String] { added.map(\.identifier) }

    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }

    func add(_ request: UNNotificationRequest) async throws {
        added.append(request)
    }

    func deliveredNotificationIds() async -> Set<String> { deliveredIds }
}
