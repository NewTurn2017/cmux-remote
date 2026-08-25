[🇰🇷 한국어](connection-guide.md) · 🇺🇸 English

# cmux Remote connection guide

> When the iPhone app can't reach your Mac, this is the **anyone-can-apply**
> setup + troubleshooting walkthrough. Every command runs **on the Mac**.
> Copy and paste them one line at a time, top to bottom.

cmux Remote has two parts:

- **Mac**: `cmux-relay` (a small background service) runs next to cmux and
  answers the iPhone's requests.
- **iPhone**: the cmux Remote app attaches only to that relay, over Tailscale.

For the iPhone to connect, three things must be true at once:
**① cmux running + ② relay running + ③ same Tailnet**. When it won't
connect, one of these three is almost always missing.

---

## 0. Prerequisites (once)

```bash
cmux --version       # cmux must be installed and running
tailscale status     # Tailscale must be signed in and online
swift --version      # Swift 5.10+ (Xcode 15.3+)
```

- No `cmux`? → install and launch [cmux](https://github.com/manaflow-ai/cmux) first.
- No `tailscale`? → install [Tailscale](https://tailscale.com/download) on **both** Mac and iPhone, signed into the same account.
- No `swift`? → install Xcode from the App Store (or `xcode-select --install`).

---

## 1. Install (on the Mac)

```bash
git clone https://github.com/NewTurn2017/cmux-remote.git
cd cmux-remote
./scripts/install-launchd.sh
```

That one line:

1. builds the relay in release mode (`~/.cmuxremote/bin/`),
2. writes a default config if none exists (`~/.cmuxremote/relay.json`),
3. registers it as a background service that auto-starts on login.

Logs land in `~/.cmuxremote/log/`.

> The first build can take a few minutes. If you get an error about
> `swift` or `launchctl` not being found, re-check **Prerequisites** above.

---

## 2. Confirm the relay is up (on the Mac)

```bash
curl -s http://$(tailscale ip -4):4399/v1/health
```

`{"ok":true,"version":"0.1.0"}` means the **relay is healthy**.

Confirm it also attached to the cmux socket:

```bash
./scripts/cmux-probe.sh
# {"id":"probe-1","result":{...}}  ← a result object means OK
```

If both are fine, go to step 3 (pairing). If there's no response, jump to
**4. Troubleshooting**.

---

## 3. Pair your iPhone

Find your Mac's address first:

```bash
tailscale ip -4      # e.g. 100.101.102.103  ← enter this in the app
tailscale status     # if you'd rather use the MagicDNS name (e.g. my-mac)
```

On the iPhone, open the cmux Remote app and:

1. Tap **Add Mac**
2. Enter the IP (or MagicDNS name) above, port **`4399`**
3. **Approve** the pairing request that appears in the Mac's menu bar

Once connected, the workspace list appears.

---

## 4. Troubleshooting

Check these in order, one line at a time. **Most issues resolve at ① or ②.**

```bash
SERVICE="gui/$(id -u)/com.genie.cmuxremote"
```

### ① Is cmux running?

If the cmux app is closed, the relay can't read the screen.

```bash
cmux --version
# After launching the cmux app:
launchctl kickstart -k "$SERVICE"
```

### ② Is the relay alive?

```bash
curl -s http://$(tailscale ip -4):4399/v1/health
```

- No response → restart: `launchctl kickstart -k "$SERVICE"`
- Still nothing → reinstall: `./scripts/install-launchd.sh`
- Status: `launchctl print "$SERVICE" | grep -E "state|pid|last exit"`

### ③ Are the logs healthy?

```bash
tail -n 40 ~/.cmuxremote/log/stderr.log
```

Healthy startup shows these three lines:

```
starting cmux-relay on 0.0.0.0:4399
listening …
cmux event stream attached
```

Depending on the log:

| Log message | Meaning | Fix |
|---|---|---|
| `cmux event stream unavailable: socketMissing` | cmux is not running | Launch the cmux app, then `launchctl kickstart -k "$SERVICE"` |
| Repeated `Connection refused` | cmux restarted and the socket name rotated | `launchctl kickstart -k "$SERVICE"`; if needed, re-run `./scripts/install-launchd.sh` |
| Repeated `cmux event stream attached` then immediately `detached` | cmux socket access denied (cmux 0.64+) | See **③a** below |
| `attached`, then `detached` after ~30 s, on repeat | password mode is on but no socket password is set | See **③a** below |
| Three lines OK but only the app can't attach | network/address issue | Check ④ and ⑤ |

### ③a Socket access denied (cmux 0.64+)

cmux 0.64 introduced a socket access control mode that defaults to
`cmuxOnly`. It authorises by process ancestry — only processes launched
inside cmux may connect. The relay runs as a launchd agent outside cmux,
so cmux rejects it with:

```text
ERROR: Access denied — only processes started inside cmux can connect
```

Fix: switch cmux to password mode, then set a socket password.

**1. Set the mode.** cmux creates `~/.config/cmux/cmux.json` on launch,
so edit the existing file rather than overwriting it (back it up first):

```jsonc
{
  "automation": {
    "socketControlMode": "password"
  }
}
```

You can also set the mode in cmux Settings → Automation.

**2. Restart the cmux app.** `cmux reload-config` is not enough — as of
cmux 0.64.19 the socket listener reads `socketControlMode` only at
startup.

> Restarting cmux terminates everything running inside it, including
> agent sessions in cmux workspaces. Finish or hand off that work first.

**3. Set the password in cmux Settings.** Press ⌘, in cmux →
**Automation** → set the socket password there. It cannot be set from a
file: as of cmux 0.64.19 cmux keeps the password in the Keychain, and on
restart it drops any `automation.socketPassword` key from `cmux.json`
along with the password file below.

**4. Restart the relay** so it picks the password up:

```bash
launchctl kickstart -k "$SERVICE"
```

The relay reads the first non-empty password once at process start, in this
order:

1. `CMUX_SOCKET_PASSWORD`
2. `$XDG_STATE_HOME/cmux/socket-control-password` when `XDG_STATE_HOME` is set
3. `~/.local/state/cmux/socket-control-password`
4. `~/Library/Application Support/cmux/socket-control-password`

cmux writes the state-directory file when the password is set. Restart the
relay after any password change.

**If the mode is on but the password is empty**, cmux accepts the
connection and then drops it after a ~30 s grace period, so the log shows
`attached` and `detached` on a 30 s cycle. cmux's own CLI also fails with
`auth_required` in this state. Check that the applicable environment value or
password file from the lookup order above exists and is non-empty.

### ④ Is Tailscale online on both ends?

```bash
tailscale status
```

- The Mac and iPhone must be on the **same Tailnet (same account)**.
- Make sure Tailscale is toggled on in the iPhone's Tailscale app.

### ⑤ Is the address in the app correct?

```bash
tailscale ip -4
```

- Confirm the app uses this exact **IP** and port **`4399`**.
- If you used a MagicDNS name, it must match `tailscale status` spelling.

### Still stuck?

A previously paired device token may have been revoked.

```bash
.build/release/cmux-relay devices list     # see registered devices
# If needed, remove a device and re-pair from the app:
# .build/release/cmux-relay devices revoke <device-id>
```

---

## FAQ

**Q. It disconnects every time I restart cmux.**
cmux can change its internal socket name on restart. The fastest way to
re-attach the relay:

```bash
launchctl kickstart -k "gui/$(id -u)/com.genie.cmuxremote"
```

**Q. We're on the same Wi-Fi but it won't connect.**
This app connects over **Tailscale**, not Wi-Fi. Both ends must be signed
into Tailscale, and the app needs the IP from `tailscale ip -4`.

**Q. No notifications.**
Notifications are currently *local*: they only arrive while the app is
open or alive in the background. If you fully quit the app, none arrive
(real push is planned for v1.1).

**Q. Do I have to start it manually each time?**
No. The relay is a launchd service, so it **auto-starts on Mac login** and
respawns if it dies. You do, however, need to **launch the cmux app**
yourself.

---

## Short notice to send to a user

Forward this verbatim to anyone reporting they can't connect:

> **cmux Remote connection check (run on the Mac)**
>
> 1. Make sure the cmux app is open.
> 2. Paste into Terminal:
>    ```bash
>    SERVICE="gui/$(id -u)/com.genie.cmuxremote"
>    launchctl kickstart -k "$SERVICE"
>    curl -s http://$(tailscale ip -4):4399/v1/health
>    ```
>    → `{"ok":true,...}` means the relay is healthy.
> 3. Confirm the iPhone app and the Mac are signed into the **same
>    Tailscale account**.
> 4. In the app, enter the IP from `tailscale ip -4` and port `4399`.
>
> Still stuck? Send the output of
> `tail -n 40 ~/.cmuxremote/log/stderr.log`.
