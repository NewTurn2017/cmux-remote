import CoreGraphics
import Darwin
import Foundation
import ImageIO
import SharedKit
import UniformTypeIdentifiers
@testable import RelayServer

enum BrowserCaptureTestImages {
    static func png(width: Int, height: Int, noise: Bool = false) -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if noise {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let value = state >> 24
                    pixels[index] = UInt8(truncatingIfNeeded: value)
                    pixels[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
                    pixels[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
                } else {
                    pixels[index] = UInt8(x * 255 / max(1, width - 1))
                    pixels[index + 1] = UInt8(y * 255 / max(1, height - 1))
                    pixels[index + 2] = 128
                }
            }
        }
        let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        let output = NSMutableData()
        guard let image,
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return output as Data
    }

    static func isJPEG(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8, 0xFF])
    }
}

/// A temporary directory under the real `NSTemporaryDirectory()` (a `/var` path that resolves
/// to `/private/var`) holding a `cmux-browser-screenshots` folder, removed when released.
final class BrowserScreenshotDirectory {
    let root: String
    let screenshots: String

    init() throws {
        root = NSTemporaryDirectory() + "cmux-relay-browser-\(UUID().uuidString)"
        screenshots = root + "/" + BrowserScreenshotCleanup.directoryName
        try FileManager.default.createDirectory(atPath: screenshots, withIntermediateDirectories: true)
    }

    deinit {
        chmod(screenshots, 0o755)
        try? FileManager.default.removeItem(atPath: root)
    }

    var cleanup: BrowserScreenshotCleanup { BrowserScreenshotCleanup(temporaryDirectory: root) }

    var resolvedRoot: String {
        guard let resolved = realpath(root, nil) else { return root }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @discardableResult
    func makeFile(_ path: String) throws -> String {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: path, contents: Data("png".utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return path
    }

    func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

/// Scripted cmux browser methods. `browser.screenshot` can be held on a gate so tests can
/// observe in-flight sharing without timing assumptions.
actor FakeBrowserCMUX {
    struct Call: Equatable, Sendable {
        let method: String
        let params: JSONValue
    }

    static let pageURL = "https://example.com/private-page"
    static let pageTitle = "Example Private Title"

    private(set) var calls: [Call] = []
    private var screenshots: [String: TerminalArtifactService.NativeResult]
    private var url: TerminalArtifactService.NativeResult
    private var title: TerminalArtifactService.NativeResult
    private let gate: AsyncStream<Void>?
    private let entered: AsyncStream<Void>.Continuation?

    init(
        screenshots: [String: TerminalArtifactService.NativeResult],
        url: TerminalArtifactService.NativeResult = .success(.object(["url": .string(FakeBrowserCMUX.pageURL)])),
        title: TerminalArtifactService.NativeResult = .success(.object(["title": .string(FakeBrowserCMUX.pageTitle)])),
        gate: AsyncStream<Void>? = nil,
        entered: AsyncStream<Void>.Continuation? = nil
    ) {
        self.screenshots = screenshots
        self.url = url
        self.title = title
        self.gate = gate
        self.entered = entered
    }

    nonisolated var dispatch: BrowserCaptureService.Dispatch {
        { [self] method, params in await self.handle(method, params) }
    }

    func methods() -> [String] { calls.map(\.method) }

    func count(of method: String) -> Int { calls.filter { $0.method == method }.count }

    private func handle(_ method: String, _ params: JSONValue) async -> TerminalArtifactService.NativeResult {
        calls.append(Call(method: method, params: params))
        switch method {
        case "browser.screenshot":
            entered?.yield()
            if let gate {
                for await _ in gate { break }
            }
            guard case .object(let fields) = params, case .string(let surface)? = fields["surface_id"] else {
                return .failure(code: "invalid_params")
            }
            return screenshots[surface] ?? .failure(code: "not_found")
        case "browser.url.get":
            return url
        case "browser.get.title":
            return title
        default:
            return .failure(code: "method_not_found")
        }
    }

    static func screenshot(png: Data, path: String?) -> TerminalArtifactService.NativeResult {
        var fields: [String: JSONValue] = [
            "png_base64": .string(png.base64EncodedString()),
            "url": .string("file:///private/var/folders/x/T/cmux-browser-screenshots/surface-x.png"),
            "surface_id": .string("S"),
            "workspace_id": .string("W"),
        ]
        if let path { fields["path"] = .string(path) }
        return .success(.object(fields))
    }
}

final class BrowserTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

final class BrowserLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var lines: [String] { lock.withLock { recorded } }

    func record(_ line: String) { lock.withLock { recorded.append(line) } }
}

enum BrowserTestWaitError: Error { case timedOut }

/// Awaits the next element of `stream`, failing after `timeout` instead of hanging.
func nextEvent<Element: Sendable>(
    _ stream: AsyncStream<Element>,
    timeout: Duration = .seconds(10)
) async throws -> Element {
    try await withThrowingTaskGroup(of: Element?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let element = first else {
            throw BrowserTestWaitError.timedOut
        }
        return element
    }
}
