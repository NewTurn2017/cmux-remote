# Privacy Policy — Cmux Remote

_Last updated: 2026-05-14_

Cmux Remote ("the app") is an iPhone client that remote-controls a copy of [cmux](https://cmux.com) running on **your own Mac**, over **your own Tailscale network**. It is published as open source under the MIT license at <https://github.com/NewTurn2017/cmux-remote>.

## Summary

**The app does not collect, transmit, or share any personal data with the developer or any third party.** Everything the app sends or receives travels directly between your iPhone and your Mac through the WireGuard-encrypted Tailscale tunnel.

## What the app stores on your device

The following items are stored locally in the iOS Keychain or `UserDefaults` and never leave your device, except as part of the connection to your own Mac:

| Item | Where | Purpose |
|---|---|---|
| Tailscale host name / IP | `UserDefaults` (`cmux.host`) | Address of your own relay |
| Relay port | `UserDefaults` (`cmux.port`) | TCP port of your own relay (default `4399`) |
| Bearer token | iOS Keychain (`com.genie.cmuxremote/bearer`) | Authenticates this iPhone to your relay |
| Device identifier | iOS Keychain (`com.genie.cmuxremote/device_id`) | Identifies this iPhone to your relay |
| Demo mode flag | `UserDefaults` (`cmux.demoMode`) | Whether App Review / first-run demo mode is on |

The bearer token and device id are issued by **your own Mac relay** during the first connection. The developer of this app never sees them.

## What the app sends over the network

When connected (i.e. demo mode is off and you have configured a host), the app sends:

- A WebSocket connection (`ws://<your-tailscale-host>:<your-port>/v1/ws`) carrying the JSON-RPC protocol described in the open-source repository.
- The same payloads you would type at your Mac terminal: text, key events, screen-subscribe requests.

These connections **only** terminate at the relay process (`cmux-relay`) running on the Mac you configured. They do not transit any server controlled by the app developer.

The `NSAppTransportSecurity / NSAllowsArbitraryLoads` exception declared in the app's `Info.plist` is required because the relay communicates over plain HTTP/WS — confidentiality and integrity are guaranteed by the underlying WireGuard tunnel that Tailscale provides between the two devices.

## Local notifications

The app uses `UNUserNotificationCenter` to display **local** notifications when the relay forwards events from cmux. iOS asks for your permission once at launch. No remote push (APNs) is used in v1.0; no device tokens are sent anywhere.

## What the app does NOT do

- ❌ No analytics, telemetry, crash reporting, or usage statistics
- ❌ No advertising SDKs, no advertising identifiers, no IDFA access
- ❌ No third-party service integrations (Firebase, Google, etc.)
- ❌ No location, camera, microphone, contacts, or photos access
- ❌ No background data collection
- ❌ No tracking across apps or websites

## Demo Mode

When you enable Demo Mode in Settings, the app uses entirely fabricated workspaces, terminal output, and notifications generated locally. No network connections are made.

## Children

The app is rated 4+ and contains no objectionable content, advertising, or tracking. It is, however, a developer tool and not intended for children under the age that can meaningfully use a Unix terminal.

## Open source

The full source code of both the iOS app and the Mac relay is available at <https://github.com/NewTurn2017/cmux-remote>. You can verify any of the claims above by reading the code.

## Changes

If this policy ever changes, the new version will be published in the same repository and the in-app version bumped. There is no opt-in mechanism because there is no data collection to opt in or out of.

## Contact

Security disclosures and privacy questions: see [SECURITY.md](https://github.com/NewTurn2017/cmux-remote/blob/main/SECURITY.md) in the repository.
