#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="$ROOT/docs/launch-assets/screenshots/1.1.1"

validate_group() {
  local directory="$1"
  local expected_count="$2"
  local expected_size="$3"
  local count
  count="$(find "$directory" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')"
  if [[ "$count" != "$expected_count" ]]; then
    echo "ERROR $directory contains $count PNG files, expected $expected_count" >&2
    exit 1
  fi

  while IFS= read -r file; do
    local actual
    actual="$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixelWidth|pixelHeight/ {print $2}' | paste -sd x -)"
    if [[ "$actual" != "$expected_size" ]]; then
      echo "ERROR $file is $actual, expected $expected_size" >&2
      exit 1
    fi
    echo "OK $file ($actual)"
  done < <(find "$directory" -maxdepth 1 -type f -name '*.png' | sort)
}

for locale in ko en; do
  validate_group "$OUTPUT/iphone-6.9/$locale" 5 1320x2868
  validate_group "$OUTPUT/ipad-13/$locale" 3 2752x2064
done

review_count="$(find "$OUTPUT/review" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')"
[[ "$review_count" == "4" ]] || {
  echo "ERROR review contains $review_count PNG files, expected 4" >&2
  exit 1
}
for file in "$OUTPUT/review"/iphone-6.9-*-contact-sheet.png; do
  actual="$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixelWidth|pixelHeight/ {print $2}' | paste -sd x -)"
  [[ "$actual" == "1800x820" ]] || {
    echo "ERROR $file is $actual, expected 1800x820" >&2
    exit 1
  }
done
for file in "$OUTPUT/review"/ipad-13-*-contact-sheet.png; do
  actual="$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixelWidth|pixelHeight/ {print $2}' | paste -sd x -)"
  [[ "$actual" == "1900x650" ]] || {
    echo "ERROR $file is $actual, expected 1900x650" >&2
    exit 1
  }
done
echo "OK review contact sheets"

echo "PASS 16 ASC screenshots and 4 review sheets"
