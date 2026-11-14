#!/bin/zsh
# Build, install and launch WarmUp Pulse (with the embedded watch app) on the connected physical iPhone.
set -euo pipefail
# Bundle ID prefix and Team ID come from Config/Signing.xcconfig (override in Config/Local.xcconfig).
cd "$(dirname "$0")/.."
DEVICE=${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /connected/ && /iPhone/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')}
[[ -z "$DEVICE" ]] && { echo "No connected iPhone found. Connect it (cable or same Wi-Fi) and unlock it."; exit 1; }
echo "▶ iPhone $DEVICE"
xcodebuild -scheme WarmUpPulse -destination "id=$DEVICE" -allowProvisioningUpdates -derivedDataPath build/dd build -quiet
APP="build/dd/Build/Products/Debug-iphoneos/WarmUpPulse.app"
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE_ID"
