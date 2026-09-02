import Foundation

extension CmuxRemoteApp {
    static func connectionMessage(for error: AuthError) -> String {
        switch error {
        case .pairingRemoved:
            return String(
                localized: "connection.error.pairing_removed",
                defaultValue: "Pairing was removed on the Mac. Select Unpair This Device, then reconnect."
            )
        case .registrationDenied:
            return String(
                localized: "connection.error.registration_denied",
                defaultValue: "This Tailscale account is not allowed by the Mac relay."
            )
        case .relayUnavailable:
            return String(
                localized: "connection.error.relay_unavailable",
                defaultValue: "The Mac relay is waiting for Tailscale and will retry automatically."
            )
        case .disallowedHost:
            return String(
                localized: "connection.error.disallowed_host",
                defaultValue: "Enter a Tailscale IP or tailnet DNS name."
            )
        case .missingHost:
            return String(
                localized: "connection.error.missing_host",
                defaultValue: "Enter the Mac Tailscale address in Settings."
            )
        case .transport:
            return String(
                localized: "connection.error.transport",
                defaultValue: "The Mac relay is unreachable."
            )
        default:
            return String(
                localized: "connection.error.generic",
                defaultValue: "The relay returned an invalid response."
            )
        }
    }
}
