# Privacy Policy — Cmux Remote

_Last updated: 2026-11-09 (describes Cmux Remote 2.0.0 and the matching Mac relay)_

Cmux Remote ("the app") is an iPhone and iPad client that remote-controls a copy of [cmux](https://cmux.com) running on **your own Mac**, over **your own Tailscale network**. The Mac side is a small program called `cmux-relay` ("the relay") that runs on your Mac. Both are published as open source under the MIT license at <https://github.com/NewTurn2017/cmux-remote>.

## Summary

**The developer does not run any server that the app or the relay talks to, and the app does not collect, transmit, or share any personal data with the developer.** Your terminal screens, files, documents, browser screenshots, conversations, and notifications travel between your iPhone and your own Mac through the WireGuard-encrypted Tailscale tunnel.

A small amount of optional or maintenance traffic leaves your tailnet for Apple or GitHub instead. None of it goes to the developer. It is all listed here:

| Traffic | From → to | What it contains | When / control |
|---|---|---|---|
| Push notifications (optional) | Your Mac's relay → Apple's push service → your device | The notification's title, subtitle, and body, plus workspace, surface, and notification ids (see [Notifications](#notifications)) | Sent only if an `apns` block is configured on the relay |
| App Store version check | The app → Apple (`itunes.apple.com`) | The app's bundle ID and your country code, nothing else (see [Update checks](#update-checks)) | At most once every 24 hours, when the app opens or the Settings version section is shown; failures are ignored |
| Relay update check | Your Mac's relay → GitHub (`github.com/NewTurn2017/cmux-remote`) | A git request for the repository's release tags, and the code of a newer release when one exists (see [Update checks](#update-checks)) | About hourly; turn it off with `./scripts/install-launchd.sh --no-auto-update` |

## What the app stores on your device

The following items are stored locally in the iOS Keychain, in `UserDefaults`, or in the app's Caches folder. They never leave your device, except as part of the connection to your own Mac:

| Item | Where | Purpose |
|---|---|---|
| Tailscale host name / IP | `UserDefaults` (`cmux.host`) | Address of your own relay |
| Relay port | `UserDefaults` (`cmux.port`) | TCP port of your own relay (default `4399`) |
| Bearer token | iOS Keychain (`com.genie.cmuxremote/bearer`) | Authenticates this iPhone to your relay |
| Device identifier | iOS Keychain (`com.genie.cmuxremote/device_id`) | Identifies this iPhone to your relay |
| Demo mode flag | `UserDefaults` (`cmux.demoMode`) | Whether App Review / first-run demo mode is on |
| Local notification switch | `UserDefaults` (`cmux.localNotificationsEnabled`) | Whether the app may raise local banners |
| Document text size | `UserDefaults` (`cmux.documentTextScale`) | Zoom level of the document viewer |
| App Store check cache | `UserDefaults` (`cmux.appStore.*`) | When the app last checked, the latest version number, its App Store link, its minimum iOS version, and the version you last saw in Settings, so the notice survives a restart |
| Cached files and thumbnails | The app's Caches folder (`TerminalArtifacts`) | Copies of files and images you opened from your Mac, kept so they open faster. The cache is limited to 128 MiB of files and 32 MiB of thumbnails, and iOS may clear it at any time |
| Notification inbox | Memory only | The 200 most recent notification cards (title and text). They are gone when the app quits |

The bearer token and device id are issued by **your own Mac relay** during the first connection. The developer of this app never sees them.

The app includes one open-source library, [IOSSecuritySuite](https://github.com/securing/IOSSecuritySuite) (MIT), that runs entirely on your device to detect a jailbroken phone. If it detects one, the app erases the credentials it keeps in the Keychain. The library does not contact any server. The app also ships a privacy manifest (`PrivacyInfo.xcprivacy`) that declares no tracking and no collected data types.

Photos and files you choose to attach are copied to a temporary folder inside the app while they are prepared for upload to your Mac.

## What the app sends over the network

When connected (that is, demo mode is off and you have configured a host), the app sends:

- A WebSocket connection (`ws://<your-tailscale-host>:<your-port>/v1/ws`) carrying the JSON-RPC protocol described in the open-source repository.
- The same payloads you would type at your Mac terminal: text, key events, screen-subscribe requests.
- The files and photos you pick to upload. The relay saves them under `~/Downloads/cmux-remote` on your Mac.
- Your answers to the questions, permission requests, and plan approvals that coding agents on your Mac are waiting on (the AGENTS tab).

When you ask to see something, the relay on your Mac reads it and sends it to the app:

- Terminal screens you subscribe to, and files or images that appear in the terminal output when you open them.
- Markdown tabs and text files. The relay takes the file path from cmux; the app never supplies a path.
- Screenshots of cmux browser tabs, with the page title and URL. The relay asks cmux for a temporary image in your Mac's temporary folder (`cmux-browser-screenshots`), converts it to a small JPEG, and removes the temporary file. The view is read-only: nothing is sent back to the browser.
- Claude conversations. The relay reads only `.jsonl` session files inside `~/.claude/projects`. File paths and resume commands are not sent to the app.
- Notification text, so the app can show it in the Inbox and in banners.

These connections **only** terminate at the relay process (`cmux-relay`) running on the Mac you configured. They do not transit any server controlled by the app developer.

The `NSAppTransportSecurity / NSAllowsArbitraryLoads` exception declared in the app's `Info.plist` is required because the relay communicates over plain HTTP/WS — confidentiality and integrity are guaranteed by the underlying WireGuard tunnel that Tailscale provides between the two devices.

## Notifications

The app uses `UNUserNotificationCenter` to display **local** notifications when the relay forwards events from cmux. iOS asks for your permission. While the app is connected, each new notification appears in the Inbox with its title and text, and as a local banner. Clearing notifications on your Mac clears them from the Inbox.

### Push notifications (optional)

Push notifications reach the app even when it is closed. They are **optional and off by default**: the relay sends one only if you (or whoever runs the Mac) added an `apns` block with an Apple push key to the relay's configuration. Without that block, nothing is sent to Apple.

- **Route:** your Mac's relay → Apple Push Notification service (`api.push.apple.com`, or `api.sandbox.push.apple.com` for development builds) → your device. The developer's servers are not involved.
- **Contents:** the notification's title and subtitle (each cut to 128 characters), its body (cut to 1,024 characters), the workspace, surface, and notification ids, and a thread id that groups banners. If a notification has no text yet, the push says only "cmux needs attention".
- **The body is whatever text the cmux notification carries.** Programs running in your terminal, such as coding agents, write that text, so it can contain words from your work. The terminal screen itself is not sent in a push.
- **Apple processes the push** to deliver it, under Apple's own privacy terms. The developer never receives it.
- **Device token:** iOS gives the app a push token, and the app registers it with your own relay. The developer never receives it.
- **To turn push off:** remove the `apns` block from the relay configuration and restart the relay, or turn off notifications for the app in iOS Settings.

## Update checks

Version 2.0.0 adds two update checks. Neither sends your terminal contents, tokens, or account data, and neither goes to the developer.

### App Store version check (the app)

- **Where:** the app asks Apple's App Store lookup service (`https://itunes.apple.com/lookup`) for the latest published version of Cmux Remote.
- **What it sends:** the app's bundle ID and your country code (from your device's region) as query parameters. There are no cookies, identifiers, or user data. As with any web request, Apple sees your device's IP address. If the lookup returns nothing for your country, the app asks once more without the country code, so a day with a check has at most two requests.
- **When:** when the app becomes active or you open the Settings version section, and only if the last check was more than 24 hours ago. Failures (no network, an error from the service) are ignored silently.
- **What is kept:** the time of the last check, the latest version number, its App Store link, its minimum iOS version, and the last version you saw, in `UserDefaults` on your device. If a newer version exists, the Settings tab shows a dot and the Settings version section offers an Open App Store button.
- **Demo Mode:** the check does not depend on Demo Mode, so it still runs there.

### Relay update check (your Mac)

- **Where:** a separate background job on your Mac (`com.genie.cmuxremote.updater`) contacts the repository `https://github.com/NewTurn2017/cmux-remote.git` over https. Nothing goes through the developer.
- **What it does:** it lists the repository's release tags (`git ls-remote --tags`) and follows only tags named `vX.Y.Z` that are newer than the installed version. When there is one, it downloads that release's code into a folder under `~/.cmuxremote/src`, builds and signs it on your Mac, and installs it. GitHub sees your Mac's IP address and the git request.
- **When:** the first check comes about 15 to 20 minutes after installation, then at most once an hour. The relay restarts for an update only after no phone has been connected for two minutes; tapping Update Now in the app applies it right away.
- **What it records:** the update log (`~/.cmuxremote/log/update.log`) and the state files hold tags, commit ids, states, and times. They contain no terminal contents, tokens, or signing identities, and home paths are shortened to `~`.
- **To turn it off:** run `./scripts/install-launchd.sh --no-auto-update` on your Mac. The relay then makes no GitHub request at all, and the app shows that auto-update is off. Run it with `--auto-update` to turn it on again.

## What the app does NOT do

- ❌ No analytics, telemetry, crash reporting, or usage statistics
- ❌ No advertising SDKs, no advertising identifiers, no IDFA access
- ❌ No third-party analytics, advertising, or tracking SDKs, and no third-party service integrations (Firebase, Google, etc.). The services outside your tailnet are the ones listed in the Summary
- ❌ No location, camera, microphone, or contacts access, and no access to your photo library: photos and files are sent only when you pick them to attach
- ❌ No background data collection
- ❌ No tracking across apps or websites

## Demo Mode

When you enable Demo Mode in Settings, the app uses entirely fabricated workspaces, terminal output, and notifications generated locally. The app makes no connection to a relay. The once-a-day App Store version check described under [Update checks](#update-checks) still runs.

## Children

The app is rated 4+ and contains no objectionable content, advertising, or tracking. It is, however, a developer tool and not intended for children under the age that can meaningfully use a Unix terminal.

## Open source

The full source code of both the iOS app and the Mac relay is available at <https://github.com/NewTurn2017/cmux-remote>. You can verify any of the claims above by reading the code.

## Changes

If this policy ever changes, the new version will be published in the same repository and the "Last updated" date above will change. The developer collects no data, so there is nothing to opt in or out of. Push notifications are opt-in on your Mac: they are sent only if you configure them.

## Contact

Security disclosures and privacy questions: see [SECURITY.md](https://github.com/NewTurn2017/cmux-remote/blob/main/SECURITY.md) in the repository.
