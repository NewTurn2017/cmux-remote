#!/usr/bin/env bash
# Install cmux-relay as a per-user launchd agent.
#
# Default mode builds the release binary, copies it into ~/.cmuxremote/bin,
# renders ~/Library/LaunchAgents/com.genie.cmuxremote.plist, then bootstraps
# and kickstarts the agent. Use --dry-run to validate/render without writes or
# launchctl side effects.

set -euo pipefail

LABEL="com.genie.cmuxremote"
DRY_RUN=0

usage() {
  cat <<USAGE
Usage: scripts/install-launchd.sh [--dry-run]

Options:
  --dry-run   Print resolved paths and rendered plist without building,
              copying, writing LaunchAgents, or invoking launchctl.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/scripts/relay.plist.tmpl"
DEST="${CMUX_REMOTE_HOME:-$HOME/.cmuxremote}"
BIN_SRC="$ROOT/.build/release/cmux-relay"
BIN_DEST="$DEST/bin/cmux-relay"
CONFIG="${CMUX_RELAY_CONFIG:-$DEST/relay.json}"
LOGDIR="${CMUX_RELAY_LOGDIR:-$DEST/log}"
SOCKET="${CMUX_SOCKET_PATH:-$HOME/Library/Application Support/cmux/cmux.sock}"
DEV_ALLOW_LOCALHOST="${CMUX_DEV_ALLOW_LOCALHOST:-0}"
# launchd starts agents with a stripped PATH; tailscale CLI on macOS lives in
# /usr/local/bin (pkg install) or /opt/homebrew/bin (brew), so prepend both
# before the system defaults so AuthService's whois fallback can find it.
RELAY_PATH="${CMUX_RELAY_PATH:-/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
LAUNCH_AGENTS_DIR="${CMUX_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
TARGET="gui/$(id -u)"
SERVICE="$TARGET/$LABEL"

note() { printf '[install-launchd] %s\n' "$*"; }
fail() { printf '[install-launchd] ERROR: %s\n' "$*" >&2; exit 1; }

sed_escape() {
  # Escape replacement text for sed's s||| delimiter.
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

xml_escape() {
  # Escape token values before placing them inside plist XML text nodes.
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

render_token() {
  sed_escape "$(xml_escape "$1")"
}

render_plist() {
  sed \
    -e "s|__BIN__|$(render_token "$BIN_DEST")|g" \
    -e "s|__CONFIG__|$(render_token "$CONFIG")|g" \
    -e "s|__SOCKET__|$(render_token "$SOCKET")|g" \
    -e "s|__LOGDIR__|$(render_token "$LOGDIR")|g" \
    -e "s|__DEV_ALLOW_LOCALHOST__|$(render_token "$DEV_ALLOW_LOCALHOST")|g" \
    -e "s|__RELAY_PATH__|$(render_token "$RELAY_PATH")|g" \
    "$TEMPLATE"
}

validate_rendered_plist() {
  local tmp rc
  tmp="$(mktemp)"
  render_plist > "$tmp"
  if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$tmp" >/dev/null; then
      rc=0
    else
      rc=$?
    fi
  else
    rc=0
  fi
  rm -f "$tmp"
  return "$rc"
}

[ -f "$TEMPLATE" ] || fail "missing plist template: $TEMPLATE"

if [ "$DRY_RUN" -eq 1 ]; then
  note "dry-run; no build, copy, writes, or launchctl calls"
  note "label: $LABEL"
  note "binary: $BIN_DEST"
  note "config: $CONFIG"
  note "socket: $SOCKET"
  note "logdir: $LOGDIR"
  note "plist: $PLIST"
  note "would run: swift build -c release"
  note "would copy: $BIN_SRC -> $BIN_DEST"
  note "would run: launchctl bootstrap $TARGET $PLIST"
  note "would run: launchctl kickstart -k $SERVICE"
  printf '%s\n' '--- rendered plist ---'
  render_plist
  validate_rendered_plist
  exit 0
fi

command -v swift >/dev/null 2>&1 || fail "missing required tool: swift"
command -v launchctl >/dev/null 2>&1 || fail "missing required tool: launchctl"
[ -f "$CONFIG" ] || fail "missing config: $CONFIG (create ~/.cmuxremote/relay.json first)"

note "building release binary"
(cd "$ROOT" && swift build -c release)
[ -x "$BIN_SRC" ] || fail "release binary not found after build: $BIN_SRC"

note "installing binary and logs under $DEST"
mkdir -p "$DEST/bin" "$LOGDIR" "$LAUNCH_AGENTS_DIR"
cp "$BIN_SRC" "$BIN_DEST"
chmod 755 "$BIN_DEST"

note "rendering $PLIST"
render_plist > "$PLIST"
validate_rendered_plist

note "bootstrapping $LABEL"
launchctl bootout "$TARGET" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "$TARGET" "$PLIST"
launchctl kickstart -k "$SERVICE"

note "installed; logs at $LOGDIR"
note "inspect with: launchctl print $SERVICE"
