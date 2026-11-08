import Foundation
import SharedKit
import Testing
@testable import CmuxRemote

@Suite("BrowserCaptureFailureTests")
struct BrowserCaptureFailureTests {
    @Test(arguments: [
        ("surface_not_browser", BrowserCaptureFailure.notBrowser),
        ("temporarily_unavailable", .temporarilyUnavailable),
        ("size_limit_exceeded", .tooLarge),
        ("offline", .disconnected),
        ("not_found", .generic),
        ("rate_limited", .generic),
    ])
    func testErrorCodeMapping(code: String, expected: BrowserCaptureFailure) {
        #expect(BrowserCaptureFailure(error: CmuxRemoteRPCError.rpc(code: code, message: code)) == expected)
    }

    @Test
    func testTransportAndDecodeErrorsMapToStates() {
        #expect(BrowserCaptureFailure(error: RPCClientError.closed) == .disconnected)
        #expect(BrowserCaptureFailure(error: RPCClientError.timeout) == .temporarilyUnavailable)
        #expect(BrowserCaptureFailure(error: RemoteProtocolError.invalidField("width")) == .invalidImage)
        #expect(BrowserCaptureFailure(error: RemoteProtocolError.invalidBase64) == .invalidImage)
        #expect(BrowserCaptureFailure(error: RemoteProtocolError.chunkTooLarge(maxBytes: 737_280)) == .tooLarge)
        #expect(BrowserCaptureFailure(error: BrowserCaptureDecodeError.undecodableImage) == .invalidImage)
        #expect(BrowserCaptureFailure(error: CancellationError()) == .generic)
    }

    @Test
    func testOnlyNotBrowserIsPersistent() {
        let all: [BrowserCaptureFailure] = [.notBrowser, .temporarilyUnavailable, .disconnected, .tooLarge, .invalidImage, .generic]
        #expect(all.filter(\.isPersistent) == [.notBrowser])
        #expect(Set(all.map(\.accessibilityIdentifier)).count == all.count)
    }

    @Test
    func testBackoffSequence() {
        #expect((0...6).map { BrowserRefreshPolicy.delaySeconds(consecutiveFailures: $0, baseSeconds: 2) } == [2, 4, 8, 16, 30, 30, 30])
        #expect(BrowserRefreshPolicy.delaySeconds(consecutiveFailures: 0) == Double(SurfaceBrowserCaptureLimits.recommendedRefreshSeconds))
        #expect(BrowserRefreshPolicy.delaySeconds(consecutiveFailures: 3, baseSeconds: 600) == 600)
    }
}
