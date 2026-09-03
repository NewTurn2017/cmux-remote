#!/usr/bin/env bash
# Live integration smoke for cmux-relay.
#
# Boots the daemon against ~/.cmuxremote/relay.json, then walks the wire
# protocol from the outside: /v1/health, /v1/devices/me/register,
# authenticated credential preflight, /v1/state, /v1/devices/me/apns,
# frame. Phases that depend on tailscaled or websocat skip gracefully
# instead of failing so the operator can still see health pass on a
# bare box.
#
# Run from a checkout root: `bash scripts/smoke-relay.sh`.
# Full local Tailnet smoke without mutating ~/.cmuxremote:
#   SMOKE_EPHEMERAL=1 \
#   SMOKE_LISTEN_HOST=0.0.0.0 \
#   SMOKE_CONNECT_HOST="$(tailscale ip -4 | head -1)" \
#   bash scripts/smoke-relay.sh
# Requires: curl, swift, jq or python3. Optional: websocat (WS test).
# Not run in CI — cmux daemon and Tailscale are operator-side deps.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LISTEN_HOST="${SMOKE_LISTEN_HOST:-${SMOKE_HOST:-127.0.0.1}}"
CONNECT_HOST="${SMOKE_CONNECT_HOST:-$LISTEN_HOST}"
PORT="${SMOKE_PORT:-4399}"
RUN_HOME="$HOME"
TMP_ROOT=""
if [ "${SMOKE_EPHEMERAL:-0}" = "1" ]; then
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-relay-smoke.XXXXXX")"
  TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
  RUN_HOME="${TMP_ROOT}/home"
  if [ -z "${SMOKE_PORT:-}" ]; then
    PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
  fi
  if [ -z "${SMOKE_LISTEN_HOST:-}" ] && [ -z "${SMOKE_HOST:-}" ] && command -v tailscale >/dev/null 2>&1; then
    tailnet_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    if [ -n "$tailnet_ip" ]; then
      LISTEN_HOST="0.0.0.0"
      CONNECT_HOST="${SMOKE_CONNECT_HOST:-$tailnet_ip}"
    fi
  fi
fi
BASE="http://${CONNECT_HOST}:${PORT}"
WS_BASE="ws://${CONNECT_HOST}:${PORT}"
CFG_DIR="${RUN_HOME}/.cmuxremote"
CFG="${CFG_DIR}/relay.json"
LOGIN_NAME="${SMOKE_LOGIN:-}"
SMOKE_DEVICE_ID=""
RELAY_PID=""
CMUX_PASSWORD="${CMUX_SOCKET_PASSWORD:-}"
if [ -z "$CMUX_PASSWORD" ]; then
  for password_file in \
    "$HOME/.local/state/cmux/socket-control-password" \
    "$HOME/Library/Application Support/cmux/socket-control-password"; do
    if [ -s "$password_file" ]; then
      CMUX_PASSWORD="$(tr -d '\r\n' < "$password_file")"
      break
    fi
  done
fi

note() { printf '\033[1;36m[smoke]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[skip]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}

json_field() {
  local field="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$field" '.[$k] // empty'
  else
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$field',''))"
  fi
}

detect_tailnet_login() {
  command -v tailscale >/dev/null 2>&1 || return 1
  local status
  status="$(tailscale status --json 2>/dev/null)" || return 1
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$status" | jq -r '.User[.Self.UserID|tostring].LoginName // empty'
  else
    printf '%s' "$status" | python3 -c \
      'import json,sys; d=json.load(sys.stdin); print(d.get("User",{}).get(str(d.get("Self",{}).get("UserID")),{}).get("LoginName",""))'
  fi
}

cleanup() {
  local rc=$?
  if [ -n "$RELAY_PID" ] && kill -0 "$RELAY_PID" 2>/dev/null; then
    note "stopping daemon pid=$RELAY_PID"
    kill "$RELAY_PID" 2>/dev/null || true
    wait "$RELAY_PID" 2>/dev/null || true
  fi
  if [ -n "$SMOKE_DEVICE_ID" ] && [ -x "${BIN:-}" ]; then
    note "revoking smoke device ${SMOKE_DEVICE_ID:0:12}…"
    HOME="$RUN_HOME" "$BIN" devices revoke "$SMOKE_DEVICE_ID" >/dev/null 2>&1 || true
  fi
  if [ -n "$TMP_ROOT" ]; then
    if [ "$rc" -eq 0 ]; then
      rm -rf "$TMP_ROOT"
    else
      warn "keeping ephemeral smoke logs at ${CFG_DIR}"
    fi
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

require curl
require swift
command -v jq >/dev/null 2>&1 || require python3

if [ -z "$LOGIN_NAME" ]; then
  LOGIN_NAME="$(detect_tailnet_login || true)"
fi
LOGIN_NAME="${LOGIN_NAME:-smoke@local}"

# Phase 0 — seed ~/.cmuxremote/relay.json if absent. Existing files are
# preserved; the operator may have tuned allow_login or apns for their
# tailnet identity. The template's allow_login won't grant register
# unless the operator edits it to include their tailnet LoginName. Use
# SMOKE_EPHEMERAL=1 to generate an isolated config + device store for a
# one-off full smoke.
mkdir -p "$CFG_DIR"
if [ ! -f "$CFG" ]; then
  note "seeding $CFG (edit allow_login to your tailnet login for register)"
  cat > "$CFG" <<EOF
{
  "listen": "${LISTEN_HOST}:${PORT}",
  "allow_login": ["${LOGIN_NAME}"],
  "apns": {
    "key_path": "/dev/null",
    "key_id": "K",
    "team_id": "T",
    "topic": "com.example.smoke",
    "env": "sandbox"
  },
  "snippets": [{"label": "echo", "text": "echo hello"}],
  "default_fps": 15,
  "idle_fps": 5
}
EOF
fi

note "building cmux-relay (debug)"
( cd "$ROOT" && swift build --product cmux-relay ) >/dev/null

BIN="$ROOT/.build/debug/cmux-relay"
[ -x "$BIN" ] || fail "binary not found at $BIN"

note "starting relay daemon on ${LISTEN_HOST}:${PORT}; probing ${CONNECT_HOST}:${PORT}"
HOME="$RUN_HOME" \
  CMUX_SOCKET_PASSWORD="$CMUX_PASSWORD" \
  CMUX_RELAY_UPLOAD_ROOT="${RUN_HOME}/Downloads/cmux-remote" \
  "$BIN" serve --config "$CFG" \
  >"${CFG_DIR}/smoke-stdout.log" 2>"${CFG_DIR}/smoke-stderr.log" &
RELAY_PID=$!

# Phase A — health probe (no auth, no Tailscale needed).
note "waiting for /v1/health"
health_body=$(curl -fsS --retry 15 --retry-connrefused --retry-delay 0 \
  --retry-max-time 15 --connect-timeout 1 --max-time 2 "${BASE}/v1/health") || {
  kill -0 "$RELAY_PID" 2>/dev/null || fail "daemon exited before health came up; see ${CFG_DIR}/smoke-stderr.log"
  fail "health did not become ready; see ${CFG_DIR}/smoke-stderr.log"
}

note "GET /v1/health"
printf '  → %s\n' "$health_body"
case "$health_body" in
  *'"ok":true'*) : ;;
  *) fail "health body not ok=true: $health_body" ;;
esac

# Phase B: register through tailscaled whois. A Tailscale identity outage is
# retryable for the app, but it is a failed full smoke because this run asked
# to prove the complete registration path.
note "POST /v1/devices/me/register"
register_out="${CFG_DIR}/smoke-register.json"
register_code=$(curl -sS -o "$register_out" -w '%{http_code}' \
  -X POST "${BASE}/v1/devices/me/register")
printf '  → HTTP %s\n' "$register_code"

case "$register_code" in
  200)
    note "registered (tailscaled present)"
    TOKEN=$(json_field token < "$register_out")
    SMOKE_DEVICE_ID=$(json_field device_id < "$register_out")
    if [ -z "$TOKEN" ] || [ -z "$SMOKE_DEVICE_ID" ]; then
      fail "register 200 but body missing token/device_id: $(cat "$register_out")"
    fi
    note "  device_id=${SMOKE_DEVICE_ID:0:12}…"
    ;;
  403)
    warn "register 403: the source peer or tailnet login is outside relay policy (login: ${LOGIN_NAME})."
    if [[ "$CONNECT_HOST" == "127."* || "$CONNECT_HOST" == "localhost" ]]; then
      warn "loopback peers are not resolved by tailscaled whois; use the Mac's Tailscale IP for a full smoke."
    fi
    note "smoke OK (health-only)"
    exit 0
    ;;
  503)
    fail "register 503: local Tailscale identity is unavailable; body: $(cat "$register_out")"
    ;;
  500)
    fail "register 500: relay registration failed internally; body: $(cat "$register_out")"
    ;;
  *)
    fail "register returned unexpected HTTP $register_code; body: $(cat "$register_out")"
    ;;
esac

# Phase C: authenticated REST roundtrip with the freshly issued bearer.
note "GET /v1/devices/me"
device_body=$(curl -fsS -H "Authorization: Bearer ${TOKEN}" "${BASE}/v1/devices/me")
printf '  → %s\n' "$device_body"
case "$device_body" in
  *"${SMOKE_DEVICE_ID}"*) : ;;
  *) fail "/v1/devices/me omitted the registered device id: $device_body" ;;
esac

note "GET /v1/state"
state_body=$(curl -fsS -H "Authorization: Bearer ${TOKEN}" "${BASE}/v1/state")
printf '  → %s\n' "$state_body"
case "$state_body" in
  *'"default_fps"'*) : ;;
  *) fail "/v1/state missing default_fps: $state_body" ;;
esac

note "POST /v1/devices/me/apns"
apns_code=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"apns_token":"deadbeef","env":"sandbox"}' \
  -X POST "${BASE}/v1/devices/me/apns")
printf '  → HTTP %s\n' "$apns_code"
[ "$apns_code" = "204" ] || fail "apns expected 204, got $apns_code"

# Phase D — full authenticated relay RPC integration. One websocket stays
# open for malformed requests and each following host.battery liveness check.
if command -v websocat >/dev/null 2>&1; then
  note "WS /v1/ws authenticated file + artifact integration via websocat"
  require python3
  artifact_path="${RUN_HOME}/cmux-smoke-artifact.png"
  python3 - "$artifact_path" <<'PY'
import base64
import pathlib
import sys

png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
pathlib.Path(sys.argv[1]).write_bytes(png)
PY

  python3 "$ROOT/scripts/smoke_relay_ws.py" \
    "${WS_BASE}/v1/ws" \
    "cmuxremote.v1, bearer.${TOKEN}" \
    "$SMOKE_DEVICE_ID" \
    "$artifact_path" \
    "${RUN_HOME}/Downloads/cmux-remote"
else
  note "WS /v1/ws upgrade via curl (no websocat installed)"
  ws_status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
    -H "Connection: Upgrade" \
    -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    -H "Sec-WebSocket-Protocol: cmuxremote.v1, bearer.${TOKEN}" \
    "${BASE}/v1/ws" || true)
  printf '  → HTTP %s\n' "$ws_status"
  [ "$ws_status" = "101" ] || fail "WS upgrade expected 101, got $ws_status (install websocat for full integration coverage)"
fi

note "smoke OK"
