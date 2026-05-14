#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/ios"

# Force software keyboard in Simulator so the overlap regression is actually exercised.
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool NO >/dev/null 2>&1 || true

DESTINATION="${CMUX_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"

xcodebuild test \
  -project CmuxRemote.xcodeproj \
  -scheme CmuxRemote \
  -destination "$DESTINATION" \
  -only-testing:CmuxRemoteUITests/SmokeUITests/testKeyboardKeepsTerminalAndComposerControlsVisible \
  -only-testing:CmuxRemoteTests/CommandComposerTests \
  -quiet
