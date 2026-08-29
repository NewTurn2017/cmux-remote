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
HOME="$RUN_HOME" CMUX_RELAY_UPLOAD_ROOT="${RUN_HOME}/Downloads/cmux-remote" \
  "$BIN" serve --config "$CFG" \
  >"${CFG_DIR}/smoke-stdout.log" 2>"${CFG_DIR}/smoke-stderr.log" &
RELAY_PID=$!

# Phase A — health probe (no auth, no Tailscale needed).
note "waiting for /v1/health"
health_body=$(curl -fsS --retry 20 --retry-connrefused --retry-delay 0 --connect-timeout 1 --max-time 15 "${BASE}/v1/health") || {
  kill -0 "$RELAY_PID" 2>/dev/null || fail "daemon exited before health came up; see ${CFG_DIR}/smoke-stderr.log"
  fail "health did not become ready; see ${CFG_DIR}/smoke-stderr.log"
}

note "GET /v1/health"
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
    if [[ "$CONNECT_HOST" == "127."* || "$CONNECT_HOST" == "localhost" ]]; then
      warn "loopback peers are not resolved by tailscaled whois; for full smoke use SMOKE_EPHEMERAL=1 SMOKE_LISTEN_HOST=0.0.0.0 SMOKE_CONNECT_HOST=\"\$(tailscale ip -4 | head -1)\"."
    fi
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

  python3 - \
    "${WS_BASE}/v1/ws" \
    "cmuxremote.v1, bearer.${TOKEN}" \
    "$SMOKE_DEVICE_ID" \
    "$artifact_path" \
    "${RUN_HOME}/Downloads/cmux-remote" <<'PY'
import base64
import hashlib
import json
import os
import queue
import shlex
import subprocess
import sys
import threading
import time
import uuid

url, protocol, device_id, artifact_path, upload_root = sys.argv[1:6]
next_id = 0
proc = None
events = None
pushes = []
hello = {"deviceId": device_id, "appVersion": "smoke-1.0", "protocolVersion": 1}


def collect(stream, event_queue, kind):
    for line in stream:
        event_queue.put((kind, line))


def close_socket():
    global proc
    if proc is None:
        return
    if proc.stdin:
        proc.stdin.close()
    proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    proc = None


def reconnect():
    global proc, events
    close_socket()
    proc = subprocess.Popen(
        ["websocat", "--protocol", protocol, "-n", "-t", "-B", "2000000", url],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    events = queue.Queue()
    threading.Thread(target=collect, args=(proc.stdout, events, "stdout"), daemon=True).start()
    threading.Thread(target=collect, args=(proc.stderr, events, "stderr"), daemon=True).start()
    send(hello)


def send(value):
    proc.stdin.write(json.dumps(value, separators=(",", ":")) + "\n")
    proc.stdin.flush()


def exchange(requests):
    expected = {request["id"] for request in requests}
    responses = {}
    for request in requests:
        send(request)
    deadline = time.monotonic() + 15
    while expected:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("timed out waiting for websocket state")
        try:
            kind, line = events.get(timeout=remaining)
        except queue.Empty as error:
            raise RuntimeError("timed out waiting for websocket state") from error
        if kind == "stderr":
            raise RuntimeError("websocat: " + line.strip())
        try:
            message = json.loads(line)
        except json.JSONDecodeError as error:
            raise RuntimeError("non-JSON websocket output: " + line.strip()) from error
        message_id = message.get("id")
        if message_id in expected:
            responses[message_id] = message
            expected.remove(message_id)
        else:
            pushes.append(message)
    return list(responses.values())


def call(method, params):
    global next_id
    next_id += 1
    request_id = "smoke-" + str(next_id)
    request = {"id": request_id, "method": method, "params": params}
    for message in exchange([request]):
        if message.get("id") == request_id:
            return message
    raise RuntimeError("missing websocket response for " + method)


def require_ok(response, context):
    if response.get("error") is not None or response.get("ok") is False:
        raise RuntimeError(context + ": " + json.dumps(response, sort_keys=True))
    return response.get("result", {})


def require_error_with_liveness(method, params, code, data, context):
    global next_id
    next_id += 1
    malformed_id = "smoke-" + str(next_id)
    next_id += 1
    battery_id = "smoke-" + str(next_id)
    messages = exchange([
        {"id": malformed_id, "method": method, "params": params},
        {"id": battery_id, "method": "host.battery", "params": {}},
    ])
    responses = {message.get("id"): message for message in messages if "id" in message}
    malformed = responses.get(malformed_id, {})
    actual = (malformed.get("error") or {}).get("code")
    actual_data = (malformed.get("error") or {}).get("data")
    if actual != code or actual_data != data:
        raise RuntimeError(
            f"{context}: expected code={code} data={data!r}, got {json.dumps(malformed, sort_keys=True)}"
        )
    battery = require_ok(responses.get(battery_id, {}), context + " liveness")
    if "level" not in battery and "state" not in battery:
        raise RuntimeError(context + " liveness returned malformed battery payload")


def begin(data, digest, filename, batch_id=None, file_count=1, batch_bytes=None):
    if batch_id is None:
        batch_id = str(uuid.uuid4())
    if batch_bytes is None:
        batch_bytes = len(data)
    result = require_ok(call("file.upload.begin", {
        "batch_id": batch_id,
        "filename": filename,
        "mime_type": "application/octet-stream",
        "bytes": len(data),
        "sha256": digest,
        "batch_file_count": file_count,
        "batch_bytes": batch_bytes,
    }), "upload begin")
    if result.get("batch_id") != batch_id:
        raise RuntimeError("upload begin did not echo stable batch_id")
    return result["upload_id"]


created_workspace_id = None
try:
    reconnect()
    capabilities = require_ok(call("host.capabilities", {}), "host.capabilities").get("capabilities", [])
    if capabilities != ["file.upload.v2", "terminal.artifact.v1"]:
        raise RuntimeError("unexpected relay capabilities: " + repr(capabilities))

    upload_data = (b"cmux-upload-chunk-" * 1800) + b"tail"
    upload_hash = hashlib.sha256(upload_data).hexdigest()
    upload_id = begin(upload_data, upload_hash, "smoke-upload.bin")
    offset = 0
    for raw in (upload_data[:16 * 1024], upload_data[16 * 1024:]):
        result = require_ok(call("file.upload.chunk", {
            "upload_id": upload_id,
            "offset": offset,
            "data_base64": base64.b64encode(raw).decode("ascii"),
        }), "upload chunk")
        offset = result["next_offset"]
    committed = require_ok(call("file.upload.commit", {"upload_id": upload_id}), "upload commit")
    committed_path = committed["path"]
    if committed["bytes"] != len(upload_data) or committed["sha256"] != upload_hash:
        raise RuntimeError("committed upload metadata mismatch")
    if open(committed_path, "rb").read() != upload_data:
        raise RuntimeError("committed upload bytes mismatch")

    malformed_data = b"cancel-me"
    malformed_id = begin(malformed_data, hashlib.sha256(malformed_data).hexdigest(), "cancel.bin")
    require_error_with_liveness("file.upload.chunk", {
        "upload_id": malformed_id, "offset": 0, "data_base64": "%%%",
    }, "invalid_base64", {"field": "data_base64"}, "malformed base64")
    require_error_with_liveness("file.upload.chunk", {
        "upload_id": malformed_id, "offset": 1,
        "data_base64": base64.b64encode(malformed_data).decode("ascii"),
    }, "invalid_offset", {"field": "offset"}, "wrong offset")
    require_ok(call("file.upload.cancel", {"upload_id": malformed_id}), "upload cancel")
    require_error_with_liveness("file.upload.chunk", {
        "upload_id": malformed_id, "offset": 0,
        "data_base64": base64.b64encode(malformed_data).decode("ascii"),
    }, "upload_not_found", None, "cancelled upload")

    wrong_hash_data = b"wrong-hash"
    wrong_hash_id = begin(wrong_hash_data, "0" * 64, "wrong-hash.bin")
    require_ok(call("file.upload.chunk", {
        "upload_id": wrong_hash_id, "offset": 0,
        "data_base64": base64.b64encode(wrong_hash_data).decode("ascii"),
    }), "wrong hash chunk")
    require_error_with_liveness(
        "file.upload.commit", {"upload_id": wrong_hash_id}, "hash_mismatch", None, "wrong hash"
    )

    empty_hash = hashlib.sha256(b"").hexdigest()
    reconnect_batch_id = str(uuid.uuid4())
    reconnect_committed_paths = []
    for index in range(10):
        reconnect()
        reconnect_upload_id = begin(
            b"", empty_hash, f"reconnect-{index}.bin",
            batch_id=reconnect_batch_id, file_count=10, batch_bytes=0,
        )
        reconnect_result = require_ok(call(
            "file.upload.commit", {"upload_id": reconnect_upload_id}
        ), "reconnect upload commit")
        reconnect_committed_paths.append(reconnect_result["path"])
    reconnect()
    require_error_with_liveness("file.upload.begin", {
        "batch_id": reconnect_batch_id,
        "filename": "eleventh.bin",
        "mime_type": "application/octet-stream",
        "bytes": 0,
        "sha256": empty_hash,
        "batch_file_count": 10,
        "batch_bytes": 0,
    }, "size_limit_exceeded", {"field": "batch_file_count"}, "eleventh reconnect begin")
    require_error_with_liveness("file.upload.begin", {
        "batch_id": reconnect_batch_id,
        "filename": "conflicting-total.bin",
        "mime_type": "application/octet-stream",
        "bytes": 0,
        "sha256": empty_hash,
        "batch_file_count": 9,
        "batch_bytes": 0,
    }, "upload_conflict", {"field": "batch_id"}, "conflicting batch totals")

    aggregate_batch_id = str(uuid.uuid4())
    aggregate_upload_ids = []
    for index, declared_bytes in enumerate((100 * 1024 * 1024, 100 * 1024 * 1024, 50 * 1024 * 1024)):
        reconnect()
        aggregate_result = require_ok(call("file.upload.begin", {
            "batch_id": aggregate_batch_id,
            "filename": f"aggregate-{index}.bin",
            "mime_type": "application/octet-stream",
            "bytes": declared_bytes,
            "sha256": empty_hash,
            "batch_file_count": 4,
            "batch_bytes": 250 * 1024 * 1024,
        }), "aggregate begin")
        if aggregate_result.get("batch_id") != aggregate_batch_id:
            raise RuntimeError("aggregate begin did not echo stable batch_id")
        aggregate_upload_ids.append(aggregate_result["upload_id"])
    reconnect()
    require_error_with_liveness("file.upload.begin", {
        "batch_id": aggregate_batch_id,
        "filename": "aggregate-overflow.bin",
        "mime_type": "application/octet-stream",
        "bytes": 1,
        "sha256": empty_hash,
        "batch_file_count": 4,
        "batch_bytes": 250 * 1024 * 1024,
    }, "size_limit_exceeded", {"field": "batch_bytes"}, "aggregate bytes across reconnects")
    for aggregate_upload_id in aggregate_upload_ids:
        require_ok(call("file.upload.cancel", {"upload_id": aggregate_upload_id}), "aggregate cleanup")
    print("UPLOAD_CHUNK_OK", flush=True)

    created = require_ok(call("workspace.create", {
        "title": "cmux-relay-smoke-" + uuid.uuid4().hex[:8],
    }), "workspace.create")
    workspace = created.get("workspace", created)
    workspace_id = workspace.get("id") or workspace.get("workspace_id")
    if not workspace_id:
        raise RuntimeError("workspace.create omitted workspace id: " + json.dumps(created, sort_keys=True))
    created_workspace_id = workspace_id
    surface_result = require_ok(call("surface.create", {
        "workspace_id": workspace_id, "type": "terminal", "focus": True,
    }), "surface.create")
    surface_id = surface_result.get("surface_id") or surface_result.get("surface", {}).get("id")
    if not surface_id:
        raise RuntimeError("surface.create omitted surface_id: " + json.dumps(surface_result, sort_keys=True))
    require_ok(call("surface.subscribe", {
        "workspace_id": workspace_id, "surface_id": surface_id, "lines": 200,
    }), "surface.subscribe")
    require_ok(call("surface.focus", {
        "workspace_id": workspace_id, "surface_id": surface_id,
    }), "surface.focus")
    pushes.clear()
    command = "printf '%s\\n' " + shlex.quote(artifact_path)
    require_ok(call("surface.send_text", {
        "workspace_id": workspace_id, "surface_id": surface_id, "text": command,
    }), "surface.send_text")
    require_ok(call("surface.send_key", {
        "workspace_id": workspace_id, "surface_id": surface_id, "key": "enter",
    }), "surface.send_key")
    deadline = time.monotonic() + 10
    while not any(artifact_path in json.dumps(push, ensure_ascii=False) for push in pushes):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("artifact path did not reach a pushed terminal screen row")
        try:
            kind, line = events.get(timeout=remaining)
        except queue.Empty as error:
            raise RuntimeError("timed out waiting for terminal update") from error
        if kind == "stderr":
            raise RuntimeError("websocat: " + line.strip())
        message = json.loads(line)
        if "id" not in message:
            pushes.append(message)
    scan = require_ok(call("terminal.artifact.scan", {
        "workspace_id": workspace_id, "surface_id": surface_id,
    }), "terminal.artifact.scan")
    artifacts = scan.get("artifacts", [])
    artifact = next((item for item in artifacts if item.get("filename") == os.path.basename(artifact_path)), None)
    if artifact is None:
        raise RuntimeError("terminal-visible PNG was not authorized: " + json.dumps(scan, sort_keys=True))
    artifact_id = artifact["artifact_id"]

    require_error_with_liveness(
        "terminal.artifact.stat",
        {"artifact_id": str(uuid.uuid4())},
        "forbidden",
        {"field": "artifact_id"},
        "unauthorized artifact"
    )
    stat = require_ok(call("terminal.artifact.stat", {"artifact_id": artifact_id}), "artifact stat")
    thumbnail = require_ok(call("terminal.artifact.thumbnail", {
        "artifact_id": artifact_id, "dimension": 512,
    }), "artifact thumbnail")
    thumbnail_bytes = base64.b64decode(thumbnail["data_base64"], validate=True)
    if not thumbnail_bytes.startswith(b"\xff\xd8") or thumbnail["mime_type"] != "image/jpeg":
        raise RuntimeError("artifact thumbnail was not a JPEG")
    fetched = require_ok(call("terminal.artifact.fetch", {
        "artifact_id": artifact_id, "offset": 0,
    }), "artifact fetch")
    fetched_bytes = base64.b64decode(fetched["data_base64"], validate=True)
    expected_bytes = open(artifact_path, "rb").read()
    if fetched_bytes != expected_bytes or not fetched["eof"] or stat["bytes"] != len(expected_bytes):
        raise RuntimeError("artifact fetch/stat mismatch")
    print("ARTIFACT_FALLBACK_OK", flush=True)

    os.unlink(committed_path)
    for reconnect_committed_path in reconnect_committed_paths:
        os.unlink(reconnect_committed_path)
    os.unlink(artifact_path)
    uploads = os.path.join(upload_root, ".uploads")
    if os.path.isdir(uploads) and os.listdir(uploads):
        raise RuntimeError("temporary upload residue remains: " + repr(os.listdir(uploads)))
    require_ok(call("host.battery", {}), "final liveness")
    print("SMOKE_FULL_INTEGRATION_OK", flush=True)
finally:
    if created_workspace_id is not None:
        try:
            require_ok(call("workspace.close", {"workspace_id": created_workspace_id}), "workspace.close")
        except Exception as cleanup_error:
            print("workspace cleanup failed: " + str(cleanup_error), file=sys.stderr)
    close_socket()
PY
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
