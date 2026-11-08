import Foundation
import UIKit

/// One decoded browser capture. Only the latest capture is kept in memory.
struct BrowserCapture: Equatable {
    let image: UIImage
    let url: String?
    let title: String?
    let capturedAt: Int64
    /// Device time when the capture arrived; "n seconds ago" uses this to avoid Mac/phone clock skew.
    let receivedAt: Date

    var pixelSize: CGSize { CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale) }

    /// The capture's page title, or the surface title from the workspace list when cmux sent none.
    func displayTitle(fallback: String) -> String {
        guard let title, !title.isEmpty else { return fallback }
        return title
    }

    static func == (lhs: BrowserCapture, rhs: BrowserCapture) -> Bool {
        lhs.image === rhs.image && lhs.url == rhs.url && lhs.title == rhs.title
            && lhs.capturedAt == rhs.capturedAt && lhs.receivedAt == rhs.receivedAt
    }
}

enum SurfaceBrowserState: Equatable {
    case idle
    case loading
    case loaded(BrowserCapture)
    /// `last` is the previous successful capture, kept on screen for transient failures.
    case failed(BrowserCaptureFailure, last: BrowserCapture?)
    /// The relay advertised browsers but does not answer `surface.browser.capture`.
    case unsupported

    var lastCapture: BrowserCapture? {
        switch self {
        case .loaded(let capture): return capture
        case .failed(_, let last): return last
        case .idle, .loading, .unsupported: return nil
        }
    }

    var failure: BrowserCaptureFailure? {
        if case .failed(let failure, _) = self { return failure }
        return nil
    }
}
