#!/usr/bin/env bash
# Install cmux-relay as a per-user launchd agent.
#
# Default mode builds the release binary, copies it into ~/.cmuxremote/bin,
# renders ~/Library/LaunchAgents/com.genie.cmuxremote.plist, then bootstraps
# and kickstarts the agent. Use --dry-run to validate/render without writes or
# launchctl side effects.
#
# It also installs the updater agent com.genie.cmuxremote.updater, which follows
# the release tags vX.Y.Z of the update origin (see scripts/relay-update.sh), unless
# --no-auto-update is given; that choice is remembered in ~/.cmuxremote/update.
#
# INTERNAL STABLE INTERFACE: `install-launchd.sh --apply-staged <dir>` installs a
# release the updater built and staged. Every future release keeps this option and
# the staged layout (<dir>/cmux-relay, <dir>/manifest.json, <dir>/scripts/). It never
# touches the updater job itself, because it runs inside that job.

set -euo pipefail

LABEL="com.genie.cmuxremote"
DRY_RUN=0

usage() {
  cat <<USAGE
Usage: scripts/install-launchd.sh [--dry-run] [--socket <path>] [--sign <identity>]
                                  [--no-auto-update | --auto-update] [--update-origin <url>]

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
  --no-auto-update   Do not install the updater; relay.info reports "disabled".
                     Remembered until --auto-update is given.
  --auto-update      Install the updater again after --no-auto-update (default).
  --update-origin <url>
                     https:// git URL whose vX.Y.Z tags the updater follows.
                     Default: https://github.com/NewTurn2017/cmux-remote.git
                     Also read from CMUX_RELAY_UPDATE_ORIGIN.

Auto-update: the updater checks the origin's release tags once an hour, builds a
newer release in ~/.cmuxremote/src/cmux-remote, signs it with the remembered
identity, and restarts the relay only after no phone has been connected for two
minutes ("Update now" in the app applies at once). Log: ~/.cmuxremote/log/update.log.

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

update_origin_error() {
  echo "--update-origin requires an https:// git URL" >&2
  usage >&2
  exit 2
}

apply_staged_error() {
  echo "--apply-staged requires a staged update directory" >&2
  exit 2
}

PIN_SOCKET=""
PIN_SOCKET_SET=0
SIGN_IDENTITY_ARG=""
SIGN_IDENTITY_ARG_SET=0
AUTO_UPDATE_ARG=""
UPDATE_ORIGIN_ARG=""
APPLY_STAGED=""

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
    --no-auto-update) AUTO_UPDATE_ARG=0 ;;
    --auto-update) AUTO_UPDATE_ARG=1 ;;
    --update-origin)
      [ "$#" -ge 2 ] || update_origin_error
      case "$2" in
        ""|-*) update_origin_error ;;
      esac
      UPDATE_ORIGIN_ARG="$2"; shift ;;
    --update-origin=*)
      UPDATE_ORIGIN_ARG="${1#--update-origin=}"
      case "$UPDATE_ORIGIN_ARG" in
        ""|-*) update_origin_error ;;
      esac ;;
    --apply-staged)
      [ "$#" -ge 2 ] || apply_staged_error
      case "$2" in
        ""|-*) apply_staged_error ;;
      esac
      APPLY_STAGED="$2"; shift ;;
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
LAUNCHCTL="${CMUX_RELAY_LAUNCHCTL:-launchctl}"
CODESIGN="${CMUX_RELAY_CODESIGN:-codesign}"
BUILD_CMD="${CMUX_RELAY_BUILD_CMD:-swift build -c release}"
TEST_MODE="${CMUX_RELAY_UPDATE_TEST:-0}"

UPDATER_LABEL="$LABEL.updater"
UPDATER_SERVICE="$TARGET/$UPDATER_LABEL"
UPDATER_SRC="$ROOT/scripts/relay-update.sh"
UPDATER_TEMPLATE="$ROOT/scripts/relay-updater.plist.tmpl"
UPDATER_DEST="$DEST/libexec/relay-update.sh"
UPDATER_PLIST="$LAUNCH_AGENTS_DIR/$UPDATER_LABEL.plist"
UPDATE_DIR="$DEST/update"
UPDATE_CONFIG="$UPDATE_DIR/config.json"
DEFAULT_UPDATE_ORIGIN="https://github.com/NewTurn2017/cmux-remote.git"

json_get() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

# Auto-update: --no-auto-update/--auto-update beat the choice remembered in
# update/config.json; a first install turns it on.
AUTO_UPDATE=1
AUTO_UPDATE_SOURCE="default"
if [ -n "$AUTO_UPDATE_ARG" ]; then
  AUTO_UPDATE="$AUTO_UPDATE_ARG"
  if [ "$AUTO_UPDATE" -eq 1 ]; then AUTO_UPDATE_SOURCE="--auto-update"; else AUTO_UPDATE_SOURCE="--no-auto-update"; fi
elif [ -f "$UPDATE_CONFIG" ] && [ "$(json_get "$UPDATE_CONFIG" auto_update)" = "false" ]; then
  AUTO_UPDATE=0
  AUTO_UPDATE_SOURCE="$UPDATE_CONFIG"
fi
UPDATE_ORIGIN="$DEFAULT_UPDATE_ORIGIN"
if [ -n "$UPDATE_ORIGIN_ARG" ]; then
  UPDATE_ORIGIN="$UPDATE_ORIGIN_ARG"
elif [ -n "${CMUX_RELAY_UPDATE_ORIGIN:-}" ]; then
  UPDATE_ORIGIN="$CMUX_RELAY_UPDATE_ORIGIN"
elif [ -f "$UPDATE_CONFIG" ] && [ -n "$(json_get "$UPDATE_CONFIG" origin)" ]; then
  UPDATE_ORIGIN="$(json_get "$UPDATE_CONFIG" origin)"
fi
case "$UPDATE_ORIGIN" in
  *'"'*|*\\*|*' '*) update_origin_error ;;
  https://*) ;;
  file://*|/*) [ "$TEST_MODE" = "1" ] || update_origin_error ;;
  *) update_origin_error ;;
esac
# launchd starts the updater with a bare PATH; keep the swift that built this install.
UPDATER_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
SWIFT_BIN="$(command -v swift 2>/dev/null || true)"
case "$SWIFT_BIN" in
  ""|/usr/bin/swift) ;;
  *) UPDATER_PATH="$(dirname "$SWIFT_BIN"):$UPDATER_PATH" ;;
esac

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
    -e "s|__DEST__|$(render_token "$DEST")|g" \
    "$TEMPLATE"
}

render_updater_plist() {
  sed \
    -e "s|__UPDATER__|$(render_token "$UPDATER_DEST")|g" \
    -e "s|__DEST__|$(render_token "$DEST")|g" \
    -e "s|__LOGDIR__|$(render_token "$LOGDIR")|g" \
    -e "s|__LAUNCH_AGENTS_DIR__|$(render_token "$LAUNCH_AGENTS_DIR")|g" \
    -e "s|__UPDATER_PATH__|$(render_token "$UPDATER_PATH")|g" \
    "$UPDATER_TEMPLATE"
}

validate_rendered_plist() {
  local tmp rc render="${1:-render_plist}"
  tmp="$(mktemp)"
  "$render" > "$tmp"
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

# Copies a file into place by rename so a running reader never sees a partial file.
install_file() {
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2.tmp.$$"
  chmod "$3" "$2.tmp.$$"
  mv -f "$2.tmp.$$" "$2"
}

write_update_config() {
  mkdir -p "$UPDATE_DIR"
  printf '{"schema_version":1,"auto_update":%s,"origin":"%s","check_interval_seconds":3600,"idle_restart_seconds":120,"installed_version":"%s"}\n' \
    "$1" "$UPDATE_ORIGIN" "$2" > "$UPDATE_CONFIG.tmp.$$"
  mv -f "$UPDATE_CONFIG.tmp.$$" "$UPDATE_CONFIG"
}

plist_value() {
  local value
  if value="$(/usr/bin/plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null)"; then
    printf '%s' "$value"
  else
    printf '%s' "$2"
  fi
}

resolve_dir() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# Test mode (CMUX_RELAY_UPDATE_TEST=1) must never reach the real relay home,
# LaunchAgents, launchd, or keychain.
test_mode_guard() {
  [ "$TEST_MODE" = "1" ] || return 0
  local tmp dest agents found
  tmp="$(resolve_dir "${TMPDIR:-/tmp}")" || return 1
  dest="$(resolve_dir "$DEST")" || { echo "test mode: relay home must exist under TMPDIR" >&2; return 1; }
  agents="$(resolve_dir "$LAUNCH_AGENTS_DIR")" || { echo "test mode: LaunchAgents must exist under TMPDIR" >&2; return 1; }
  case "$dest/" in "$tmp"/*) ;; *) echo "test mode: relay home is not under TMPDIR" >&2; return 1 ;; esac
  case "$agents/" in "$tmp"/*) ;; *) echo "test mode: LaunchAgents is not under TMPDIR" >&2; return 1 ;; esac
  case "$LAUNCHCTL" in launchctl|/bin/launchctl) echo "test mode: real launchctl" >&2; return 1 ;; esac
  found="$(command -v launchctl 2>/dev/null || true)"
  [ "$found" != "/bin/launchctl" ] || { echo "test mode: /bin/launchctl is first on PATH" >&2; return 1; }
  case "$CODESIGN" in codesign|/usr/bin/codesign) echo "test mode: real codesign" >&2; return 1 ;; esac
  return 0
}

[ -f "$TEMPLATE" ] || fail "missing plist template: $TEMPLATE"
[ -f "$UPDATER_TEMPLATE" ] || fail "missing plist template: $UPDATER_TEMPLATE"
test_mode_guard || exit 3

if [ -n "$APPLY_STAGED" ]; then
  [ "$DRY_RUN" -eq 0 ] || { echo "--apply-staged cannot be combined with --dry-run" >&2; exit 2; }
  STAGED_BIN="$APPLY_STAGED/cmux-relay"
  [ -x "$STAGED_BIN" ] || fail "staged relay not found: $STAGED_BIN"
  command -v "$LAUNCHCTL" >/dev/null 2>&1 || fail "missing required tool: launchctl"
  if [ -f "$PLIST" ]; then
    # Keep the running install's settings: a release must not drop a pinned socket or an opt-out.
    SOCKET="$(plist_value EnvironmentVariables.CMUX_SOCKET_PATH "")"
    SELF_LOGIN_OPT_OUT="$(plist_value EnvironmentVariables.CMUX_NO_SELF_LOGIN "$SELF_LOGIN_OPT_OUT")"
    DEV_ALLOW_LOCALHOST="$(plist_value EnvironmentVariables.CMUX_DEV_ALLOW_LOCALHOST "$DEV_ALLOW_LOCALHOST")"
    RELAY_PATH="$(plist_value EnvironmentVariables.PATH "$RELAY_PATH")"
    CONFIG="$(plist_value ProgramArguments.3 "$CONFIG")"
  fi
  mkdir -p "$DEST/bin" "$LOGDIR" "$LAUNCH_AGENTS_DIR"
  cp "$STAGED_BIN" "$BIN_DEST.new"
  chmod 755 "$BIN_DEST.new"
  if [ "$(json_get "$APPLY_STAGED/manifest.json" signing)" = "identity" ]; then
    "$CODESIGN" --verify --strict "$BIN_DEST.new" \
      || { rm -f "$BIN_DEST.new"; fail "staged relay signature does not verify"; }
  fi
  mv -f "$BIN_DEST.new" "$BIN_DEST"
  INSTALLED_VERSION="$("$BIN_DEST" --version 2>/dev/null | head -n 1)"
  note "installed relay $INSTALLED_VERSION from the staged update"

  render_plist > "$PLIST.tmp.$$"
  if [ -f "$PLIST" ] && cmp -s "$PLIST.tmp.$$" "$PLIST"; then
    rm -f "$PLIST.tmp.$$"
    note "restarting $LABEL"
    "$LAUNCHCTL" kickstart -k "$SERVICE"
  else
    mv -f "$PLIST.tmp.$$" "$PLIST"
    validate_rendered_plist
    note "relay plist changed; reloading $LABEL"
    "$LAUNCHCTL" bootout "$TARGET" "$PLIST" >/dev/null 2>&1 || true
    "$LAUNCHCTL" bootstrap "$TARGET" "$PLIST"
  fi

  install_file "$UPDATER_SRC" "$UPDATER_DEST" 755
  render_updater_plist > "$UPDATER_PLIST.tmp.$$"
  if [ -f "$UPDATER_PLIST" ] && ! cmp -s "$UPDATER_PLIST.tmp.$$" "$UPDATER_PLIST"; then
    mv -f "$UPDATER_PLIST.tmp.$$" "$UPDATER_PLIST"
    note "updater plist changed; it takes effect at the next login or install"
  else
    rm -f "$UPDATER_PLIST.tmp.$$"
  fi
  if [ "$AUTO_UPDATE" -eq 1 ]; then
    write_update_config true "$INSTALLED_VERSION"
  else
    write_update_config false "$INSTALLED_VERSION"
  fi
  exit 0
fi

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
  note "would run: $BUILD_CMD"
  note "would copy: $BIN_SRC -> $BIN_DEST"
  note "would run: launchctl bootstrap $TARGET $PLIST"
  note "would run: launchctl kickstart -k $SERVICE"
  if [ "$AUTO_UPDATE" -eq 1 ]; then
    note "auto-update: enabled (origin $UPDATE_ORIGIN, tags vX.Y.Z only, check every 3600s, restart after no phone for 120s)"
    note "updater label: $UPDATER_LABEL"
    note "would install: $UPDATER_SRC -> $UPDATER_DEST"
    note "would write: $UPDATE_CONFIG (auto_update=true)"
    note "updater plist: $UPDATER_PLIST"
    note "would run: launchctl bootout $UPDATER_SERVICE"
    note "would run: launchctl bootstrap $TARGET $UPDATER_PLIST"
    note "managed clone (first new release): $DEST/src/cmux-remote"
  else
    note "auto-update: disabled (from $AUTO_UPDATE_SOURCE; relay.info reports disabled)"
    note "would write: $UPDATE_CONFIG (auto_update=false)"
    note "would run: launchctl bootout $UPDATER_SERVICE"
    note "would remove: $UPDATER_PLIST"
    note "would remove: $UPDATER_DEST"
    note "not installed: updater job $UPDATER_LABEL, its plist, or its script"
  fi
  printf '%s\n' '--- rendered plist ---'
  render_plist
  validate_rendered_plist
  if [ "$AUTO_UPDATE" -eq 1 ]; then
    printf '%s\n' '--- rendered updater plist ---'
    render_updater_plist
    validate_rendered_plist render_updater_plist
  fi
  exit 0
fi

command -v swift >/dev/null 2>&1 || fail "missing required tool: swift"
command -v "$LAUNCHCTL" >/dev/null 2>&1 || fail "missing required tool: launchctl"

# Stop an updater pass that may be running, so it cannot race this install.
"$LAUNCHCTL" bootout "$UPDATER_SERVICE" >/dev/null 2>&1 || true

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
(cd "$ROOT" && /bin/bash -c "$BUILD_CMD")
[ -x "$BIN_SRC" ] || fail "release binary not found after build: $BIN_SRC"

note "installing binary and logs under $DEST"
mkdir -p "$DEST/bin" "$LOGDIR" "$LAUNCH_AGENTS_DIR"
# Replace the binary by rename, never in place: overwriting the file the
# running relay was launched from invalidates its code signature, and macOS
# then kills it and refuses relaunch (OS_REASON_CODESIGNING).
cp "$BIN_SRC" "$BIN_DEST.new"
chmod 755 "$BIN_DEST.new"
if [ -n "$SIGN_IDENTITY" ]; then
  command -v "$CODESIGN" >/dev/null 2>&1 || fail "missing required tool: codesign"
  note "signing with: $SIGN_IDENTITY (from $SIGN_IDENTITY_SOURCE)"
  "$CODESIGN" --force --timestamp=none --identifier "$SIGN_IDENTIFIER" \
    --sign "$SIGN_IDENTITY" "$BIN_DEST.new" \
    || { rm -f "$BIN_DEST.new"; fail "codesign failed for identity: $SIGN_IDENTITY"; }
  "$CODESIGN" --verify --strict "$BIN_DEST.new" \
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
"$LAUNCHCTL" bootout "$TARGET" "$PLIST" >/dev/null 2>&1 || true
"$LAUNCHCTL" bootstrap "$TARGET" "$PLIST"
"$LAUNCHCTL" kickstart -k "$SERVICE"

INSTALLED_VERSION="$("$BIN_DEST" --version 2>/dev/null | head -n 1)"
if [ "$AUTO_UPDATE" -eq 1 ]; then
  note "installing updater $UPDATER_LABEL (release tags vX.Y.Z from $UPDATE_ORIGIN)"
  install_file "$UPDATER_SRC" "$UPDATER_DEST" 755
  write_update_config true "$INSTALLED_VERSION"
  render_updater_plist > "$UPDATER_PLIST.tmp.$$"
  mv -f "$UPDATER_PLIST.tmp.$$" "$UPDATER_PLIST"
  validate_rendered_plist render_updater_plist
  "$LAUNCHCTL" bootstrap "$TARGET" "$UPDATER_PLIST"
else
  note "auto-update off (from $AUTO_UPDATE_SOURCE); updater not installed"
  write_update_config false "$INSTALLED_VERSION"
  rm -f "$UPDATER_PLIST" "$UPDATER_DEST"
fi

note "installed $INSTALLED_VERSION; logs at $LOGDIR"
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY_SOURCE" != "$SIGN_IDENTITY_FILE" ]; then
  note "first install with this identity: allow Downloads access once if macOS asks"
fi
note "inspect with: launchctl print $SERVICE"
if [ "$AUTO_UPDATE" -eq 1 ]; then
  note "updater: launchctl print $UPDATER_SERVICE; log $LOGDIR/update.log"
fi
