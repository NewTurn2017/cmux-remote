#!/usr/bin/env bash
# Remove the per-user cmux-relay launchd agent plist and unload it if present.

set -euo pipefail

LABEL="com.genie.cmuxremote"
DRY_RUN=0

usage() {
  cat <<USAGE
Usage: scripts/uninstall-launchd.sh [--dry-run]

Options:
  --dry-run   Print the launchctl/rm actions without changing launchd or files.
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

LAUNCH_AGENTS_DIR="${CMUX_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
TARGET="gui/$(id -u)"
SERVICE="$TARGET/$LABEL"

note() { printf '[uninstall-launchd] %s\n' "$*"; }

if [ "$DRY_RUN" -eq 1 ]; then
  note "dry-run; no launchctl calls or file removal"
  note "plist: $PLIST"
  note "would run: launchctl bootout $TARGET $PLIST"
  note "would remove: $PLIST"
  exit 0
fi

command -v launchctl >/dev/null 2>&1 || { echo "missing required tool: launchctl" >&2; exit 1; }

if [ -f "$PLIST" ]; then
  launchctl bootout "$TARGET" "$PLIST" >/dev/null 2>&1 || launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  note "uninstalled $LABEL"
else
  launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
  note "plist already absent: $PLIST"
fi
