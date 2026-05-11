#!/usr/bin/env bash
# Live integration smoke for cmux-relay.
#
# Boots the daemon against ~/.cmuxremote/relay.json, then walks the wire
# protocol from the outside: /v1/health, /v1/devices/me/register,
# /v1/state, /v1/devices/me/apns, and a /v1/ws upgrade with a hello
# frame. Phases that depend on tailscaled or websocat skip gracefully
# instead of failing so the operator can still see health pass on a
# bare box.
#
# Run from a checkout root: `bash scripts/smoke-relay.sh`.
# Requires: curl, swift, jq or python3. Optional: websocat (WS test).
# Not run in CI — cmux daemon and Tailscale are operator-side deps.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="127.0.0.1"
PORT="4399"
BASE="http://${HOST}:${PORT}"
WS_BASE="ws://${HOST}:${PORT}"
CFG_DIR="${HOME}/.cmuxremote"
CFG="${CFG_DIR}/relay.json"
LOGIN_NAME="${SMOKE_LOGIN:-smoke@local}"
SMOKE_DEVICE_ID=""
RELAY_PID=""

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

cleanup() {
  local rc=$?
  if [ -n "$RELAY_PID" ] && kill -0 "$RELAY_PID" 2>/dev/null; then
    note "stopping daemon pid=$RELAY_PID"
    kill "$RELAY_PID" 2>/dev/null || true
    wait "$RELAY_PID" 2>/dev/null || true
  fi
  if [ -n "$SMOKE_DEVICE_ID" ] && [ -x "${BIN:-}" ]; then
    note "revoking smoke device ${SMOKE_DEVICE_ID:0:12}…"
    "$BIN" devices revoke "$SMOKE_DEVICE_ID" >/dev/null 2>&1 || true
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

require curl
require swift
command -v jq >/dev/null 2>&1 || require python3

# Phase 0 — seed ~/.cmuxremote/relay.json if absent. Existing files are
# preserved; the operator may have tuned allow_login or apns for their
# tailnet identity. The template's allow_login won't grant register
# unless the operator edits it to include their tailnet LoginName.
mkdir -p "$CFG_DIR"
if [ ! -f "$CFG" ]; then
  note "seeding $CFG (edit allow_login to your tailnet login for register)"
  cat > "$CFG" <<EOF
{
  "listen": "${HOST}:${PORT}",
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

note "starting relay daemon on ${HOST}:${PORT}"
"$BIN" serve --config "$CFG" \
  >"${CFG_DIR}/smoke-stdout.log" 2>"${CFG_DIR}/smoke-stderr.log" &
RELAY_PID=$!

# Phase A — health probe (no auth, no Tailscale needed).
note "waiting for /v1/health"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS "${BASE}/v1/health" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$RELAY_PID" 2>/dev/null; then
    fail "daemon exited before health came up; see ${CFG_DIR}/smoke-stderr.log"
  fi
  sleep 0.5
done

note "GET /v1/health"
health_body=$(curl -fsS "${BASE}/v1/health")
printf '  → %s\n' "$health_body"
case "$health_body" in
  *'"ok":true'*) : ;;
  *) fail "health body not ok=true: $health_body" ;;
esac

# Phase B — register (needs tailscaled whois). Treat 403/500 as SKIP so
# this script still demonstrates daemon liveness on boxes outside the
# tailnet or with a tailnet login that isn't in allow_login.
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
    warn "register 403 — your tailnet login isn't in allow_login (current: ${LOGIN_NAME}). Edit ${CFG} and rerun."
    note "smoke OK (health-only)"
    exit 0
    ;;
  500)
    warn "register 500 — tailscaled likely not running. Start Tailscale and rerun."
    note "smoke OK (health-only)"
    exit 0
    ;;
  *)
    fail "register returned unexpected HTTP $register_code; body: $(cat "$register_out")"
    ;;
esac

# Phase C — authenticated REST roundtrip with the freshly-issued bearer.
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

# Phase D — WS upgrade + hello frame. websocat is the cleanest tool; if
# absent, fall back to a raw-curl 101-handshake probe so we at least
# verify Sec-WebSocket-Protocol bearer parsing.
if command -v websocat >/dev/null 2>&1; then
  note "WS /v1/ws upgrade + hello via websocat"
  hello=$(printf '{"deviceId":"%s","appVersion":"smoke-1.0","protocolVersion":1}' \
          "$SMOKE_DEVICE_ID")
  # -n1 sends one line and exits; --protocol sets Sec-WebSocket-Protocol.
  # We don't strictly need a response — server attaches the session on
  # hello and starts the FPS clock. Capturing stderr in case the upgrade
  # gets rejected.
  ws_out=$(printf '%s\n' "$hello" \
    | websocat --protocol "cmuxremote.v1, bearer.${TOKEN}" -n1 -t "${WS_BASE}/v1/ws" 2>&1 \
    || true)
  if [ -n "$ws_out" ]; then
    printf '  → WS first message: %s\n' "$(printf '%s' "$ws_out" | head -c 200)"
  else
    note "  WS upgrade OK (no inbound text; expected when cmux daemon isn't running)"
  fi
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
  [ "$ws_status" = "101" ] || fail "WS upgrade expected 101, got $ws_status (install websocat for hello-frame coverage)"
fi

note "smoke OK"
