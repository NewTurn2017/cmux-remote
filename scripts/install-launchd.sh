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
Usage: scripts/install-launchd.sh [--dry-run] [--socket <path>] [--sign <identity>]

Options:
  --dry-run          Print resolved paths and rendered plist without building,
                     copying, writing LaunchAgents, or invoking launchctl.
  --socket <path>    Pin cmux-relay to a fixed socket path. Omit to let the
                     relay discover the live cmux socket at runtime.
  --sign <identity>  Code-sign the relay with this keychain identity, e.g.
                     "Developer ID Application: Name (TEAMID)". The choice is
                     remembered in ~/.cmuxremote/codesign-identity. Pass
                     "adhoc" to go back to ad-hoc signing.
                     Also read from CMUX_RELAY_CODESIGN_IDENTITY.

Why sign: an ad-hoc signature changes with every build, so macOS treats each
reinstall as a new app and asks again for Downloads access. Until someone
clicks Allow on the Mac, relay file work (uploads, terminal artifacts) waits.
A stable identity keeps that permission across reinstalls.
USAGE
}

sign_identity_error() {
  echo "--sign requires an identity" >&2
  usage >&2
  exit 2
}

socket_path_error() {
  echo "--socket requires a path" >&2
  usage >&2
  exit 2
}

PIN_SOCKET=""
PIN_SOCKET_SET=0
SIGN_IDENTITY_ARG=""
SIGN_IDENTITY_ARG_SET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --socket)
      [ "$#" -ge 2 ] || socket_path_error
      case "$2" in
        ""|-*) socket_path_error ;;
      esac
      PIN_SOCKET="$2"; PIN_SOCKET_SET=1; shift ;;
    --socket=*)
      PIN_SOCKET="${1#--socket=}"
      case "$PIN_SOCKET" in
        ""|-*) socket_path_error ;;
      esac
      PIN_SOCKET_SET=1 ;;
    --sign)
      [ "$#" -ge 2 ] || sign_identity_error
      case "$2" in
        ""|-*) sign_identity_error ;;
      esac
      SIGN_IDENTITY_ARG="$2"; SIGN_IDENTITY_ARG_SET=1; shift ;;
    --sign=*)
      SIGN_IDENTITY_ARG="${1#--sign=}"
      case "$SIGN_IDENTITY_ARG" in
        ""|-*) sign_identity_error ;;
      esac
      SIGN_IDENTITY_ARG_SET=1 ;;
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
# Leave the socket empty by default so cmux-relay discovers the live cmux
# socket at runtime: it follows cmux's last-socket-path markers (the fixed
# /tmp/cmux-last-socket-path, then ~/.local/state/cmux, then the legacy
# ~/Library/Application Support/cmux) and falls back to ~/.local/state/cmux/cmux.sock.
#
# Pinning is opt-in through --socket. It deliberately does NOT read an ambient
# CMUX_SOCKET_PATH: cmux exports that variable into every process it starts, so
# installing from a cmux terminal — the normal case for this project — would
# silently bake the current socket into the plist and leave the relay pinned to
# a dead path the next time cmux rotates it.
SOCKET=""
if [ "$PIN_SOCKET_SET" -eq 1 ]; then
  SOCKET="$PIN_SOCKET"
fi
SELF_LOGIN_OPT_OUT="${CMUX_NO_SELF_LOGIN:-0}"
DEV_ALLOW_LOCALHOST="${CMUX_DEV_ALLOW_LOCALHOST:-0}"
# launchd starts agents with a stripped PATH; tailscale CLI on macOS lives in
# /usr/local/bin (pkg install), /opt/homebrew/bin (brew), or the Tailscale.app
# bundle, so prepend them before the system defaults for CLI fallback discovery.
RELAY_PATH="${CMUX_RELAY_PATH:-/usr/local/bin:/opt/homebrew/bin:/Applications/Tailscale.app/Contents/MacOS:/usr/bin:/bin:/usr/sbin:/sbin}"
# Code-signing identity: --sign beats CMUX_RELAY_CODESIGN_IDENTITY, which beats
# the identity remembered from an earlier install. "adhoc" (or nothing) keeps
# the ad-hoc signature from swift build.
SIGN_IDENTITY_FILE="$DEST/codesign-identity"
SIGN_IDENTITY_SOURCE="default"
SIGN_IDENTITY=""
if [ "$SIGN_IDENTITY_ARG_SET" -eq 1 ]; then
  SIGN_IDENTITY="$SIGN_IDENTITY_ARG"; SIGN_IDENTITY_SOURCE="--sign"
elif [ -n "${CMUX_RELAY_CODESIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$CMUX_RELAY_CODESIGN_IDENTITY"; SIGN_IDENTITY_SOURCE="CMUX_RELAY_CODESIGN_IDENTITY"
elif [ -f "$SIGN_IDENTITY_FILE" ]; then
  SIGN_IDENTITY="$(head -n 1 "$SIGN_IDENTITY_FILE")"; SIGN_IDENTITY_SOURCE="$SIGN_IDENTITY_FILE"
fi
if [ "$SIGN_IDENTITY" = "adhoc" ]; then
  SIGN_IDENTITY=""
fi
SIGN_IDENTIFIER="$LABEL.relay"
LAUNCH_AGENTS_DIR="${CMUX_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
TARGET="gui/$(id -u)"
SERVICE="$TARGET/$LABEL"

note() { printf '[install-launchd] %s\n' "$*"; }
fail() { printf '[install-launchd] ERROR: %s\n' "$*" >&2; exit 1; }

if [ "$PIN_SOCKET_SET" -eq 0 ] && [ -n "${CMUX_SOCKET_PATH:-}" ]; then
  note "ignoring ambient CMUX_SOCKET_PATH=$CMUX_SOCKET_PATH"
  note "  (cmux exports it to processes it starts; pinning would break on socket rotation)"
  note "  pass --socket '$CMUX_SOCKET_PATH' if you really want to pin it"
fi

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
    -e "s|__NO_SELF_LOGIN__|$(render_token "$SELF_LOGIN_OPT_OUT")|g" \
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
  if [ -f "$CONFIG" ]; then
    note "config: $CONFIG (exists)"
  else
    note "config: $CONFIG (would write default relay.json)"
  fi
  if [ -n "$SOCKET" ]; then
    note "socket override: $SOCKET"
  else
    note "socket override: <dynamic via cmux last-socket-path>"
  fi
  note "logdir: $LOGDIR"
  if [ -n "$SIGN_IDENTITY" ]; then
    note "codesign identity: $SIGN_IDENTITY (from $SIGN_IDENTITY_SOURCE)"
  else
    note "codesign identity: adhoc (macOS asks for Downloads access again after each reinstall)"
  fi
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

# First-run convenience: if there is no config yet, write a sane default so a
# brand-new user does not have to hand-author relay.json before the first
# install. Existing configs are never touched.
if [ ! -f "$CONFIG" ]; then
  note "no config at $CONFIG; writing default relay.json"
  mkdir -p "$(dirname "$CONFIG")"
  cat > "$CONFIG" <<'JSON'
{
  "listen":      "0.0.0.0:4399",
  "default_fps": 15,
  "idle_fps":    5
}
JSON
  note "this Mac's own tailnet login is auto-authorised, so a phone on the"
  note "  same Tailscale account pairs out of the box. For other accounts, add"
  note "  the login to \"allow_login\" in $CONFIG (CMUX_NO_SELF_LOGIN=1 to opt out)."
fi

note "building release binary"
(cd "$ROOT" && swift build -c release)
[ -x "$BIN_SRC" ] || fail "release binary not found after build: $BIN_SRC"

note "installing binary and logs under $DEST"
mkdir -p "$DEST/bin" "$LOGDIR" "$LAUNCH_AGENTS_DIR"
# Replace the binary by rename, never in place: overwriting the file the
# running relay was launched from invalidates its code signature, and macOS
# then kills it and refuses relaunch (OS_REASON_CODESIGNING).
cp "$BIN_SRC" "$BIN_DEST.new"
chmod 755 "$BIN_DEST.new"
if [ -n "$SIGN_IDENTITY" ]; then
  command -v codesign >/dev/null 2>&1 || fail "missing required tool: codesign"
  note "signing with: $SIGN_IDENTITY (from $SIGN_IDENTITY_SOURCE)"
  codesign --force --timestamp=none --identifier "$SIGN_IDENTIFIER" \
    --sign "$SIGN_IDENTITY" "$BIN_DEST.new" \
    || { rm -f "$BIN_DEST.new"; fail "codesign failed for identity: $SIGN_IDENTITY"; }
  codesign --verify --strict "$BIN_DEST.new" \
    || { rm -f "$BIN_DEST.new"; fail "codesign verification failed"; }
else
  note "keeping the ad-hoc signature; macOS will ask again for Downloads access"
  note "  (pass --sign \"Developer ID Application: …\" once to keep it across reinstalls)"
fi
mv -f "$BIN_DEST.new" "$BIN_DEST"
if [ "$SIGN_IDENTITY_ARG_SET" -eq 1 ]; then
  if [ -n "$SIGN_IDENTITY" ]; then
    printf '%s\n' "$SIGN_IDENTITY" > "$SIGN_IDENTITY_FILE"
  else
    rm -f "$SIGN_IDENTITY_FILE"
  fi
fi

note "rendering $PLIST"
render_plist > "$PLIST"
validate_rendered_plist

note "bootstrapping $LABEL"
launchctl bootout "$TARGET" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "$TARGET" "$PLIST"
launchctl kickstart -k "$SERVICE"

note "installed; logs at $LOGDIR"
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY_SOURCE" != "$SIGN_IDENTITY_FILE" ]; then
  note "first install with this identity: allow Downloads access once if macOS asks"
fi
note "inspect with: launchctl print $SERVICE"
