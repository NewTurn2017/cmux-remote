import Foundation

public struct TestNotificationResult: Sendable {
    public let localBannerRequested: Bool
    public let roundTrip: Task<Void, Error>?
}
