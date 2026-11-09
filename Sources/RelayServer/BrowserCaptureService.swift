import Foundation
import Logging
import SharedKit

/// Serves `surface.browser.capture` from cmux `browser.screenshot`.
///
/// One instance is shared by every WebSocket connection, so requests for the same
/// surface share one in-flight capture and reuse a successful result for ``reuseWindow``.
/// Errors are never reused. Log lines carry only fixed reason words, never a URL, title,
/// or path.
actor BrowserCaptureService {
    typealias Dispatch = @Sendable (String, JSONValue) async -> TerminalArtifactService.NativeResult

    enum Error: Swift.Error, Sendable, Equatable {
        case surfaceNotBrowser
        case sizeLimitExceeded
        case unsupportedImage
        case native(String)
    }

    enum Observation: Sendable, Equatable {
        case joinedInFlight
    }

    private struct Key: Hashable {
        let workspaceID: String
        let surfaceID: String
    }

    static let reuseWindow: TimeInterval = 1.0
    static let logger = Logger(label: "cmux-relay.browser")
    private static let notBrowserCodes: Set<String> = ["invalid_params", "not_found", "surface_not_found"]

    private let dispatch: Dispatch
    private let cleanup: BrowserScreenshotCleanup
    private let clock: @Sendable () -> Date
    private let maxImageBytes: Int
    private let log: @Sendable (String) -> Void
    private let observe: @Sendable (Observation) -> Void
    private var inFlight: [Key: Task<SurfaceBrowserCaptureResult, Swift.Error>] = [:]
    private var recent: [Key: (result: SurfaceBrowserCaptureResult, at: Date)] = [:]

    init(
        dispatch: @escaping Dispatch,
        cleanup: BrowserScreenshotCleanup = BrowserScreenshotCleanup(),
        clock: @escaping @Sendable () -> Date = { Date() },
        maxImageBytes: Int = SurfaceBrowserCaptureLimits.maxImageBytes,
        log: @escaping @Sendable (String) -> Void = { BrowserCaptureService.logger.notice("\($0)") },
        observe: @escaping @Sendable (Observation) -> Void = { _ in }
    ) {
        self.dispatch = dispatch
        self.cleanup = cleanup
        self.clock = clock
        self.maxImageBytes = maxImageBytes
        self.log = log
        self.observe = observe
    }

    var recentEntryCount: Int { recent.count }

    init(cmux: any CMUXFacade) {
        self.init(dispatch: { method, params in
            do {
                return .success(try await cmux.dispatch(method: method, params: params))
            } catch let error as RPCError {
                return .failure(code: error.code)
            } catch {
                return .failure(code: "internal_error")
            }
        })
    }

    func capture(workspaceID: String, surfaceID: String) async throws -> SurfaceBrowserCaptureResult {
        let key = Key(workspaceID: workspaceID, surfaceID: surfaceID)
        let now = clock()
        recent = recent.filter { _, entry in
            let age = now.timeIntervalSince(entry.at)
            return age >= 0 && age < Self.reuseWindow
        }
        if let reusable = recent[key] { return reusable.result }
        if let running = inFlight[key] {
            observe(.joinedInFlight)
            return try await running.value
        }

        let dispatch = self.dispatch
        let cleanup = self.cleanup
        let clock = self.clock
        let maxImageBytes = self.maxImageBytes
        let log = self.log
        let task = Task {
            try await Self.performCapture(
                key: key, dispatch: dispatch, cleanup: cleanup, clock: clock,
                maxImageBytes: maxImageBytes, log: log
            )
        }
        inFlight[key] = task
        do {
            let result = try await task.value
            inFlight[key] = nil
            recent[key] = (result, clock())
            return result
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    private static func performCapture(
        key: Key,
        dispatch: Dispatch,
        cleanup: BrowserScreenshotCleanup,
        clock: @Sendable () -> Date,
        maxImageBytes: Int,
        log: @Sendable (String) -> Void
    ) async throws -> SurfaceBrowserCaptureResult {
        let params = JSONValue.object([
            "workspace_id": .string(key.workspaceID),
            "surface_id": .string(key.surfaceID),
        ])
        let fields: [String: JSONValue]
        switch await dispatch("browser.screenshot", params) {
        case .success(.object(let object)):
            fields = object
        case .success:
            log("surface.browser.capture screenshot malformed")
            throw Error.unsupportedImage
        case .failure(let code):
            throw mapScreenshotFailure(code)
        }

        let path: String?
        if case .string(let reported)? = fields["path"] { path = reported } else { path = nil }
        defer {
            if let path {
                logCleanup(cleanup.remove(path: path), log: log)
            } else {
                log("surface.browser.capture cleanup skipped: path_missing")
            }
        }
        return try await finish(fields: fields, params: params, dispatch: dispatch,
                                clock: clock, maxImageBytes: maxImageBytes, log: log)
    }

    private static func finish(
        fields: [String: JSONValue],
        params: JSONValue,
        dispatch: Dispatch,
        clock: @Sendable () -> Date,
        maxImageBytes: Int,
        log: @Sendable (String) -> Void
    ) async throws -> SurfaceBrowserCaptureResult {
        guard case .string(let pngBase64)? = fields["png_base64"],
              let png = Data(base64Encoded: pngBase64) else {
            log("surface.browser.capture screenshot malformed")
            throw Error.unsupportedImage
        }
        async let url = pageString(method: "browser.url.get", field: "url", params: params, dispatch: dispatch)
        async let title = pageString(method: "browser.get.title", field: "title", params: params, dispatch: dispatch)
        let encoded = await BoundedRelayWork.offCooperativePool {
            Result { try BrowserCaptureImageEncoder.encode(png: png, maxImageBytes: maxImageBytes) }
        }
        let (pageURL, pageTitle) = await (url, title)
        let image: BrowserCaptureImageEncoder.Encoded
        do {
            image = try encoded.get()
        } catch BrowserCaptureImageEncoder.Failure.sizeLimitExceeded {
            log("surface.browser.capture refused: size_limit_exceeded")
            throw Error.sizeLimitExceeded
        } catch {
            log("surface.browser.capture refused: unsupported_image")
            throw Error.unsupportedImage
        }
        return SurfaceBrowserCaptureResult(
            imageBase64: image.jpeg.base64EncodedString(),
            mimeType: "image/jpeg",
            width: image.width,
            height: image.height,
            sourceWidth: image.sourceWidth,
            sourceHeight: image.sourceHeight,
            url: pageURL,
            title: pageTitle,
            capturedAt: Int64((clock().timeIntervalSince1970 * 1_000).rounded(.down))
        )
    }

    private static func pageString(
        method: String,
        field: String,
        params: JSONValue,
        dispatch: Dispatch
    ) async -> String? {
        guard case .success(.object(let fields)) = await dispatch(method, params),
              case .string(let value)? = fields[field],
              !value.isEmpty else { return nil }
        return value
    }

    private static func mapScreenshotFailure(_ code: String) -> Error {
        if notBrowserCodes.contains(code) { return .surfaceNotBrowser }
        switch code {
        case "unauthorized", "forbidden": return .native("forbidden")
        default: return .native(code)
        }
    }

    private static func logCleanup(_ outcome: BrowserScreenshotCleanup.Outcome, log: @Sendable (String) -> Void) {
        switch outcome {
        case .deleted:
            return
        case .missing:
            log("surface.browser.capture cleanup skipped: missing")
        case .refused(let refusal):
            log("surface.browser.capture cleanup refused: \(refusal.rawValue)")
        case .unlinkFailed(let code):
            log("surface.browser.capture cleanup failed: errno=\(code)")
        }
    }
}
