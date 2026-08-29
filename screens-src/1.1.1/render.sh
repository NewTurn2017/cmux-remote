#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/screens-src/1.1.1/index.html"
OUTPUT="$ROOT/docs/launch-assets/screenshots/1.1.1"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

if [[ ! -x "$CHROME" ]]; then
  echo "Google Chrome is required." >&2
  exit 1
fi

render() {
  local device="$1"
  local locale="$2"
  local frame="$3"
  local width="$4"
  local height="$5"
  local slug="$6"
  local target="$OUTPUT/$device/$locale/$slug.png"
  mkdir -p "$(dirname "$target")"
  "$CHROME" \
    --headless \
    --hide-scrollbars \
    --force-device-scale-factor=1 \
    --virtual-time-budget=1200 \
    --window-size="${width},${height}" \
    --screenshot="$target" \
    "file://$SOURCE?device=${device%%-*}&locale=$locale&frame=$frame" \
    >/dev/null 2>&1
  local actual
  actual="$(sips -g pixelWidth -g pixelHeight "$target" | awk '/pixelWidth|pixelHeight/ {print $2}' | paste -sd x -)"
  if [[ "$actual" != "${width}x${height}" ]]; then
    echo "ERROR $target is $actual, expected ${width}x${height}" >&2
    exit 1
  fi
  echo "OK $target ($actual)"
}

for locale in ko en; do
  render iphone-6.9 "$locale" 1 1320 2868 "01-remote-command-center"
  render iphone-6.9 "$locale" 2 1320 2868 "02-truecolor-selection-copy"
  render iphone-6.9 "$locale" 3 1320 2868 "03-terminal-files-preview"
  render iphone-6.9 "$locale" 4 1320 2868 "04-compact-command-deck"
  render iphone-6.9 "$locale" 5 1320 2868 "05-private-tailscale"

  render ipad-13 "$locale" 1 2752 2064 "01-full-width-terminal"
  render ipad-13 "$locale" 2 2752 2064 "02-files-beside-terminal"
  render ipad-13 "$locale" 3 2752 2064 "03-workspaces-at-a-glance"
done

render_contact() {
  local device="$1"
  local locale="$2"
  local width="$3"
  local height="$4"
  local source="$ROOT/screens-src/1.1.1/contact.html"
  local target="$OUTPUT/review/${device}-${locale}-contact-sheet.png"
  mkdir -p "$(dirname "$target")"
  "$CHROME" \
    --headless \
    --hide-scrollbars \
    --force-device-scale-factor=1 \
    --virtual-time-budget=1200 \
    --window-size="${width},${height}" \
    --screenshot="$target" \
    "file://$source?device=$device&locale=$locale" \
    >/dev/null 2>&1
  local actual
  actual="$(sips -g pixelWidth -g pixelHeight "$target" | awk '/pixelWidth|pixelHeight/ {print $2}' | paste -sd x -)"
  if [[ "$actual" != "${width}x${height}" ]]; then
    echo "ERROR $target is $actual, expected ${width}x${height}" >&2
    exit 1
  fi
  echo "OK $target ($actual)"
}

for locale in ko en; do
  render_contact iphone-6.9 "$locale" 1800 820
  render_contact ipad-13 "$locale" 1900 650
done
