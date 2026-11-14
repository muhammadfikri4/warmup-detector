#!/bin/zsh
# Boot the paired iPhone + Apple Watch simulators, build with your signing (Config/Signing.xcconfig), install and launch both apps.
set -euo pipefail
cd "$(dirname "$0")/.."
PAIR_LINE=$(xcrun simctl list pairs | grep -m1 -E "^[0-9A-F-]{36} \(active")
[[ -z "$PAIR_LINE" ]] && { echo "No active iPhone + Watch simulator pair. Create one: xcrun simctl pair <watch-udid> <phone-udid>"; exit 1; }
PAIR=${PAIR_LINE%% *}
WATCH=$(xcrun simctl list pairs | grep -A2 "^$PAIR" | sed -n 's/.*Watch: .*(\([0-9A-F-]\{36\}\)).*/\1/p')
PHONE=$(xcrun simctl list pairs | grep -A2 "^$PAIR" | sed -n 's/.*Phone: .*(\([0-9A-F-]\{36\}\)).*/\1/p')
echo "▶ iPhone $PHONE + Watch $WATCH"
xcrun simctl boot "$PHONE" 2>/dev/null || true
xcrun simctl boot "$WATCH" 2>/dev/null || true
open -a Simulator 2>/dev/null || true
xcodebuild -scheme WarmUpPulse -destination "id=$PHONE" -allowProvisioningUpdates -derivedDataPath build/sim build -quiet
P=build/sim/Build/Products/Debug-iphonesimulator/WarmUpPulse.app
W="build/sim/Build/Products/Debug-watchsimulator/WarmUpPulse Watch App.app"
xcrun simctl install "$PHONE" "$P"
xcrun simctl install "$WATCH" "$W"
xcrun simctl launch --terminate-running-process "$WATCH" "$(plutil -extract CFBundleIdentifier raw "$W/Info.plist")"
sleep 3
PHONE_ID=$(plutil -extract CFBundleIdentifier raw "$P/Info.plist")
xcrun simctl launch --terminate-running-process "$PHONE" "$PHONE_ID" >/dev/null
# WatchConnectivity on a fresh boot reports "no watch" until the pair settles: relaunch once.
sleep 8
xcrun simctl launch --terminate-running-process "$PHONE" "$PHONE_ID"
xcrun simctl list pairs | grep "^$PAIR"
