import SharedKit

enum BrowserCaptureFailure: Equatable, Sendable {
    /// `surface_not_browser`: the tab was closed or is not a browser. The relay reports both the same way.
    case notBrowser
    case temporarilyUnavailable
    case disconnected
    case tooLarge
    case invalidImage
    case generic

    init(error: Error) {
        switch error {
        case let CmuxRemoteRPCError.rpc(code, _):
            switch code {
            case RemoteErrorCode.surfaceNotBrowser.rawValue: self = .notBrowser
            case "temporarily_unavailable": self = .temporarilyUnavailable
            case RemoteErrorCode.sizeLimitExceeded.rawValue, RemoteErrorCode.chunkTooLarge.rawValue: self = .tooLarge
            case "offline": self = .disconnected
            default: self = .generic
            }
        case RPCClientError.closed:
            self = .disconnected
        case RPCClientError.timeout:
            self = .temporarilyUnavailable
        case RemoteProtocolError.chunkTooLarge:
            self = .tooLarge
        case is RemoteProtocolError, is BrowserCaptureDecodeError:
            self = .invalidImage
        default:
            self = .generic
        }
    }

    /// Persistent failures drop the last image and pause automatic refresh until the user retries.
    var isPersistent: Bool { self == .notBrowser }

    var message: String {
        switch self {
        case .notBrowser:
            return String(localized: "browser.error.not_browser", defaultValue: "This tab can't be viewed. It may have been closed, or it isn't a browser tab.")
        case .temporarilyUnavailable:
            return String(localized: "browser.error.temporarily_unavailable", defaultValue: "The Mac didn't answer in time. Retrying shortly.")
        case .disconnected:
            return String(localized: "browser.error.disconnected", defaultValue: "Disconnected from the relay. Reconnect, then try again.")
        case .tooLarge:
            return String(localized: "browser.error.too_large", defaultValue: "This page's screenshot is too large to show.")
        case .invalidImage:
            return String(localized: "browser.error.invalid_image", defaultValue: "The page screenshot couldn't be displayed.")
        case .generic:
            return String(localized: "browser.error.generic", defaultValue: "The page screenshot couldn't be updated.")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .notBrowser: return "BrowserErrorNotBrowser"
        case .temporarilyUnavailable: return "BrowserErrorTemporarilyUnavailable"
        case .disconnected: return "BrowserErrorDisconnected"
        case .tooLarge: return "BrowserErrorTooLarge"
        case .invalidImage: return "BrowserErrorInvalidImage"
        case .generic: return "BrowserErrorGeneric"
        }
    }
}
