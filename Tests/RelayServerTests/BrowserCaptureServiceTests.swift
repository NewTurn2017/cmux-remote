import Foundation
import SharedKit
import Testing
@testable import RelayServer

@Suite("BrowserCaptureServiceTests")
struct BrowserCaptureServiceTests {
    private static let start = Date(timeIntervalSince1970: 1_794_240_000.5)
    private static let ids = JSONValue.object(["workspace_id": .string("W"), "surface_id": .string("S")])

    @Test func captureReturnsTheDownscaledJPEGWithPageMetadataAndDeletesTheTempFile() async throws {
        let directory = try BrowserScreenshotDirectory()
        let path = try directory.makeFile(directory.screenshots + "/surface-67DA7B9E-capture.png")
        let png = BrowserCaptureTestImages.png(width: 2400, height: 1800)
        let cmux = FakeBrowserCMUX(screenshots: ["S": FakeBrowserCMUX.screenshot(png: png, path: path)])
        let service = BrowserCaptureService(
            dispatch: cmux.dispatch, cleanup: directory.cleanup, clock: { Self.start }
        )

        let result = try await service.capture(workspaceID: "W", surfaceID: "S")

        #expect(result.mimeType == "image/jpeg")
        #expect(result.width == 1600)
        #expect(result.height == 1200)
        #expect(result.sourceWidth == 2400)
        #expect(result.sourceHeight == 1800)
        #expect(result.url == FakeBrowserCMUX.pageURL)
        #expect(result.title == FakeBrowserCMUX.pageTitle)
        #expect(result.capturedAt == 1_794_240_000_500)
        #expect(BrowserCaptureTestImages.isJPEG(try result.decodedImage()))
        let wire = try SharedKitJSON.snakeCaseEncoder.encode(result)
        #expect(try SharedKitJSON.snakeCaseDecoder.decode(SurfaceBrowserCaptureResult.self, from: wire) == result)
        #expect(!directory.exists(path))

        let calls = await cmux.calls
        #expect(calls.first?.method == "browser.screenshot")
        #expect(Set(calls.dropFirst().map(\.method)) == ["browser.url.get", "browser.get.title"])
        #expect(calls.count == 3)
        #expect(calls.allSatisfy { $0.params == Self.ids })
    }

    @Test(arguments: ["invalid_params", "not_found", "surface_not_found"])
    func nonBrowserFailuresMapToSurfaceNotBrowser(code: String) async throws {
        let cmux = FakeBrowserCMUX(screenshots: ["S": .failure(code: code)])
        let service = BrowserCaptureService(dispatch: cmux.dispatch, clock: { Self.start })

        await #expect(throws: BrowserCaptureService.Error.surfaceNotBrowser) {
            try await service.capture(workspaceID: "W", surfaceID: "S")
        }
        #expect(await cmux.methods() == ["browser.screenshot"])
    }

    @Test func otherCmuxFailuresKeepTheirCodeAndUnauthorizedBecomesForbidden() async throws {
        let cmux = FakeBrowserCMUX(screenshots: [
            "limited": .failure(code: "rate_limited"),
            "denied": .failure(code: "unauthorized"),
        ])
        let service = BrowserCaptureService(dispatch: cmux.dispatch, clock: { Self.start })

        await #expect(throws: BrowserCaptureService.Error.native("rate_limited")) {
            try await service.capture(workspaceID: "W", surfaceID: "limited")
        }
        await #expect(throws: BrowserCaptureService.Error.native("forbidden")) {
            try await service.capture(workspaceID: "W", surfaceID: "denied")
        }
    }

    @Test func missingURLAndEmptyTitleAreOmittedWhileTheCaptureSucceeds() async throws {
        let cmux = FakeBrowserCMUX(
            screenshots: ["S": FakeBrowserCMUX.screenshot(png: BrowserCaptureTestImages.png(width: 640, height: 480), path: nil)],
            url: .failure(code: "timeout"),
            title: .success(.object(["title": .string("")]))
        )
        let service = BrowserCaptureService(dispatch: cmux.dispatch, clock: { Self.start })

        let result = try await service.capture(workspaceID: "W", surfaceID: "S")

        #expect(result.url == nil)
        #expect(result.title == nil)
        #expect(result.width == 640)
        let keys = try JSONSerialization.jsonObject(with: SharedKitJSON.snakeCaseEncoder.encode(result)) as? [String: Any]
        #expect(keys?["url"] == nil)
        #expect(keys?["title"] == nil)
    }

    @Test func malformedScreenshotIsUnsupportedAndItsFileIsStillDeleted() async throws {
        let directory = try BrowserScreenshotDirectory()
        let path = try directory.makeFile(directory.screenshots + "/surface-67DA7B9E-bad.png")
        let cmux = FakeBrowserCMUX(screenshots: ["S": .success(.object([
            "png_base64": .string(Data("not a png".utf8).base64EncodedString()),
            "path": .string(path),
        ]))])
        let service = BrowserCaptureService(dispatch: cmux.dispatch, cleanup: directory.cleanup, clock: { Self.start })

        await #expect(throws: BrowserCaptureService.Error.unsupportedImage) {
            try await service.capture(workspaceID: "W", surfaceID: "S")
        }
        #expect(!directory.exists(path))
    }

    @Test func oversizedCaptureIsRefusedWithSizeLimitExceeded() async throws {
        let cmux = FakeBrowserCMUX(screenshots: [
            "S": FakeBrowserCMUX.screenshot(png: BrowserCaptureTestImages.png(width: 640, height: 480), path: nil),
        ])
        let service = BrowserCaptureService(dispatch: cmux.dispatch, clock: { Self.start }, maxImageBytes: 10)

        await #expect(throws: BrowserCaptureService.Error.sizeLimitExceeded) {
            try await service.capture(workspaceID: "W", surfaceID: "S")
        }
    }

    @Test func logLinesNeverCarryTheURLTitleOrPath() async throws {
        let directory = try BrowserScreenshotDirectory()
        let outside = try directory.makeFile(directory.root + "/elsewhere/surface-67DA7B9E-out.png")
        let png = BrowserCaptureTestImages.png(width: 320, height: 240)
        let cmux = FakeBrowserCMUX(screenshots: [
            "outside": FakeBrowserCMUX.screenshot(png: png, path: outside),
            "nopath": FakeBrowserCMUX.screenshot(png: png, path: nil),
            "bad": .success(.object(["path": .string(outside)])),
            "missing": FakeBrowserCMUX.screenshot(png: png, path: directory.screenshots + "/surface-gone.png"),
        ])
        let recorder = BrowserLogRecorder()
        let service = BrowserCaptureService(
            dispatch: cmux.dispatch, cleanup: directory.cleanup, clock: { Self.start },
            log: { recorder.record($0) }
        )

        _ = try await service.capture(workspaceID: "W", surfaceID: "outside")
        _ = try await service.capture(workspaceID: "W", surfaceID: "nopath")
        _ = try await service.capture(workspaceID: "W", surfaceID: "missing")
        await #expect(throws: BrowserCaptureService.Error.unsupportedImage) {
            try await service.capture(workspaceID: "W", surfaceID: "bad")
        }

        let lines = recorder.lines
        #expect(lines.contains("surface.browser.capture cleanup refused: outside_directory"))
        #expect(lines.contains("surface.browser.capture cleanup skipped: path_missing"))
        #expect(lines.contains("surface.browser.capture cleanup skipped: missing"))
        #expect(lines.contains("surface.browser.capture screenshot malformed"))
        for line in lines {
            #expect(!line.contains("/"))
            #expect(!line.contains(FakeBrowserCMUX.pageURL))
            #expect(!line.contains(FakeBrowserCMUX.pageTitle))
            #expect(!line.contains("surface-67DA7B9E"))
        }
        #expect(directory.exists(outside))
    }

    @Test func concurrentRequestsForOneSurfaceShareOneScreenshot() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let entered = AsyncStream<Void>.makeStream()
        let joined = AsyncStream<BrowserCaptureService.Observation>.makeStream()
        defer { gate.continuation.finish() }
        let cmux = FakeBrowserCMUX(
            screenshots: ["S": FakeBrowserCMUX.screenshot(png: BrowserCaptureTestImages.png(width: 320, height: 240), path: nil)],
            gate: gate.stream,
            entered: entered.continuation
        )
        let service = BrowserCaptureService(
            dispatch: cmux.dispatch, clock: { Self.start },
            observe: { joined.continuation.yield($0) }
        )

        let first = Task { try await service.capture(workspaceID: "W", surfaceID: "S") }
        _ = try await nextEvent(entered.stream)
        let second = Task { try await service.capture(workspaceID: "W", surfaceID: "S") }
        #expect(try await nextEvent(joined.stream) == .joinedInFlight)
        gate.continuation.yield()

        let results = try await (first.value, second.value)
        #expect(results.0 == results.1)
        #expect(await cmux.count(of: "browser.screenshot") == 1)
    }

    @Test func differentSurfacesAreCapturedSeparately() async throws {
        let png = BrowserCaptureTestImages.png(width: 320, height: 240)
        let cmux = FakeBrowserCMUX(screenshots: [
            "A": FakeBrowserCMUX.screenshot(png: png, path: nil),
            "B": FakeBrowserCMUX.screenshot(png: png, path: nil),
        ])
        let service = BrowserCaptureService(dispatch: cmux.dispatch, clock: { Self.start })

        _ = try await service.capture(workspaceID: "W", surfaceID: "A")
        _ = try await service.capture(workspaceID: "W", surfaceID: "B")

        #expect(await cmux.count(of: "browser.screenshot") == 2)
    }

    @Test func successfulResultIsReusedForOneSecondOnly() async throws {
        let clock = BrowserTestClock(Self.start)
        let cmux = FakeBrowserCMUX(screenshots: [
            "S": FakeBrowserCMUX.screenshot(png: BrowserCaptureTestImages.png(width: 320, height: 240), path: nil),
        ])
        let service = BrowserCaptureService(dispatch: cmux.dispatch, clock: { clock.now })

        let first = try await service.capture(workspaceID: "W", surfaceID: "S")
        clock.advance(by: 0.75)
        let reused = try await service.capture(workspaceID: "W", surfaceID: "S")
        #expect(reused == first)
        #expect(await cmux.count(of: "browser.screenshot") == 1)

        clock.advance(by: 0.25)
        let fresh = try await service.capture(workspaceID: "W", surfaceID: "S")
        #expect(fresh.capturedAt == first.capturedAt + 1_000)
        #expect(await cmux.count(of: "browser.screenshot") == 2)
    }

    @Test func expiredResultsForOtherSurfacesAreDroppedOnTheNextCapture() async throws {
        let clock = BrowserTestClock(Self.start)
        let png = BrowserCaptureTestImages.png(width: 320, height: 240)
        let cmux = FakeBrowserCMUX(screenshots: [
            "A": FakeBrowserCMUX.screenshot(png: png, path: nil),
            "B": FakeBrowserCMUX.screenshot(png: png, path: nil),
            "C": FakeBrowserCMUX.screenshot(png: png, path: nil),
        ])
        let service = BrowserCaptureService(dispatch: cmux.dispatch, clock: { clock.now })

        _ = try await service.capture(workspaceID: "W", surfaceID: "A")
        _ = try await service.capture(workspaceID: "W", surfaceID: "B")
        #expect(await service.recentEntryCount == 2)

        clock.advance(by: 1.25)
        _ = try await service.capture(workspaceID: "W", surfaceID: "C")

        #expect(await service.recentEntryCount == 1)
        #expect(await cmux.count(of: "browser.screenshot") == 3)
    }

    @Test func failuresAreNeverReused() async throws {
        let cmux = FakeBrowserCMUX(screenshots: ["S": .failure(code: "rate_limited")])
        let service = BrowserCaptureService(dispatch: cmux.dispatch, clock: { Self.start })

        for _ in 0..<2 {
            await #expect(throws: BrowserCaptureService.Error.native("rate_limited")) {
                try await service.capture(workspaceID: "W", surfaceID: "S")
            }
        }
        #expect(await cmux.count(of: "browser.screenshot") == 2)
    }
}
