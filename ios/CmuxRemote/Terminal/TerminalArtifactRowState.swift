import SharedKit
import UIKit

enum TerminalArtifactRowState {
    case loading
    case ready(UIImage)
    case generic
    case stale
    case fileChanged
    case unavailable
    case corrupt
    case oversized
    case byteCap
    case pixelCap
    case error

    init(error: Error) {
        switch error {
        case TerminalArtifactStoreError.staleIdentity:
            self = .stale
        case TerminalArtifactStoreError.artifactChanged:
            self = .fileChanged
        case TerminalArtifactStoreError.malformedChunk,
             TerminalArtifactStoreError.malformedThumbnail,
             TerminalArtifactStoreError.notAnImage:
            self = .corrupt
        case TerminalArtifactStoreError.imageTooLarge:
            self = .byteCap
        case TerminalArtifactStoreError.tooManyPixels:
            self = .pixelCap
        case let CmuxRemoteRPCError.rpc(code, _):
            switch RemoteErrorCode(rawValue: code) {
            case .fileChanged: self = .fileChanged
            case .expired, .forbidden: self = .stale
            case .methodNotFound, .notFound: self = .unavailable
            case .sizeLimitExceeded, .chunkTooLarge: self = .byteCap
            case .invalidBase64, .invalidField, .unsupportedMedia: self = .corrupt
            default: self = .error
            }
        default:
            self = .error
        }
    }

    var localizedLabel: String {
        switch self {
        case .loading:
            return String(localized: "terminal.artifact.state.loading", defaultValue: "Loading")
        case .ready:
            return String(localized: "terminal.artifact.state.ready", defaultValue: "Ready")
        case .generic:
            return String(localized: "terminal.artifact.state.generic", defaultValue: "File only")
        case .stale:
            return String(localized: "terminal.artifact.state.stale", defaultValue: "Authorization expired")
        case .fileChanged:
            return String(localized: "terminal.artifact.state.file_changed", defaultValue: "File changed")
        case .unavailable:
            return String(localized: "terminal.artifact.state.unavailable", defaultValue: "Unavailable")
        case .corrupt:
            return String(localized: "terminal.artifact.state.corrupt", defaultValue: "Corrupt image")
        case .oversized:
            return String(localized: "terminal.artifact.state.oversized", defaultValue: "Image too large")
        case .byteCap:
            return String(localized: "terminal.artifact.state.byte_cap", defaultValue: "Image byte limit exceeded")
        case .pixelCap:
            return String(localized: "terminal.artifact.state.pixel_cap", defaultValue: "Image pixel limit exceeded")
        case .error:
            return String(localized: "terminal.artifact.state.error", defaultValue: "Preview failed")
        }
    }

    var localizedDetail: String {
        switch self {
        case .loading:
            return String(localized: "terminal.artifact.detail.loading", defaultValue: "The preview is still being prepared.")
        case .ready:
            return String(localized: "terminal.artifact.detail.ready", defaultValue: "The image is ready to open.")
        case .generic:
            return String(localized: "terminal.artifact.detail.generic", defaultValue: "Only file information is available for this type.")
        case .stale:
            return String(localized: "terminal.artifact.detail.stale", defaultValue: "Refresh to request a new terminal-visible authorization.")
        case .fileChanged:
            return String(localized: "terminal.artifact.detail.file_changed", defaultValue: "The file changed after it appeared in the terminal.")
        case .unavailable:
            return String(localized: "terminal.artifact.detail.unavailable", defaultValue: "The file or relay preview method is unavailable.")
        case .corrupt:
            return String(localized: "terminal.artifact.detail.corrupt", defaultValue: "The image data could not be decoded.")
        case .oversized:
            return String(localized: "terminal.artifact.detail.oversized", defaultValue: "This image is larger than the supported preview size.")
        case .byteCap:
            return String(localized: "terminal.artifact.detail.byte_cap", defaultValue: "The image exceeds the 32 MiB preview limit.")
        case .pixelCap:
            return String(localized: "terminal.artifact.detail.pixel_cap", defaultValue: "The image exceeds the 40 megapixel preview limit.")
        case .error:
            return String(localized: "terminal.artifact.detail.error", defaultValue: "The preview failed without changing the terminal.")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .loading: return "TerminalArtifactStateLoading"
        case .ready: return "TerminalArtifactStateReady"
        case .generic: return "TerminalArtifactStateGeneric"
        case .stale: return "TerminalArtifactStateStale"
        case .fileChanged: return "TerminalArtifactStateFileChanged"
        case .unavailable: return "TerminalArtifactStateUnavailable"
        case .corrupt: return "TerminalArtifactStateCorrupt"
        case .oversized: return "TerminalArtifactStateOversized"
        case .byteCap: return "TerminalArtifactStateByteCap"
        case .pixelCap: return "TerminalArtifactStatePixelCap"
        case .error: return "TerminalArtifactStateError"
        }
    }
}
