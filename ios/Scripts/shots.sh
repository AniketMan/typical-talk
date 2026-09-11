#!/bin/bash
# Build Typical Talk for the simulator and capture one screenshot per tab.
# Uses simctl only, so it needs no Simulator.app and no Claude Code panel.
#
#   ./Scripts/shots.sh                 # default devices
#   ./Scripts/shots.sh "iPhone Air"    # a specific device name
set -euo pipefail

cd "$(dirname "$0")/.."
DEVICES=("$@")
if [ ${#DEVICES[@]} -eq 0 ]; then
  DEVICES=("iPhone 17 Pro" "iPhone Air")
fi

OUT="${SHOTS_OUT:-/tmp/tt-shots}"
DD=/tmp/tt-simbuild
BUNDLE=com.typicaltalk.TypicalTalk
rm -rf "$OUT"; mkdir -p "$OUT"

echo "Building once for the simulator..."
xcodebuild -project TypicalTalk.xcodeproj -scheme TypicalTalk \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  -derivedDataPath "$DD" build >/dev/null
APP="$DD/Build/Products/Debug-iphonesimulator/TypicalTalk.app"

# Resolve a device name to a udid, creating the device if it does not exist.
udid_for() {
  local name="$1" id
  id=$(xcrun simctl list devices available \
       | grep -F "$name (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  if [ -z "$id" ]; then
    local runtime
    runtime=$(xcrun simctl list runtimes | grep -E '^iOS' | tail -1 \
              | sed -E 's/.*(com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+).*/\1/')
    id=$(xcrun simctl create "$name" \
         "com.apple.CoreSimulator.SimDeviceType.${name// /-}" "$runtime")
  fi
  echo "$id"
}

for name in "${DEVICES[@]}"; do
  id=$(udid_for "$name")
  echo "==> $name ($id)"
  xcrun simctl bootstatus "$id" -b >/dev/null 2>&1 || xcrun simctl boot "$id" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$id" -b >/dev/null 2>&1 || true
  xcrun simctl install "$id" "$APP"

  slug=$(echo "$name" | tr ' ' '-')
  for tab in talks archive you; do
    xcrun simctl terminate "$id" "$BUNDLE" >/dev/null 2>&1 || true
    xcrun simctl launch "$id" "$BUNDLE" "tab:$tab" >/dev/null
    sleep 4
    xcrun simctl io "$id" screenshot "$OUT/$slug-$tab.png" >/dev/null 2>&1
    echo "    $slug-$tab.png"
  done
done

echo "Screenshots in $OUT"
