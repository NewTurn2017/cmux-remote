import SharedKit

enum DocumentLoadFailure: Equatable, Sendable {
    case notDocument
    case notFound
    case tooLarge
    case disconnected
    case fileChanged
    case notText
    case generic

    init(error: Error) {
        switch error {
        case let CmuxRemoteRPCError.rpc(code, _):
            switch RemoteErrorCode(rawValue: code) {
            case .surfaceNotDocument, .unsupportedMedia: self = .notDocument
            case .notFound: self = .notFound
            case .sizeLimitExceeded, .chunkTooLarge: self = .tooLarge
            case .fileChanged, .forbidden, .expired: self = .fileChanged
            default: self = .generic
            }
        case TextArtifactLoaderError.fileChanged,
             TerminalArtifactStoreError.artifactChanged,
             TerminalArtifactStoreError.staleIdentity:
            self = .fileChanged
        case TerminalArtifactStoreError.inactive:
            self = .disconnected
        default:
            self = .generic
        }
    }

    var canRetry: Bool { self != .notDocument && self != .notText }

    var message: String {
        switch self {
        case .notDocument:
            return String(localized: "document.error.not_document", defaultValue: "This tab can't be opened as a document.")
        case .notFound:
            return String(localized: "document.error.not_found", defaultValue: "The file couldn't be found. It may have moved or been deleted.")
        case .tooLarge:
            return String(localized: "document.error.too_large", defaultValue: "This file is too large to open on mobile.")
        case .disconnected:
            return String(localized: "document.error.disconnected", defaultValue: "Disconnected from the relay. Reconnect, then try again.")
        case .fileChanged:
            return String(localized: "document.error.file_changed", defaultValue: "The file changed. Refresh to load the latest version.")
        case .notText:
            return String(localized: "document.error.not_text", defaultValue: "This file doesn't look like text.")
        case .generic:
            return String(localized: "document.error.generic", defaultValue: "The document couldn't be loaded.")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .notDocument: return "DocumentErrorNotDocument"
        case .notFound: return "DocumentErrorNotFound"
        case .tooLarge: return "DocumentErrorTooLarge"
        case .disconnected: return "DocumentErrorDisconnected"
        case .fileChanged: return "DocumentErrorFileChanged"
        case .notText: return "DocumentErrorNotText"
        case .generic: return "DocumentErrorGeneric"
        }
    }
}
