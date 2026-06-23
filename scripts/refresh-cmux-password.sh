#!/usr/bin/env bash
# Re-inject the cmux socket password after cmux restarts.
#
# cmux 0.64.16+ in `automation.socketControlMode = "password"` mode reads
# `automation.socketPassword` from `~/.config/cmux/cmux.json` once at startup
# and then strips the field as a privacy hardening step (so the secret does
# not sit in plaintext in cmux.json forever). Restarting cmux therefore wipes
# the server-side password and a launchd-spawned cmux-relay starts seeing:
#
#   ERROR: auth_unconfigured — Password mode is enabled but no socket
#   password is configured in Settings.
#
# This script reads the canonical secret out of the relay's launchd plist
# (where install-launchd.sh staged it via CMUX_SOCKET_PASSWORD), writes it
# back into cmux.json under automation.socketPassword, kicks cmux to ingest
# it, then kicks the relay so it re-dials with valid credentials.
#
# Idempotent: safe to re-run any time. No-op if the secret cmux just wrote
# already matches the relay's plist value.
#
# Run from anywhere (no working-directory assumptions). Requires plutil,
# python3, launchctl, and the cmux CLI on PATH — all default on macOS with
# cmux installed.

set -euo pipefail

LABEL="${CMUX_REMOTE_LABEL:-com.genie.cmuxremote}"
PLIST="${CMUX_REMOTE_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
CMUX_JSON="${CMUX_JSON:-$HOME/.config/cmux/cmux.json}"
SERVICE="gui/$(id -u)/$LABEL"

note() { printf '\033[1;36m[refresh-cmux-password]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[refresh-cmux-password]\033[0m %s\n' "$*" >&2; exit 1; }

command -v plutil    >/dev/null 2>&1 || fail "plutil not found (macOS only)"
command -v python3   >/dev/null 2>&1 || fail "python3 not found"
command -v launchctl >/dev/null 2>&1 || fail "launchctl not found (macOS only)"
command -v cmux      >/dev/null 2>&1 || fail "cmux CLI not on PATH; install cmux first"

[ -f "$PLIST" ]      || fail "launchd plist not found: $PLIST (run scripts/install-launchd.sh first)"
[ -f "$CMUX_JSON" ]  || fail "cmux config not found: $CMUX_JSON (open cmux at least once)"

# 1. Pull the password the relay was installed with. plutil emits the raw
#    string with no decoration, so a length sanity check is the only guard.
PW="$(plutil -extract EnvironmentVariables.CMUX_SOCKET_PASSWORD raw -o - "$PLIST" 2>/dev/null || true)"
if [ -z "$PW" ]; then
  fail "CMUX_SOCKET_PASSWORD is not set in $PLIST. Re-run scripts/install-launchd.sh with CMUX_SOCKET_PASSWORD=… so the launchd agent has a password to share."
fi
note "relay plist holds a password (${#PW} chars, masked: ${PW:0:4}…${PW: -4})"

# 2. Read cmux.json, set automation.socketPassword and ensure
#    automation.socketControlMode is `password`. We do the JSON edit in
#    Python so we never shell-out the secret on the command line and we
#    preserve all other top-level sections (`shortcuts`, `actions`, ui, …).
TMP="$(mktemp "${TMPDIR:-/tmp}/cmux.json.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

CMUX_JSON_PATH="$CMUX_JSON" CMUX_JSON_TMP="$TMP" PW="$PW" python3 <<'PY'
import json, os
src = os.environ["CMUX_JSON_PATH"]
dst = os.environ["CMUX_JSON_TMP"]
pw  = os.environ["PW"]

with open(src, "r", encoding="utf-8") as fh:
    data = json.load(fh)
auto = data.setdefault("automation", {})
changed = False
if auto.get("socketControlMode") != "password":
    auto["socketControlMode"] = "password"
    changed = True
if auto.get("socketPassword") != pw:
    auto["socketPassword"] = pw
    changed = True

with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=False)
    fh.write("\n")
print("changed" if changed else "unchanged")
PY

CHANGE_STATE="$(tail -n 1 < /dev/stdin 2>/dev/null || true)"
# Drop a backup once per day to avoid flooding the user's config dir on
# repeated runs but still preserve the pre-edit state for auditability.
BACKUP="$CMUX_JSON.$(date +%Y%m%d).bak"
[ -f "$BACKUP" ] || cp "$CMUX_JSON" "$BACKUP"
mv "$TMP" "$CMUX_JSON"
trap - EXIT
note "wrote socketControlMode=password + socketPassword to $CMUX_JSON (backup: $BACKUP)"

# 3. Tell cmux to re-ingest. cmux 0.64.16 picks up automation.socketPassword
#    on the next reload-config and writes ~/.local/state/cmux/socket-control-password.
note "cmux reload-config:"
cmux reload-config | sed 's/^/  /'
sleep 1

PWFILE="$HOME/.local/state/cmux/socket-control-password"
if [ -s "$PWFILE" ]; then
  note "cmux wrote $(stat -f '%z' "$PWFILE") bytes to ~/.local/state/cmux/socket-control-password ✓"
else
  fail "cmux did not write the password sidecar at $PWFILE — check 'cmux capabilities --json' and confirm cmux is in password mode"
fi

# 4. Re-dial from the relay so its events.stream subscriber re-auths with
#    cmux's freshly-loaded password. The relay reads CMUX_SOCKET_PASSWORD
#    from its launchd env, so kickstart is enough; no rebuild needed.
note "kickstart $SERVICE"
launchctl kickstart -k "$SERVICE" >/dev/null

# 5. Watch the log briefly and report. Any "event stream unavailable" line
#    after kickstart means auth still fails (likely a stale plist password
#    that no longer matches what cmux ingested — re-run install-launchd.sh
#    with the matching CMUX_SOCKET_PASSWORD).
LOG="$HOME/.cmuxremote/log/stderr.log"
sleep 5
if [ -f "$LOG" ]; then
  ATTACHED=$(grep -c 'event stream attached' "$LOG" || true)
  UNAVAIL=$(grep -c 'event stream unavailable' "$LOG" || true)
  note "post-kickstart log: attached=$ATTACHED unavailable=$UNAVAIL"
  if [ "${ATTACHED:-0}" -lt 1 ]; then
    note "no attach yet; tail of relay log:"
    tail -n 8 "$LOG" | sed 's/^/  /'
    fail "events.stream did not attach. Check that the password in $PLIST matches the one cmux just ingested."
  fi
fi

note "done. iPhone app should now reach cmux through the relay."
