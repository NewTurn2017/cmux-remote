# Local install notes

Upstream: `NewTurn2017/cmux-remote`

Pinned commit: `9f805ebe8b063a1a699534c2a2934dd0bb335304`

Local compatibility changes:

- Resolve the Tailscale CLI from `PATH` or the standalone macOS app bundle.
- Read cmux's socket password from the current XDG state path before the legacy path.
- Use the local iPhone Development team, a unique bundle identifier, and no APNs entitlements for personal sideloading.
- Set explicit Xcode product names so Xcode 16 produces `CmuxRemote.app` and the test bundles correctly.
- Format uploaded-file timestamps in UTC so filenames and tests are deterministic across time zones.
- Add an optional self-hosted VPS Broker transport so the Mac and iPhone can
  connect outbound without installing Tailscale on the phone.
- Scope iOS credentials to the complete server URL and relay id, and require
  HTTPS/WSS for public Broker endpoints.

Self-hosted Broker setup: [`broker/README.md`](broker/README.md).

Push notifications that require APNs are disabled in this local build. Terminal control and local notifications are unaffected.

Remaining interactive prerequisites:

- Sign in to a free Apple account in Xcode so it can create a development provisioning profile. A paid Apple Developer membership is not required, but a free sideloaded build normally expires after seven days.
- For Direct mode, install and sign in to Tailscale on the Mac and iPhone using
  the same Tailnet. For Server mode, deploy the Broker and configure
  `~/.cmuxremote/relay.json` instead; Tailscale is not required.
- Connect and unlock the iPhone before installing the signed app build.
