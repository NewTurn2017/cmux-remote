import Foundation
import SharedKit
import UIKit
@testable import CmuxRemote

/// Sleeper that records each requested delay and returns only when the test fires it.
actor FakeBrowserRefreshSleeper: BrowserRefreshSleeper {
    private(set) var requested: [Double] = []
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var order: [Int] = []
    private var nextID = 0
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var pendingCount: Int { pending.count }

    func sleep(seconds: Double) async throws {
        requested.append(seconds)
        let id = nextID
        nextID += 1
        let reached = requested.count
        let ready = requestWaiters.filter { $0.count <= reached }
        requestWaiters.removeAll { $0.count <= reached }
        for waiter in ready { waiter.continuation.resume() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                order.append(id)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Returns once at least `count` sleeps have been requested.
    func waitForRequests(_ count: Int) async {
        if requested.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    /// Ends the oldest pending sleep normally.
    func fireNext() {
        guard !order.isEmpty else { return }
        pending.removeValue(forKey: order.removeFirst())?.resume()
    }

    private func cancel(_ id: Int) {
        order.removeAll { $0 == id }
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

/// Real ImageIO decoder that also records whether each decode ran on the main thread.
final class RecordingBrowserCaptureDecoder: BrowserCaptureDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [Bool] = []

    var decodedOnMainThread: [Bool] { lock.withLock { threads } }

    func decode(_ result: SurfaceBrowserCaptureResult) throws -> UIImage {
        lock.withLock { threads.append(Thread.isMainThread) }
        return try ImageIOBrowserCaptureDecoder().decode(result)
    }
}

enum BrowserFixtures {
    static let fixedNow = Date(timeIntervalSince1970: 1_000)

    static func jpeg(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor(white: 0.5, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.7) ?? Data()
    }

    static func captureResponse(
        width: Int = 40,
        height: Int = 60,
        url: String? = "https://example.com/",
        title: String? = "Example Domain",
        capturedAt: Int64 = 1
    ) throws -> RPCResponse {
        let result = SurfaceBrowserCaptureResult(
            imageBase64: jpeg(width: width, height: height).base64EncodedString(),
            mimeType: "image/jpeg",
            width: width,
            height: height,
            sourceWidth: width * 2,
            sourceHeight: height * 2,
            url: url,
            title: title,
            capturedAt: capturedAt
        )
        let data = try SharedKitJSON.snakeCaseEncoder.encode(result)
        return RPCResponse(id: "capture", ok: true, result: try JSONDecoder().decode(JSONValue.self, from: data))
    }

    static func error(_ code: String) -> RPCResponse {
        DocumentFixtures.error(code)
    }
}
