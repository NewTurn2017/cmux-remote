import Foundation
import SharedKit

/// What the Settings RELAY rows show for one snapshot of connection, capability, and relay state.
struct RelaySettingsPresentation: Equatable {
    enum Version: Equatable {
        case loading
        case legacy
        case known(String)
        case unknown
    }

    enum Status: Equatable {
        case upToDate
        case available(String)
        case checking
        case downloading
        case building
        case staged(String?)
        case applying
        case restarting
        case failed(RelayUpdateFailureCode?)
        case disabled
        case unavailable
        case unknownState(String)
        case disconnected
    }

    enum UpdateButton: Equatable {
        case hidden
        case enabled
        case disabled
    }

    let version: Version
    let status: Status?
    let stateRawValue: String?
    let autoUpdateEnabled: Bool?
    let lastCheckedAt: Date?
    let showsAdhocWarning: Bool
    let showsManualGuide: Bool
    let updateButton: UpdateButton

    init(
        isConnected: Bool,
        capabilitiesResolved: Bool,
        supportsInfo: Bool,
        supportsUpdate: Bool,
        info: RelayInfoResult?,
        isLoading: Bool,
        isRequesting: Bool,
        hasPendingRequest: Bool
    ) {
        let isLegacy = isConnected && capabilitiesResolved && !supportsInfo
        let update = isLegacy ? nil : info?.update

        if isLegacy {
            version = .legacy
        } else if let info {
            version = .known(info.version)
        } else if isConnected && (!capabilitiesResolved || isLoading) {
            version = .loading
        } else {
            version = .unknown
        }

        stateRawValue = update?.state.rawValue
        autoUpdateEnabled = update?.autoUpdateEnabled
        lastCheckedAt = update?.lastCheckedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        showsAdhocWarning = update?.adhocSigning == true
        showsManualGuide = isLegacy

        if let update, let info {
            status = Self.status(
                update: update,
                version: info.version,
                isConnected: isConnected,
                hasPendingRequest: hasPendingRequest
            )
        } else if !isConnected, info != nil {
            status = .disconnected
        } else {
            status = nil
        }

        guard !isLegacy, isConnected, supportsUpdate, info != nil else {
            updateButton = .hidden
            return
        }
        if isRequesting {
            updateButton = .disabled
            return
        }
        switch update?.state {
        case .disabled, .unavailable:
            updateButton = .hidden
        case .checking, .downloading, .building, .applying:
            updateButton = .disabled
        case .staged:
            updateButton = hasPendingRequest ? .disabled : .enabled
        case .idle, .failed, .unknown, nil:
            updateButton = .enabled
        }
    }

    /// A relay before 2.0 forwards unknown methods to the cmux daemon, so `relay.info`
    /// goes out only once this connection's capabilities advertise it.
    static func shouldQueryInfo(isConnected: Bool, capabilitiesResolved: Bool, supportsInfo: Bool) -> Bool {
        isConnected && capabilitiesResolved && supportsInfo
    }

    /// `relay=<value>` for UI tests: current, legacy, loading, or unknown.
    var versionAccessibilityValue: String {
        switch version {
        case .known: return "relay=current"
        case .legacy: return "relay=legacy"
        case .loading: return "relay=loading"
        case .unknown: return "relay=unknown"
        }
    }

    private static func status(
        update: RelayUpdateStatus,
        version: String,
        isConnected: Bool,
        hasPendingRequest: Bool
    ) -> Status {
        guard isConnected else {
            switch update.state {
            case .applying:
                return .restarting
            case .staged where hasPendingRequest:
                return .restarting
            default:
                return .disconnected
            }
        }
        switch update.state {
        case .idle:
            if let latest = update.latestVersion,
               let latestVersion = SemanticVersion(latest),
               let installed = SemanticVersion(version),
               latestVersion > installed
            {
                return .available(latest)
            }
            return .upToDate
        case .checking: return .checking
        case .downloading: return .downloading
        case .building: return .building
        case .staged: return .staged(update.latestVersion)
        case .applying: return .applying
        case .failed: return .failed(update.lastErrorCode)
        case .disabled: return .disabled
        case .unavailable: return .unavailable
        case .unknown(let raw): return .unknownState(raw)
        }
    }
}

enum RelaySettingsText {
    static let manualUpdateURL = URL(string: "https://github.com/NewTurn2017/cmux-remote#readme")!

    static func version(_ version: RelaySettingsPresentation.Version) -> String {
        switch version {
        case .known(let value):
            return value
        case .legacy:
            return String(localized: "settings.relay.version.legacy", defaultValue: "Unknown (before 2.0)")
        case .loading:
            return String(localized: "settings.relay.version.loading", defaultValue: "Checking…")
        case .unknown:
            return "—"
        }
    }

    static func status(_ status: RelaySettingsPresentation.Status) -> String {
        switch status {
        case .upToDate:
            return String(localized: "settings.relay.status.up_to_date", defaultValue: "Up to date")
        case .available(let latest):
            return String(
                localized: "settings.relay.status.available",
                defaultValue: "Version \(latest) is available"
            )
        case .checking:
            return String(localized: "settings.relay.status.checking", defaultValue: "Checking for updates…")
        case .downloading:
            return String(localized: "settings.relay.status.downloading", defaultValue: "Downloading the update…")
        case .building:
            return String(
                localized: "settings.relay.status.building",
                defaultValue: "Building the update. This can take a few minutes."
            )
        case .staged(let latest?):
            return String(
                localized: "settings.relay.status.staged",
                defaultValue: "Version \(latest) is ready. The relay restarts when no phone is connected."
            )
        case .staged(nil):
            return String(
                localized: "settings.relay.status.staged_unversioned",
                defaultValue: "An update is ready. The relay restarts when no phone is connected."
            )
        case .applying:
            return String(
                localized: "settings.relay.status.applying",
                defaultValue: "Applying the update. The relay is restarting."
            )
        case .restarting:
            return String(
                localized: "settings.relay.status.restarting",
                defaultValue: "The relay is restarting. Reconnecting automatically…"
            )
        case .failed(let code):
            return String(
                localized: "settings.relay.status.failed",
                defaultValue: "Update failed: \(failureReason(code))"
            )
        case .disabled:
            return String(
                localized: "settings.relay.status.disabled",
                defaultValue: "Auto-update is turned off on the Mac."
            )
        case .unavailable:
            return String(
                localized: "settings.relay.status.unavailable",
                defaultValue: "This relay install can't update itself."
            )
        case .unknownState:
            return String(localized: "settings.relay.status.unknown", defaultValue: "Update status unknown")
        case .disconnected:
            return String(
                localized: "settings.relay.status.disconnected",
                defaultValue: "Not connected. Showing the last known version."
            )
        }
    }

    static func failureReason(_ code: RelayUpdateFailureCode?) -> String {
        switch code {
        case .networkFailed:
            return String(localized: "settings.relay.failure.network_failed", defaultValue: "couldn't download the release")
        case .tagVerificationFailed:
            return String(localized: "settings.relay.failure.tag_verification_failed", defaultValue: "the release tag didn't verify")
        case .buildFailed:
            return String(localized: "settings.relay.failure.build_failed", defaultValue: "the build failed")
        case .versionMismatch:
            return String(localized: "settings.relay.failure.version_mismatch", defaultValue: "the built version didn't match the release")
        case .signFailed:
            return String(localized: "settings.relay.failure.sign_failed", defaultValue: "couldn't sign the new relay")
        case .installFailed:
            return String(localized: "settings.relay.failure.install_failed", defaultValue: "install failed; the previous relay was restored")
        case .startFailed:
            return String(localized: "settings.relay.failure.start_failed", defaultValue: "the new relay didn't start; the previous relay was restored")
        case .insufficientDisk:
            return String(localized: "settings.relay.failure.insufficient_disk", defaultValue: "not enough disk space on the Mac")
        case .toolchainMissing:
            return String(localized: "settings.relay.failure.toolchain_missing", defaultValue: "Swift or git is missing on the Mac")
        case .versionUnknown:
            return String(localized: "settings.relay.failure.version_unknown", defaultValue: "couldn't read the installed version")
        case .interrupted:
            return String(localized: "settings.relay.failure.interrupted", defaultValue: "the update was interrupted")
        case .unknown, nil:
            return String(localized: "settings.relay.failure.unknown", defaultValue: "unknown reason")
        }
    }

    static func autoUpdate(enabled: Bool) -> String {
        enabled
            ? String(localized: "settings.relay.auto_update.on", defaultValue: "Auto-update on")
            : String(localized: "settings.relay.auto_update.off", defaultValue: "Auto-update off")
    }

    static func lastChecked(_ date: Date, relativeTo now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: min(date, now), relativeTo: now)
        return String(localized: "settings.relay.last_checked", defaultValue: "Last checked \(relative)")
    }

    static func outcome(_ outcome: RelayUpdateOutcome) -> String {
        switch outcome {
        case .updated(let from, let to):
            return String(localized: "settings.relay.result.updated", defaultValue: "Updated \(from) → \(to)")
        case .upToDate:
            return String(localized: "settings.relay.result.up_to_date", defaultValue: "Already up to date")
        case .timedOut:
            return String(
                localized: "settings.relay.result.timed_out",
                defaultValue: "Still in progress. Check again later."
            )
        }
    }

    static func requestFailure(_ failure: RelayUpdateRequestFailure) -> String {
        switch failure {
        case .disabled:
            return String(
                localized: "settings.relay.request.disabled",
                defaultValue: "Auto-update is turned off on the Mac, so the relay can't update now."
            )
        case .unavailable:
            return String(
                localized: "settings.relay.request.unavailable",
                defaultValue: "This relay can't update itself right now."
            )
        case .failed:
            return String(
                localized: "settings.relay.request.failed",
                defaultValue: "Couldn't start the update. Try again."
            )
        }
    }
}
