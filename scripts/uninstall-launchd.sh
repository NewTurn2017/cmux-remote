#!/usr/bin/env bash
# Remove the per-user cmux-relay launchd agent plist and unload it if present.
#
# Also removes the updater agent com.genie.cmuxremote.updater, its script, the update
# state in ~/.cmuxremote/update, and the updater's managed clone and build cache in
# ~/.cmuxremote/src/cmux-remote unless --keep-update-cache is given. relay.json,
# devices.json, codesign-identity, and the relay binary stay.

set -euo pipefail

LABEL="com.genie.cmuxremote"
UPDATER_LABEL="$LABEL.updater"
DRY_RUN=0
KEEP_UPDATE_CACHE=0

usage() {
  cat <<USAGE
Usage: scripts/uninstall-launchd.sh [--dry-run] [--keep-update-cache]

Options:
  --dry-run            Print the launchctl/rm actions without changing launchd or files.
  --keep-update-cache  Keep the updater's managed clone and build cache
                       (~/.cmuxremote/src/cmux-remote).
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --keep-update-cache) KEEP_UPDATE_CACHE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

DEST="${CMUX_REMOTE_HOME:-$HOME/.cmuxremote}"
LAUNCH_AGENTS_DIR="${CMUX_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
UPDATER_PLIST="$LAUNCH_AGENTS_DIR/$UPDATER_LABEL.plist"
TARGET="gui/$(id -u)"
SERVICE="$TARGET/$LABEL"
UPDATER_SERVICE="$TARGET/$UPDATER_LABEL"
UPDATER_SCRIPT="$DEST/libexec/relay-update.sh"
UPDATE_DIR="$DEST/update"
CLONE_DIR="$DEST/src/cmux-remote"
LAUNCHCTL="${CMUX_RELAY_LAUNCHCTL:-launchctl}"
TEST_MODE="${CMUX_RELAY_UPDATE_TEST:-0}"

note() { printf '[uninstall-launchd] %s\n' "$*"; }

resolve_dir() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# Test mode (CMUX_RELAY_UPDATE_TEST=1) must never reach the real relay home,
# LaunchAgents, or launchd.
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
  return 0
}

remove_tree() {
  case "$1" in
    "$DEST"/?*) rm -rf "$1" ;;
    *) note "refusing to remove a path outside the relay home: $1"; return 1 ;;
  esac
}

test_mode_guard || exit 3

if [ "$DRY_RUN" -eq 1 ]; then
  note "dry-run; no launchctl calls or file removal"
  note "plist: $PLIST"
  note "would run: launchctl bootout $TARGET $PLIST"
  note "would remove: $PLIST"
  note "would run: launchctl bootout $UPDATER_SERVICE"
  note "would remove: $UPDATER_PLIST"
  note "would remove: $UPDATER_SCRIPT"
  note "would remove: $UPDATE_DIR"
  if [ "$KEEP_UPDATE_CACHE" -eq 1 ]; then
    note "keeping (--keep-update-cache): $CLONE_DIR"
  else
    note "would remove: $CLONE_DIR"
  fi
  note "keeping: relay.json, devices.json, codesign-identity, bin/"
  exit 0
fi

command -v "$LAUNCHCTL" >/dev/null 2>&1 || { echo "missing required tool: launchctl" >&2; exit 1; }

"$LAUNCHCTL" bootout "$UPDATER_SERVICE" >/dev/null 2>&1 || true
rm -f "$UPDATER_PLIST" "$UPDATER_SCRIPT"
rmdir "$DEST/libexec" 2>/dev/null || true
if [ -d "$UPDATE_DIR" ]; then
  remove_tree "$UPDATE_DIR"
fi
if [ "$KEEP_UPDATE_CACHE" -eq 1 ]; then
  note "kept the update cache: $CLONE_DIR"
elif [ -d "$CLONE_DIR" ]; then
  remove_tree "$CLONE_DIR"
  rmdir "$DEST/src" 2>/dev/null || true
fi
note "uninstalled $UPDATER_LABEL"

if [ -f "$PLIST" ]; then
  "$LAUNCHCTL" bootout "$TARGET" "$PLIST" >/dev/null 2>&1 || "$LAUNCHCTL" bootout "$SERVICE" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  note "uninstalled $LABEL"
else
  "$LAUNCHCTL" bootout "$SERVICE" >/dev/null 2>&1 || true
  note "plist already absent: $PLIST"
fi
