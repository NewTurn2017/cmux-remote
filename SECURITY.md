# Security Policy

Thanks for taking the time to look. cmux Remote is a thin client that
brokers terminal access between your Mac and your iPhone over your
Tailscale tailnet, so security issues here can have a sharp blast
radius — please report responsibly.

## Reporting a vulnerability

**Do not file a public GitHub issue for security problems.** Instead,
email the maintainer:

- **hyuni2020@gmail.com** — subject prefix: `[cmux-remote security]`

A working PoC is appreciated but not required. We will acknowledge
receipt within 7 days and aim to ship a fix or mitigation within 30
days of the report, coordinating disclosure with the reporter.

## Scope

In scope:

- the `cmux-relay` Swift daemon (`Sources/RelayServer`, `RelayCore`,
  `CMUXClient`, `SharedKit`)
- the `CmuxRemote` iOS app (`ios/CmuxRemote/...`)
- the wire protocol (HTTP / WebSocket framing, JSON-RPC envelope,
  diff frames)
- the auth path: Tailscale UDS whois, bearer issuance, hashed token
  storage in `DeviceStore`
- the launchd installer (`scripts/install-launchd.sh`) and rendered
  plist template

Out of scope (please report to the upstream projects instead):

- [cmux](https://github.com/manaflow-ai/cmux) itself
- Tailscale, WireGuard, SwiftNIO, swift-crypto, async-http-client
- iOS / macOS platform bugs

## What counts as a vulnerability here

Any of the following are concerning and worth reporting:

- A non-Tailscale source address reaching the relay's RPC handlers
- A device bearer leaking via response body, logs, or pasteboard
- A way to forge a registration that succeeds with a Tailscale
  identity that isn't actually the caller's
- A path that causes the relay or app to leak terminal contents into
  a notification payload, log line, telemetry call, or pasteboard
- Memory or process compromise via crafted RPC / diff frames
- A way to bypass the per-device rate limiter into another device's
  budget
- Anything that lets a paired device read or send to a workspace it
  was not authorized for

## Out of scope (but still happy to hear about)

- Generic launchd / plist hardening suggestions
- App Transport Security tightenings that don't reflect a concrete
  attack
- Reports against forks that have diverged materially from upstream
  `main`

## Acknowledgements

Reporters who follow this process are credited in release notes
(`CHANGELOG.md`) and the public security advisory unless they
explicitly request to remain anonymous.
