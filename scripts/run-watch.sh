#!/bin/zsh
# Build, install and launch the watch app on the physical Apple Watch paired with your iPhone.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE=${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /Watch/ && !/unavailable/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')}
[[ -z "$DEVICE" ]] && { echo "No Apple Watch found. Pair it with the iPhone, enable Developer Mode on the watch, keep it unlocked and nearby."; exit 1; }
echo "▶ Apple Watch $DEVICE"
xcodebuild -scheme "WarmUpPulse Watch App" -destination "id=$DEVICE" -allowProvisioningUpdates -derivedDataPath build/dd build -quiet
xcrun devicectl device install app --device "$DEVICE" "build/dd/Build/Products/Debug-watchos/WarmUpPulse Watch App.app"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" id.muhammadfikri.warmuppulse.watchkitapp
